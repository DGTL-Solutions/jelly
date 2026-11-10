import Combine
import Foundation
import GroupActivities

/// SharePlay: in a FaceTime call (or from Messages) a film starts for everyone who has Jelly and access to the same
/// server. Play, pause and jumps travel between the devices; each one streams from the server with its own account.
struct WatchTogether: GroupActivity {
    static let activityIdentifier = "net.dgtl24.jelly.watch-together"
    var itemID: String
    var serverID: String?
    var title: String
    var subtitle: String?
    /// Where the person who started it stands; everyone opens the film there.
    var seconds: Double

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .watchTogether
        metadata.title = title
        metadata.subtitle = subtitle
        metadata.supportsContinuationOnTV = true
        return metadata
    }
}

@MainActor
final class SharePlay: ObservableObject, PlaybackCoordinator {
    /// A SharePlay session with Jelly is running.
    @Published private(set) var isActive = false
    /// Shown when the others' film can't be opened here.
    @Published var notice: String?

    private weak var model: AppModel?
    private let observer = GroupStateObserver()
    private var session: GroupSession<WatchTogether>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    private var tasks: [Task<Void, Never>] = []
    private var listening = false
    private var participants = 0

    private struct Signal: Codable {
        enum Kind: String, Codable { case play, pause, seek, state }
        var kind: Kind
        var itemID: String
        var position: Double
        var playing: Bool
        var sent: Date
    }

    init(model: AppModel) { self.model = model }

    /// A FaceTime call (or another SharePlay source) is there to share with.
    var isEligible: Bool { session != nil || observer.isEligibleForGroupSession }

    /// Waits for sessions – started here or by someone else in the call.
    func listen() {
        guard !listening else { return }
        listening = true
        Task { [weak self] in
            for await session in WatchTogether.sessions() { self?.configure(session) }
        }
    }

    /// "Abspielen" during a call: asks whether to start for everyone. `true` if SharePlay took the title over.
    func offer(_ item: BaseItem, seconds: Double) async -> Bool {
        let activity = WatchTogether(itemID: item.id, serverID: model?.session?.serverID, title: item.isEpisode ? item.seriesName ?? item.name : item.name,
                                     subtitle: item.isEpisode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ") : nil,
                                     seconds: seconds)
        if let session {
            session.activity = activity
            return true
        }
        switch await activity.prepareForActivation() {
        case .activationPreferred:
            return (try? await activity.activate()) == true
        case .cancelled:
            return true
        default:
            return false
        }
    }

    private func configure(_ session: GroupSession<WatchTogether>) {
        tearDown()
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger
        isActive = true
        participants = session.activeParticipants.count

        session.$state.sink { [weak self] state in
            if case .invalidated = state { self?.tearDown() }
        }.store(in: &subscriptions)
        session.$activity.sink { [weak self] activity in
            Task { await self?.open(activity) }
        }.store(in: &subscriptions)
        session.$activeParticipants.sink { [weak self] active in
            guard let self else { return }
            // Someone joined: tell them where the film stands.
            if active.count > self.participants, let player = PlaybackHub.shared.player { self.send(.state, player) }
            self.participants = active.count
        }.store(in: &subscriptions)
        tasks.append(Task { [weak self] in
            for await (signal, _) in messenger.messages(of: Signal.self) { self?.apply(signal) }
        })
        session.join()
    }

    private func tearDown() {
        subscriptions.removeAll()
        tasks.forEach { $0.cancel() }
        tasks = []
        session = nil
        messenger = nil
        isActive = false
    }

    private func open(_ activity: WatchTogether) async {
        guard let model, let client = model.client, let account = model.session else { return }
        if let player = PlaybackHub.shared.player, player.item.id == activity.itemID, model.playback != nil { return }
        guard activity.serverID == nil || account.serverID == nil || activity.serverID == account.serverID,
              let item = try? await client.item(user: account.userID, id: activity.itemID) else {
            notice = String(localized: "„\(activity.title)“ liegt auf einem Server, mit dem dieses Profil nicht verbunden ist.")
            return
        }
        guard model.purchases.access.canPlay else { model.showsPaywall = true; return }
        model.playback = PlaybackRequest(item: item, startSeconds: activity.seconds)
    }

    // MARK: Signals

    private func send(_ kind: Signal.Kind, _ player: PlayerController, position: Double? = nil, playing: Bool? = nil) {
        guard let messenger else { return }
        let signal = Signal(kind: kind, itemID: player.item.id, position: position ?? player.exactPosition, playing: playing ?? player.isPlaying, sent: Date())
        Task { try? await messenger.send(signal) }
    }

    private func apply(_ signal: Signal) {
        guard let player = PlaybackHub.shared.player, player.item.id == signal.itemID else { return }
        // The others' clocks and this one differ by less than the film would let anyone notice.
        let elapsed = max(0, min(5, Date().timeIntervalSince(signal.sent)))
        switch signal.kind {
        case .pause:
            player.groupPause(at: signal.position)
        case .play:
            Task {
                if abs(player.exactPosition - (signal.position + elapsed)) > 1.5 { await player.groupSeek(to: signal.position + elapsed) }
                player.groupPlay()
            }
        case .seek:
            Task { await player.groupSeek(to: signal.position + (signal.playing ? elapsed : 0)) }
        case .state:
            Task {
                let target = signal.position + (signal.playing ? elapsed : 0)
                if abs(player.exactPosition - target) > 1.5 { await player.groupSeek(to: target) }
                if signal.playing { player.groupPlay() } else { player.groupPause() }
            }
        }
    }

    // MARK: The player's side – it acts itself and tells the others

    func viewerWantsPlay(_ player: PlayerController) -> Bool {
        send(.play, player, playing: true)
        return false
    }

    func viewerWantsPause(_ player: PlayerController) -> Bool {
        send(.pause, player, playing: false)
        return false
    }

    func viewerWantsSeek(_ player: PlayerController, to seconds: Double) -> Bool {
        send(.seek, player, position: seconds)
        return false
    }

    func playerIsReady(_ player: PlayerController) {
        // "Nächste Folge" on this device: the others follow.
        if let session, session.activity.itemID != player.item.id {
            let item = player.item
            session.activity = WatchTogether(itemID: item.id, serverID: model?.session?.serverID, title: item.isEpisode ? item.seriesName ?? item.name : item.name,
                                             subtitle: item.isEpisode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ") : nil,
                                             seconds: player.exactPosition)
        }
    }

    func playerIsBuffering(_ player: PlayerController) {}

    func playerClosed(_ player: PlayerController) {
        // Closing the film leaves the shared session – unless the next episode opens right away.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if PlaybackHub.shared.player == nil { self?.session?.leave(); self?.tearDown() }
        }
    }
}
