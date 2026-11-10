import Foundation

/// The live line to the Jellyfin server while Jelly is open: this device shows up as a player that others can start
/// and steer ("Auf Apple TV abspielen" from the iPhone, Jellyfin's own remote control), and SyncPlay groups talk over it.
@MainActor
final class SessionLink {
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var connectedKey: String?
    /// SyncPlay messages go to the group logic.
    var onSyncPlay: ((_ type: String, _ data: [String: Any]) -> Void)?
    /// After a dropped line the group has to be asked again where it stands.
    var onReconnect: (() -> Void)?

    init(model: AppModel) { self.model = model }

    /// Connects for the active profile; call again after a profile change or when the app returns to the foreground.
    func connect() {
        guard let model, let client = model.client, let session = model.session else { return disconnect() }
        let key = session.key + "|" + client.server.absoluteString
        if key == connectedKey, task != nil { return }
        disconnect()
        connectedKey = key
        task = Task { [weak self] in await self?.run(client) }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectedKey = nil
    }

    private func run(_ client: JellyfinClient) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                // The token travels in the header: newer servers no longer take it from the address.
                var components = URLComponents(url: client.url("socket", query: ["deviceId": client.deviceID]), resolvingAgainstBaseURL: false)!
                components.scheme = components.scheme == "https" ? "wss" : "ws"
                var request = URLRequest(url: components.url!)
                request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
                let socket = URLSession.shared.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                try await client.announceCapabilities()
                if attempt > 0 { onReconnect?() }
                attempt = 0
                var keepAlive: Task<Void, Never>?
                defer { keepAlive?.cancel() }
                while !Task.isCancelled {
                    guard case .string(let text) = try await socket.receive(),
                          let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let type = message["MessageType"] as? String else { continue }
                    if type == "ForceKeepAlive", keepAlive == nil {
                        let seconds = (message["Data"] as? Double) ?? 60
                        keepAlive = Task {
                            while !Task.isCancelled {
                                try? await socket.send(.string(#"{"MessageType":"KeepAlive"}"#))
                                try? await Task.sleep(for: .seconds(max(5, seconds / 2)))
                            }
                        }
                    } else {
                        handle(type, message["Data"])
                    }
                }
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                // The server restarts, the phone changes networks: try again, slower each time.
                try? await Task.sleep(for: .seconds(min(60, 2 * Double(attempt * attempt))))
            }
        }
    }

    private func handle(_ type: String, _ data: Any?) {
        guard let model else { return }
        let data = data as? [String: Any] ?? [:]
        switch type {
        case "Play":
            guard let ids = data["ItemIds"] as? [String], !ids.isEmpty else { return }
            let index = min(max(0, data["StartIndex"] as? Int ?? 0), ids.count - 1)
            let seconds = (data["StartPositionTicks"] as? NSNumber).map { Ticks.seconds($0.int64Value) }
            Diagnostics.log("remote: play \(ids[index])")
            Task { await model.playRemotely(itemID: ids[index], seconds: seconds) }
        case "Playstate":
            guard let player = PlaybackHub.shared.player, let command = data["Command"] as? String else { return }
            switch command {
            case "Pause": if player.isPlaying { player.togglePlayPause() }
            case "Unpause": if !player.isPlaying { player.togglePlayPause() }
            case "PlayPause": player.togglePlayPause()
            case "Stop": model.playback = nil
            case "Seek":
                if let ticks = data["SeekPositionTicks"] as? NSNumber { player.seek(to: Ticks.seconds(ticks.int64Value)) }
            case "FastForward": player.seek(to: player.position + 30)
            case "Rewind": player.seek(to: player.position - 10)
            default: break
            }
        case "GeneralCommand":
            guard let player = PlaybackHub.shared.player, let name = data["Name"] as? String else { return }
            let arguments = data["Arguments"] as? [String: Any] ?? [:]
            let index = (arguments["Index"] as? String).flatMap(Int.init) ?? (arguments["Index"] as? Int)
            switch name {
            case "SetAudioStreamIndex": if let index { player.selectAudio(index) }
            case "SetSubtitleStreamIndex": if let index { player.selectSubtitle(index) }
            case "DisplayMessage": player.notice = [arguments["Header"], arguments["Text"]].compactMap { $0 as? String }.joined(separator: " – ").nonEmpty
            default: break
            }
        case "SyncPlayCommand":
            onSyncPlay?("Command", data)
        case "SyncPlayGroupUpdate":
            onSyncPlay?(data["Type"] as? String ?? "", data)
        default:
            break
        }
    }
}

extension JellyfinClient {
    /// Tells the server what this device can be asked to do; with it Jelly appears under "Wiedergabe auf".
    func announceCapabilities() async throws {
        _ = try await send("Sessions/Capabilities/Full", method: "POST", body: [
            "PlayableMediaTypes": ["Video"], "SupportsMediaControl": true, "SupportsPersistentIdentifier": true,
            "SupportedCommands": ["DisplayMessage", "SetAudioStreamIndex", "SetSubtitleStreamIndex"]
        ])
    }

    /// Other devices of this account (or, for administrators, of anyone) that can be told what to play.
    func controllableSessions(user: String) async throws -> [RemoteSession] {
        let all: [RemoteSession] = try await get("Sessions", query: ["ControllableByUserId": user, "ActiveWithinSeconds": "600"])
        return all.filter { $0.supportsRemoteControl == true && $0.deviceId != deviceID }
    }

    func play(on session: String, itemID: String, seconds: Double) async throws {
        _ = try await send("Sessions/\(session)/Playing", method: "POST",
                           query: ["playCommand": "PlayNow", "itemIds": itemID, "startPositionTicks": "\(Ticks.from(seconds: seconds))"])
    }

    /// `command`: Pause, Unpause, PlayPause, Stop, Seek (with `seconds`).
    func control(_ session: String, _ command: String, seconds: Double? = nil) async throws {
        var query: [String: String] = [:]
        if let seconds { query["seekPositionTicks"] = "\(Ticks.from(seconds: seconds))" }
        _ = try await send("Sessions/\(session)/Playing/\(command)", method: "POST", query: query)
    }
}

/// Another device signed in to the server, as far as the remote needs it.
struct RemoteSession: Decodable, Identifiable, Hashable {
    let id: String
    var deviceName: String?
    var deviceId: String?
    var client: String?
    var userName: String?
    var supportsRemoteControl: Bool?
    var nowPlayingItem: BaseItem?
    var playState: PlayState?

    struct PlayState: Decodable, Hashable {
        var positionTicks: Int64?
        var isPaused: Bool?
    }

    static func == (a: RemoteSession, b: RemoteSession) -> Bool {
        a.id == b.id && a.nowPlayingItem?.id == b.nowPlayingItem?.id && a.playState == b.playState
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isAppleTV: Bool { deviceName == "Apple TV" }
    var symbol: String {
        switch deviceName {
        case "Apple TV": return "appletv"
        case "iPhone": return "iphone"
        case "iPad": return "ipad"
        case "Mac": return "macbook"
        default: return "tv"
        }
    }
}
