import SwiftUI
import Network
import AVFoundation

/// Runs the connection analysis step by step: server, route, speed, library, server conversion, device.
@MainActor
final class ConnectionAnalyzer: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case server, route, speed, library, conversion, device
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .server: return String(localized: "Server", comment: "The Jellyfin server")
            case .route: return String(localized: "Weg", comment: "Connection analysis: network route to the server")
            case .speed: return String(localized: "Tempo", comment: "Connection analysis step: speed test")
            case .library: return String(localized: "Bibliothek", comment: "Connection analysis step: media library check")
            case .conversion: return String(localized: "Umrechnung", comment: "Connection analysis step: server transcoding test")
            case .device: return "Apple TV"
            }
        }
    }

    enum StepState: Equatable { case waiting, running, done, failed(String) }

    enum Level { case good, fair, poor }

    struct Tip: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    struct LibraryStats {
        var count = 0
        var original = 0
        var compact = 0
        var adapted = 0
        var largest: [(name: String, bitrate: Double)] = []
        var maxBitrate: Double = 0
    }

    struct Conversion {
        var factor: Double
        var limit: Int
        var range: String
        var title: String
    }

    struct Report {
        var serverName = ""
        var version = ""
        var latency: [Double] = []
        var https = false
        var proxy: String?
        var publicAddress = true
        var homeAddress: URL?
        var interface = "?"
        var speed: NetworkProbe.Result?
        var library = LibraryStats()
        var conversion: Conversion?
        var policy: UserDto.Policy?
        var dolbyVision = false
        var hdrFormats: [String] = []
        var matchingEnabled = false
        var audioChannels = 2
        var tips: [Tip] = []
        var verdict = ""
        var verdictDetail = ""
        var level = Level.fair

        var latencyAverage: Double? { latency.isEmpty ? nil : latency.reduce(0, +) / Double(latency.count) }
        var jitter: Double? { latency.count > 1 ? (latency.max()! - latency.min()!) : nil }
    }

    @Published private(set) var states: [Step: StepState] = [:]
    @Published private(set) var report: Report?
    @Published private(set) var running = false

    func run(model: AppModel) async {
        guard !running, let client = model.client, let session = model.session else { return }
        running = true
        report = nil
        states = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
        var report = Report()
        defer { running = false; self.report = report }

        // 1. Server: version, response times, HTTPS, proxy in front.
        states[.server] = .running
        do {
            let info = try await client.publicInfo(timeout: 8)
            report.serverName = info.serverName ?? "Jellyfin"
            report.version = info.version ?? "?"
            for _ in 0..<5 {
                let start = Date()
                var request = URLRequest(url: client.url("System/Info/Public"), timeoutInterval: 8)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                guard let (_, response) = try? await URLSession.shared.data(for: request) else { continue }
                report.latency.append(Date().timeIntervalSince(start))
                if let http = response as? HTTPURLResponse {
                    let server = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
                    if http.value(forHTTPHeaderField: "cf-ray") != nil || server.contains("cloudflare") { report.proxy = "Cloudflare" }
                    else if server.contains("nginx") { report.proxy = "nginx" }
                    else if server.contains("caddy") { report.proxy = "Caddy" }
                }
            }
            report.https = client.server.scheme == "https"
            report.policy = (try? await client.currentUser())?.policy
            states[.server] = .done
        } catch {
            states[.server] = .failed(String(localized: "Server antwortet nicht"))
            report.verdict = String(localized: "Server nicht erreichbar")
            report.verdictDetail = String(localized: "Prüfe, ob der Server läuft und die Adresse stimmt (\(client.server.host() ?? "")).")
            report.level = .poor
            Step.allCases.dropFirst().forEach { states[$0] = .failed(String(localized: "übersprungen", comment: "Analysis step was skipped")) }
            return
        }

        // 2. Route: home network or internet, wired or Wi-Fi.
        states[.route] = .running
        await model.preferHomeNetwork()
        report.publicAddress = !ServerLocator.isPrivate(session.server)
        report.homeAddress = model.homeAddress
        report.interface = await Self.interface()
        states[.route] = .done

        // 3. Speed: eight seconds from a large file.
        states[.speed] = .running
        let libraryQuery = JellyfinClient.ItemQuery(types: ["Movie", "Episode"], sortBy: "DateCreated", sortOrder: "Descending",
                                                    limit: 1000, fields: "MediaSources")
        let items = (try? await client.items(user: session.userID, libraryQuery))?.items ?? []
        let sources = items.compactMap { item in item.mediaSources?.first.map { (item, $0) } }
        let largest = sources.max { ($0.1.bitrate ?? 0) < ($1.1.bitrate ?? 0) }
        if case let (item, source)? = largest {
            report.speed = await NetworkProbe.measure(client: client, itemID: item.id, source: source, seconds: 8)
        }
        states[.speed] = report.speed == nil ? .failed(String(localized: "Messung fehlgeschlagen")) : .done

        // 4. Library: how much plays in original quality on this line.
        states[.library] = .running
        let throughput = report.speed?.throughput ?? 0
        var stats = LibraryStats()
        for (item, source) in sources {
            let bitrate = Double(source.bitrate ?? 0)
            guard bitrate > 0 else { continue }
            stats.count += 1
            let audio = TechInfo.defaultAudio(source)
            if bitrate * 1.15 <= throughput {
                stats.original += 1
            } else if let compact = PlaybackPlan.compactBitrate(source: source, audio: audio), Double(compact) * 1.15 <= throughput {
                stats.compact += 1
            } else {
                stats.adapted += 1
            }
            stats.maxBitrate = max(stats.maxBitrate, bitrate)
            let name = item.isEpisode ? [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " ") : item.name
            stats.largest.append((name, bitrate))
        }
        stats.largest = Array(stats.largest.sorted { $0.bitrate > $1.bitrate }.prefix(5))
        report.library = stats
        states[.library] = .done

        // 5. Server conversion: only matters if something has to be adapted.
        states[.conversion] = .running
        if case let (item, source)? = largest, (source.bitrate ?? 0) > Int(throughput / 1.15) || throughput == 0 {
            report.conversion = await Self.conversionTest(client: client, user: session.userID, item: item, source: source,
                                                          limit: max(4, Int(throughput * 0.7 / 1_000_000)) * 1_000_000)
            states[.conversion] = report.conversion == nil ? .failed(String(localized: "Server hat nicht umgerechnet")) : .done
        } else {
            states[.conversion] = .done
        }

        // 6. This Apple TV.
        states[.device] = .running
        let device = DeviceCapabilities.current
        let display = DisplayCapabilities.current()
        report.dolbyVision = device.dolbyVision
        report.hdrFormats = display.hdrFormats
        report.matchingEnabled = display.matchingEnabled
        report.audioChannels = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        states[.device] = .done

        Self.assess(&report)
        Diagnostics.log(String(format: "analysis %.1f Mbit/s, latency %.0f ms, %@, %@, original %d/%d", throughput / 1_000_000,
                               (report.latencyAverage ?? 0) * 1000, report.interface, report.proxy ?? "kein Proxy",
                               report.library.original, report.library.count))
    }

    // MARK: Pieces

    private static func interface() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                if path.usesInterfaceType(.wiredEthernet) {
                    continuation.resume(returning: String(localized: "LAN-Kabel", comment: "Network connection: Ethernet cable"))
                } else if path.usesInterfaceType(.wifi) {
                    continuation.resume(returning: String(localized: "WLAN", comment: "Network connection: Wi-Fi"))
                } else {
                    continuation.resume(returning: String(localized: "Unbekannt", comment: "Network connection: unknown type"))
                }
            }
            monitor.start(queue: .global())
        }
    }

    /// Asks the server for a converted HLS stream of the largest file and times how fast segments arrive.
    private static func conversionTest(client: JellyfinClient, user: String, item: BaseItem, source: MediaSource, limit: Int) async -> Conversion? {
        guard let stream = try? await client.remuxStream(user: user, itemID: item.id, sourceID: source.id,
                                                          audioIndex: TechInfo.defaultAudio(source)?.index, plan: .limited(limit))
        else { return nil }
        defer { Task { await client.stopEncoding(playSessionID: stream.playSessionID) } }
        func fetch(_ url: URL) async -> Data? {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
            return try? await URLSession.shared.data(for: request).0
        }
        guard let master = await fetch(stream.url).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let lines = master.components(separatedBy: .newlines)
        guard let infoIndex = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }), infoIndex + 1 < lines.count,
              let variant = URL(string: lines[infoIndex + 1], relativeTo: stream.url)?.absoluteURL,
              let playlist = await fetch(variant).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let range = lines[infoIndex].contains("VIDEO-RANGE=PQ") ? "HDR10" : lines[infoIndex].contains("VIDEO-RANGE=HLG") ? "HLG" : "SDR"
        let entries = playlist.components(separatedBy: .newlines)
        var content = 0.0
        let start = Date()
        for (index, line) in entries.enumerated() where line.hasPrefix("#EXTINF:") {
            guard index + 1 < entries.count, let url = URL(string: entries[index + 1], relativeTo: variant)?.absoluteURL,
                  await fetch(url) != nil else { break }
            content += Double(line.dropFirst(8).split(separator: ",").first ?? "0") ?? 0
            if Date().timeIntervalSince(start) > 12 || content > 40 { break }
        }
        let elapsed = Date().timeIntervalSince(start)
        guard content > 0, elapsed > 0 else { return nil }
        return Conversion(factor: content / elapsed, limit: limit, range: range, title: item.isEpisode ? item.seriesName ?? item.name : item.name)
    }

    /// Overall verdict and concrete tips.
    private static func assess(_ report: inout Report) {
        let mbit = (report.speed?.throughput ?? 0) / 1_000_000
        let library = report.library
        let share = library.count > 0 ? Double(library.original + library.compact) / Double(library.count) : 1
        let percent = share.formatted(.percent.precision(.fractionLength(0)))
        switch mbit {
        case _ where library.maxBitrate > 0 && mbit * 1_000_000 >= library.maxBitrate * 1.15:
            report.level = .good
            report.verdict = String(localized: "Alles läuft in Originalqualität")
            report.verdictDetail = String(localized: "Die Leitung trägt auch die größten Dateien deiner Bibliothek.")
        case 25...:
            report.level = share > 0.85 ? .good : .fair
            report.verdict = share > 0.85 ? String(localized: "Sehr gut für HD und 4K") : String(localized: "Gut für HD und die meisten 4K-Titel")
            report.verdictDetail = String(localized: "\(percent) deiner Titel laufen im Original. Sehr große 4K-Remuxe passt Jelly automatisch an.")
        case 8..<25:
            report.level = .fair
            report.verdict = String(localized: "Gut für HD, 4K wird oft angepasst")
            report.verdictDetail = String(localized: "\(percent) deiner Titel laufen im Original.")
        default:
            report.level = .poor
            report.verdict = String(localized: "Langsame Verbindung")
            report.verdictDetail = String(localized: "Die meisten Titel muss der Server herunterrechnen.")
        }

        if report.interface == String(localized: "WLAN", comment: "Network connection: Wi-Fi") {
            report.tips.append(Tip(icon: "cable.connector",
                                   text: String(localized: "Das Apple TV hängt im WLAN. Ein LAN-Kabel macht große Dateien stabiler – besonders 4K.")))
        }
        if let minimum = report.speed?.minimum, let speed = report.speed, minimum < speed.throughput * 0.5 {
            let low = (minimum / 1_000_000).formatted(.number.precision(.fractionLength(0)))
            report.tips.append(Tip(icon: "waveform.path.ecg",
                                   text: String(localized: "Die Geschwindigkeit schwankt stark (zeitweise nur \(low) Mbit/s). Ein größerer Puffer hilft – Jelly hält bis zu 30 s vor.")))
        }
        if report.publicAddress, report.homeAddress == nil, mbit < 60 {
            report.tips.append(Tip(icon: "globe",
                                   text: String(localized: "Der Server wird über das Internet erreicht. Die Grenze ist meist der Upload am Anschluss des Servers – mehr als dieser Upload kommt nirgends an.")))
        }
        if report.proxy == "Cloudflare" {
            report.tips.append(Tip(icon: "cloud",
                                   text: String(localized: "Der Server läuft über Cloudflare. Cloudflare erlaubt im kostenlosen Tarif kein großes Video-Streaming und kann drosseln – eine direkte Verbindung (z. B. per VPN wie Tailscale oder WireGuard) ist meist schneller.")))
        }
        if let home = report.homeAddress {
            report.tips.append(Tip(icon: "house",
                                   text: String(localized: "Zu Hause spricht Jelly den Server direkt im Heimnetz an (\(home.host() ?? "")) – schneller als über das Internet.")))
        }
        if let conversion = report.conversion {
            let factor = conversion.factor.formatted(.number.precision(.fractionLength(1)))
            if conversion.factor >= 1.3 {
                report.tips.append(Tip(icon: "cpu",
                                       text: String(localized: "Der Server rechnet \(factor)-mal schneller als Echtzeit um – angepasste Qualität läuft flüssig.")))
            } else {
                report.tips.append(Tip(icon: "cpu",
                                       text: String(localized: "Der Server rechnet nur \(factor)-mal so schnell wie Echtzeit um – angepasste Qualität kann stocken. Hardware-Beschleunigung im Jellyfin-Dashboard hilft.")))
            }
            if conversion.range == "SDR" {
                report.tips.append(Tip(icon: "sun.max",
                                       text: String(localized: "Beim Umrechnen macht der Server aus HDR normales SDR. Für HDR in angepasster Qualität braucht der Server einen 10-Bit-fähigen HEVC-Encoder.")))
            }
        }
        if report.policy?.enableVideoPlaybackTranscoding == false {
            report.tips.append(Tip(icon: "lock",
                                   text: String(localized: "Dein Konto darf nicht umrechnen lassen. Titel über der Leitungsgeschwindigkeit werden stocken.")))
        }
        if let limit = report.policy?.remoteClientBitrateLimit, limit > 0 {
            report.tips.append(Tip(icon: "speedometer", text: String(localized: "Der Server begrenzt Fernzugriffe auf \(limit / 1_000_000) Mbit/s.")))
        }
        if !report.matchingEnabled {
            report.tips.append(Tip(icon: "tv",
                                   text: String(localized: "„Inhalt anpassen“ ist aus: Für automatisches HDR, Dolby Vision und 24 Hz in den Apple-TV-Einstellungen unter Video und Audio aktivieren.",
                                                           comment: "Refers to the tvOS setting 'Match Content' in Settings › Video and Audio")))
        }
    }

    /// Average throughput per time of day from all stored measurements of this server.
    static func timeOfDay(for server: URL) -> [(label: String, megabits: Double, count: Int)] {
        let entries = NetworkProbe.history.filter { $0.server == server.absoluteString }
        let buckets: [(String, ClosedRange<Int>)] = [(String(localized: "Morgens", comment: "Time of day: morning"), 6...11),
                                                     (String(localized: "Mittags", comment: "Time of day: midday/afternoon"), 12...17),
                                                     (String(localized: "Abends", comment: "Time of day: evening"), 18...22)]
        let calendar = Calendar.current
        var result = buckets.compactMap { label, hours -> (String, Double, Int)? in
            let values = entries.filter { hours.contains(calendar.component(.hour, from: $0.date)) }.map(\.throughput)
            return values.isEmpty ? nil : (label, values.reduce(0, +) / Double(values.count) / 1_000_000, values.count)
        }
        let night = entries.filter { let hour = calendar.component(.hour, from: $0.date); return hour >= 23 || hour < 6 }.map(\.throughput)
        if !night.isEmpty {
            let label = String(localized: "Nachts", comment: "Time of day: night")
            result.append((label, night.reduce(0, +) / Double(night.count) / 1_000_000, night.count))
        }
        return result
    }
}
