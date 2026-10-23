import Foundation
import Darwin

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    var name: String
    var url: URL
    var version: String?
}

/// Finds Jellyfin servers without typing: UDP discovery on port 7359 plus a scan of the local /24 network on port 8096.
@MainActor
final class ServerDiscovery: ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []
    @Published private(set) var isSearching = false

    func search() async {
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let replies = await Task.detached { LocalNetwork.broadcastDiscovery(timeout: 2.5) }.value
                await withTaskGroup(of: DiscoveredServer?.self) { probes in
                    for reply in replies { probes.addTask { await ServerLocator.reachable(reply) } }
                    for await server in probes { if let server { await self.add(server) } }
                }
            }
            group.addTask {
                await LocalNetwork.scan { server in await self.add(server) }
            }
        }
    }

    private func add(_ server: DiscoveredServer) {
        guard !servers.contains(where: { $0.id == server.id }) else { return }
        servers.append(server)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum ServerLocator {
    /// Addresses only reachable at home: RFC 1918 IPv4, link-local and .local names.
    static func isPrivate(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    /// Accepts "192.168.1.20", "jellyfin.local:8096", "media.example.com/jellyfin" or a copied web-client link.
    static func candidates(for input: String) throws -> [URL] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { throw JellyError.invalidURL }
        let lower = text.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        guard var components = URLComponents(string: hasScheme ? text : "http://" + text),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { throw JellyError.invalidURL }
        components.query = nil
        components.fragment = nil
        var path = components.path
        if let range = path.range(of: "/web", options: [.caseInsensitive, .backwards]),
           path[range.upperBound...].isEmpty || path[range.upperBound...].hasPrefix("/") {
            path = String(path[..<range.lowerBound])
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        if hasScheme { return [components.url].compactMap { $0 } }

        var result: [URL] = []
        func add(_ scheme: String, _ port: Int?) {
            var candidate = components
            candidate.scheme = scheme
            candidate.port = port
            if let url = candidate.url, !result.contains(url) { result.append(url) }
        }
        let isLocal = host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." } || !host.contains(".")
        if let port = components.port {
            if port == 443 || port == 8920 { add("https", port); add("http", port) } else { add("http", port); add("https", port) }
        } else if isLocal {
            add("http", 8096); add("https", 8920); add("https", nil); add("http", nil)
        } else {
            add("https", nil); add("http", 8096); add("https", 8920); add("http", nil)
        }
        return result
    }

    /// Tries all candidates in parallel and returns the most preferred one that answers like a Jellyfin server.
    static func resolve(_ input: String) async throws -> (URL, PublicSystemInfo) {
        let urls = try candidates(for: input)
        var results = [(URL, PublicSystemInfo)?](repeating: nil, count: urls.count)
        var finished = Set<Int>()
        return try await withThrowingTaskGroup(of: (Int, PublicSystemInfo?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, try? await JellyfinClient(server: url, deviceID: "probe").publicInfo(timeout: 6)) }
            }
            for try await (index, info) in group {
                finished.insert(index)
                if let info { results[index] = (urls[index], info) }
                // Stop as soon as every more preferred candidate has failed.
                if let best = results.firstIndex(where: { $0 != nil }), (0..<best).allSatisfy(finished.contains) {
                    group.cancelAll()
                    return results[best]!
                }
            }
            throw JellyError.serverNotFound
        }
    }

    /// Docker installs often announce an internal address. Fall back to the IP the reply came from.
    static func reachable(_ reply: LocalNetwork.Reply) async -> DiscoveredServer? {
        var urls = [reply.address]
        if var fallback = URLComponents(url: reply.address, resolvingAgainstBaseURL: false) {
            fallback.host = reply.sender
            if let url = fallback.url, url != reply.address { urls.append(url) }
        }
        for url in urls {
            if let info = try? await JellyfinClient(server: url, deviceID: "probe").publicInfo(timeout: 3) {
                return DiscoveredServer(id: info.id ?? reply.id, name: info.serverName ?? reply.name, url: url, version: info.version)
            }
        }
        return nil
    }
}

enum LocalNetwork {
    struct Interface { let address: UInt32; let netmask: UInt32 }
    struct Reply { let id: String; let name: String; let address: URL; let sender: String }

    static func ipv4Interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0xA9FE { continue } // link-local
            result.append(Interface(address: ip, netmask: mask))
        }
        return result
    }

    static func string(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    /// Blocking. Sends Jellyfin's discovery datagram to every broadcast address and collects replies.
    static func broadcastDiscovery(timeout: TimeInterval) -> [Reply] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return [] }
        defer { close(socketFD) }
        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let message = Array("who is JellyfinServer?".utf8)
        var targets: Set<UInt32> = [0xFFFF_FFFF]
        for interface in ipv4Interfaces() { targets.insert((interface.address & interface.netmask) | ~interface.netmask) }
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(7359).bigEndian
            address.sin_addr.s_addr = target.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        struct Payload: Decodable { let address: String; let id: String; let name: String }
        var replies: [String: Reply] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0,
                  let payload = try? JSONDecoder.jellyfin.decode(Payload.self, from: Data(buffer[0..<count])),
                  let url = URL(string: payload.address) else { continue }
            let ip = string(UInt32(bigEndian: sender.sin_addr.s_addr))
            replies[payload.id] = Reply(id: payload.id, name: payload.name, address: url, sender: ip)
        }
        return Array(replies.values)
    }

    /// Probes every host of the local /24 networks on Jellyfin's default port.
    static func scan(found: @escaping (DiscoveredServer) async -> Void) async {
        var hosts: [UInt32] = []
        for interface in ipv4Interfaces() {
            let base = interface.address & 0xFFFF_FF00
            hosts += (1...254).map { base | UInt32($0) }.filter { $0 != interface.address && !hosts.contains($0) }
        }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for host in hosts {
                if running >= 96 { await group.next(); running -= 1 }
                running += 1
                group.addTask {
                    let url = URL(string: "http://\(string(host)):8096")!
                    if let info = try? await JellyfinClient(server: url, deviceID: "probe").publicInfo(timeout: 1.5), let id = info.id {
                        await found(DiscoveredServer(id: id, name: info.serverName ?? string(host), url: url, version: info.version))
                    }
                }
            }
        }
    }
}
