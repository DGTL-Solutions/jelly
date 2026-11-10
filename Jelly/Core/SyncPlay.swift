import Foundation

/// Jellyfin's SyncPlay: everyone in a group on the same server sees the same second of the same film, wherever they
/// are and whatever device they use. The server decides; each player reports when it is ready and follows its commands.
@MainActor
final class SyncPlay: ObservableObject, PlaybackCoordinator {
    static let settingKey = "syncPlay"

    struct Group: Decodable, Identifiable, Equatable {
        let groupId: String
        var groupName: String
        var participants: [String]
        var id: String { groupId }
    }

    /// The group this device is in.
    @Published private(set) var group: Group?
    /// Groups on the server that can be joined.
    @Published private(set) var available: [Group] = []
    @Published private(set) var loading = false
    /// "Anna ist dabei" and the like, shown briefly.
    @Published var notice: String?
    @Published var error: String?

    private weak var model: AppModel?
    /// Server time minus this device's time.
    private var clockOffset: TimeInterval = 0
    private var playlistItemID: String?
    private var groupItemID: String?
    /// The server waits for this player's "ready" (after a new title, a jump or a stall).
    private var owesReady = false
    private var groupIsPlaying = false
    private var scheduled: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    private var client: JellyfinClient? { model?.client }
    private var serverNow: Date { Date().addingTimeInterval(clockOffset) }

    static func isAllowed(_ user: UserDto?) -> Bool {
        UserDefaults.standard.bool(forKey: settingKey) && user?.policy?.syncPlayAccess != "None"
    }

    // MARK: Groups

    func refresh() async {
        guard let client else { return }
        loading = true
        defer { loading = false }
        do {
            available = try await client.get("SyncPlay/List")
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(name: String) async {
        await request("SyncPlay/New", ["GroupName": name])
    }

    func join(_ group: Group) async {
        await request("SyncPlay/Join", ["GroupId": group.groupId])
    }

    func leave() async {
        await request("SyncPlay/Leave", nil)
        left()
    }

    /// The profile changed or signed out: the group belongs to the old one.
    func reset() {
        if group != nil, let client { Task { _ = try? await client.send("SyncPlay/Leave", method: "POST") } }
        left()
        available = []
    }

    private func left() {
        group = nil
        playlistItemID = nil
        groupItemID = nil
        owesReady = false
        scheduled?.cancel()
        pingTask?.cancel()
    }

    @discardableResult
    private func request(_ path: String, _ body: [String: Any]?) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.send(path, method: "POST", body: body)
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: Starting a title for everyone

    /// In a group, "Abspielen" starts the title for all members.
    func start(_ item: BaseItem, at seconds: Double) {
        Task {
            await request("SyncPlay/SetNewQueue", ["PlayingQueue": [item.id], "PlayingItemPosition": 0,
                                                   "StartPositionTicks": Ticks.from(seconds: seconds)])
        }
    }

    // MARK: The player's side

    func viewerWantsPlay(_ player: PlayerController) -> Bool {
        guard group != nil else { return false }
        Task { await request("SyncPlay/Unpause", nil) }
        return true
    }

    func viewerWantsPause(_ player: PlayerController) -> Bool {
        guard group != nil else { return false }
        Task { await request("SyncPlay/Pause", nil) }
        return true
    }

    func viewerWantsSeek(_ player: PlayerController, to seconds: Double) -> Bool {
        guard group != nil else { return false }
        Task { await request("SyncPlay/Seek", ["PositionTicks": Ticks.from(seconds: seconds)]) }
        return true
    }

    func playerIsReady(_ player: PlayerController) {
        guard group != nil, owesReady, player.item.id == groupItemID else { return }
        owesReady = false
        report("Ready", position: player.exactPosition)
    }

    func playerIsBuffering(_ player: PlayerController) {
        guard group != nil, player.item.id == groupItemID else { return }
        owesReady = true
        report("Buffering", position: player.exactPosition)
    }

    func playerClosed(_ player: PlayerController) {
        guard group != nil else { return }
        // The others shouldn't wait for someone who stopped watching.
        Task { await request("SyncPlay/SetIgnoreWait", ["IgnoreWait": true]) }
    }

    private func report(_ kind: String, position: Double) {
        guard let playlistItemID else { return }
        let body: [String: Any] = ["When": JellyDate.string(serverNow), "PositionTicks": Ticks.from(seconds: position),
                                   "IsPlaying": groupIsPlaying, "PlaylistItemId": playlistItemID]
        Task { await request("SyncPlay/\(kind)", body) }
    }

    // MARK: Messages from the server

    func handle(_ type: String, _ data: [String: Any]) {
        switch type {
        case "Command":
            command(data)
        case "GroupJoined":
            guard let info = data["Data"], let json = try? JSONSerialization.data(withJSONObject: info),
                  let joined = try? JSONDecoder.jellyfin.decode(Group.self, from: json) else { return }
            group = joined
            error = nil
            Task { await synchroniseClock() }
            startPinging()
        case "UserJoined":
            guard let name = data["Data"] as? String else { return }
            if group?.participants.contains(name) == false { group?.participants.append(name) }
            notice = String(localized: "\(name) schaut jetzt mit")
        case "UserLeft":
            guard let name = data["Data"] as? String else { return }
            group?.participants.removeAll { $0 == name }
            notice = String(localized: "\(name) hat die Gruppe verlassen")
        case "GroupLeft", "NotInGroup", "GroupDoesNotExist":
            left()
        case "CreateGroupDenied", "JoinGroupDenied", "LibraryAccessDenied":
            error = String(localized: "Dein Konto darf auf diesem Server nicht gemeinsam schauen.")
        case "PlayQueue":
            guard let queue = data["Data"] as? [String: Any] else { return }
            playQueue(queue)
        default:
            break
        }
    }

    private func playQueue(_ queue: [String: Any]) {
        guard let model, let list = queue["Playlist"] as? [[String: Any]], let index = queue["PlayingItemIndex"] as? Int,
              list.indices.contains(index), let itemID = list[index]["ItemId"] as? String else { return }
        playlistItemID = list[index]["PlaylistItemId"] as? String
        groupItemID = itemID
        var seconds = Ticks.seconds((queue["StartPositionTicks"] as? NSNumber)?.int64Value)
        groupIsPlaying = queue["IsPlaying"] as? Bool ?? false
        // Joining a running film: it has moved on since the server wrote this down.
        if groupIsPlaying, let updated = (queue["LastUpdate"] as? String).flatMap(JellyDate.parse) {
            seconds += max(0, serverNow.timeIntervalSince(updated))
        }
        owesReady = true
        scheduled?.cancel()
        Task { await request("SyncPlay/SetIgnoreWait", ["IgnoreWait": false]) }
        if let player = PlaybackHub.shared.player, player.item.id == itemID, model.playback != nil {
            // Already open here: go to the group's second and wait.
            report("Buffering", position: seconds)
            Task {
                player.groupPause()
                await player.groupSeek(to: seconds)
                playerIsReady(player)
            }
        } else {
            report("Buffering", position: seconds)
            Task { await model.playForGroup(itemID: itemID, seconds: seconds) }
        }
    }

    private func command(_ data: [String: Any]) {
        guard group != nil, let name = data["Command"] as? String else { return }
        let seconds = Ticks.seconds((data["PositionTicks"] as? NSNumber)?.int64Value)
        let when = (data["When"] as? String).flatMap(JellyDate.parse) ?? serverNow
        // Commands for a title this device no longer shows are of no use.
        if let id = data["PlaylistItemId"] as? String, let playlistItemID, id != playlistItemID { return }
        guard let player = PlaybackHub.shared.player, player.item.id == groupItemID else { return }
        scheduled?.cancel()
        switch name {
        case "Unpause":
            groupIsPlaying = true
            scheduled = Task {
                let wait = when.timeIntervalSince(serverNow)
                if wait > 0 {
                    // Everyone starts at the same instant, from the same second.
                    if abs(player.exactPosition - seconds) > 0.5 { await player.groupSeek(to: seconds) }
                    try? await Task.sleep(for: .seconds(max(0, when.timeIntervalSince(serverNow))))
                } else if abs(player.exactPosition - (seconds - wait)) > 1.5 {
                    // The command arrived late: catch up to where the others are by now.
                    await player.groupSeek(to: seconds - wait + 0.5)
                }
                guard !Task.isCancelled else { return }
                player.groupPlay()
            }
        case "Pause":
            groupIsPlaying = false
            player.groupPause(at: seconds)
        case "Seek":
            owesReady = true
            scheduled = Task {
                player.groupPause()
                await player.groupSeek(to: seconds)
                guard !Task.isCancelled else { return }
                playerIsReady(player)
            }
        case "Stop":
            groupIsPlaying = false
            player.groupPause()
        default:
            break
        }
    }

    // MARK: Clock

    /// The members' clocks differ; the server's is the one that counts. Five quick questions, the fastest answer wins.
    private func synchroniseClock() async {
        guard let client else { return }
        struct ServerTime: Decodable { var requestReceptionTime: String; var responseTransmissionTime: String }
        var best: (delay: TimeInterval, offset: TimeInterval)?
        for _ in 0..<5 {
            let sent = Date()
            guard let time: ServerTime = try? await client.get("GetUtcTime"),
                  let received = JellyDate.parse(time.requestReceptionTime), let answered = JellyDate.parse(time.responseTransmissionTime) else { continue }
            let back = Date()
            let delay = (back.timeIntervalSince(sent) - answered.timeIntervalSince(received)) / 2
            let offset = (received.timeIntervalSince(sent) + answered.timeIntervalSince(back)) / 2
            if best == nil || delay < best!.delay { best = (delay, offset) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let best else { return }
        clockOffset = best.offset
        Diagnostics.log(String(format: "syncplay clock offset %.0f ms, ping %.0f ms", best.offset * 1000, best.delay * 1000))
        await request("SyncPlay/Ping", ["Ping": Int(max(0, best.delay) * 1000)])
    }

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.synchroniseClock()
            }
        }
    }
}

/// Jellyfin writes times with up to seven decimals, which the system's parser doesn't take.
enum JellyDate {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return formatter.date(from: text) }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let rest = text[text.index(dot, offsetBy: digits.count + 1)...]
        guard let base = formatter.date(from: String(text[..<dot]) + (rest.isEmpty ? "Z" : String(rest))),
              let fraction = Double("0." + digits) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    static func string(_ date: Date) -> String {
        let whole = floor(date.timeIntervalSince1970)
        let millis = Int((date.timeIntervalSince1970 - whole) * 1000)
        return formatter.string(from: Date(timeIntervalSince1970: whole)).replacingOccurrences(of: "Z", with: String(format: ".%03dZ", millis))
    }
}
