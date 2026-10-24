import SwiftUI
import AVKit
import Combine
import MediaPlayer
import AetherEngine

// MARK: - Picture in Picture

/// Picture in Picture around whichever pipeline plays: Apple's player layer on the native route, the engine's
/// sample-buffer layer on the software route. While the window is open the engine keeps the pipeline alive in the
/// background (`pictureInPictureActive`); on the software route it also draws the subtitles into the window.
@MainActor
final class PlayerPictureInPicture: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    /// The window closed while the app is in the background: playback is paused and should be reported.
    var onStopInBackground: (@MainActor () -> Void)?

    private weak var engine: AetherEngine?
    private var controller: AVPictureInPictureController?
    /// The layer the current controller is built around; a new layer (new session, other route) needs a new one.
    private var layer: CALayer?
    private var subscriptions = Set<AnyCancellable>()
    private var possibleObservation: NSKeyValueObservation?

    func bind(_ engine: AetherEngine) {
        guard isSupported, self.engine !== engine else { return }
        self.engine = engine
        subscriptions.removeAll()
        engine.$videoRoute.map { _ in () }
            .merge(with: engine.$softwarePiPSource.map { _ in () }, engine.$currentAVPlayer.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &subscriptions)
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    /// The software route answers play/pause itself; the window asks again after a change from elsewhere.
    func invalidatePlaybackState() {
        guard engine?.videoRoute == .software else { return }
        controller?.invalidatePlaybackState()
    }

    func tearDown() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        engine?.pictureInPictureActive = false
        possibleObservation = nil
        controller = nil
        layer = nil
        subscriptions.removeAll()
        isActive = false
        isPossible = false
    }

    private func refresh() {
        // A running window keeps its controller; the engine hands the item over in place.
        guard let engine, !isActive else { return }
        var nextLayer: CALayer?
        var source: AVPictureInPictureController.ContentSource?
        switch engine.videoRoute {
        case .software:
            if let pipSource = engine.softwarePiPSource {
                nextLayer = pipSource.layer
                source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: pipSource.layer, playbackDelegate: self)
            }
        case .loopback, .remoteBypass:
            if let playerLayer = engine.nativePlayerLayer {
                nextLayer = playerLayer
                source = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
            }
        default:
            break
        }
        guard nextLayer !== layer else { return }
        possibleObservation = nil
        controller = nil
        isPossible = false
        layer = nextLayer
        guard let source else { return }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Going home while a film plays opens the window (if the system setting allows it).
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        self.controller = controller
    }

    private func started() {
        // Before the transition, so the engine never treats the inline layer as missing video.
        engine?.pictureInPictureActive = true
        engine?.setNativeSubtitleRendering(true)
        isActive = true
    }

    private func ended() {
        engine?.pictureInPictureActive = false
        engine?.setNativeSubtitleRendering(false)
        isActive = false
        if UIApplication.shared.applicationState == .background { onStopInBackground?() }
    }

    nonisolated private func onMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(work) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}

extension PlayerPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        onMain { started() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onMain { ended() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        onMain {
            Diagnostics.log("pip failed: \(error.localizedDescription)")
            ended()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen stays open underneath the window.
        completionHandler(true)
    }
}

extension PlayerPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain { engine?.softwarePiPSource?.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        onMain { engine?.softwarePiPSource?.timeRange() ?? CMTimeRange(start: .zero, duration: .zero) }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        onMain { engine?.softwarePiPSource?.isPaused ?? true }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        onMain { engine?.softwarePiPSource?.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}

// MARK: - Now Playing and AirPlay

/// The lock screen, Control Center and AirPlay: the engine owns the system Now Playing session on its native route
/// (`ownsVideoNowPlayingSession`), Jelly stages title and artwork and answers the transport commands.
/// Also tells the screen when the picture plays on an AirPlay receiver.
@MainActor
final class PlayerSystemBridge: ObservableObject {
    /// Name of the AirPlay receiver showing the picture, nil while it plays here.
    @Published private(set) var externalRoute: String?

    private weak var player: PlayerController?
    private weak var session: MPNowPlayingSession?
    private var subscriptions = Set<AnyCancellable>()
    private var externalObservation: NSKeyValueObservation?
    private var info: [String: Any] = [:]

    func bind(player: PlayerController, client: JellyfinClient?) {
        guard let engine = player.aether, self.player !== player else { return }
        self.player = player
        // Read when the engine creates its native host, so before the first load.
        engine.ownsVideoNowPlayingSession = true
        stage(player.item, client: client)
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                self?.registerCommands()
                self?.observeExternalPlayback(avPlayer)
            }
            .store(in: &subscriptions)
    }

    func tearDown() {
        if let center = session?.remoteCommandCenter {
            for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                            center.skipBackwardCommand, center.changePlaybackPositionCommand] as [MPRemoteCommand] {
                command.removeTarget(nil)
            }
        }
        subscriptions.removeAll()
        externalObservation = nil
        externalRoute = nil
    }

    /// Title, series and artwork for the system's player card; elapsed time and rate come from the player itself.
    private func stage(_ item: BaseItem, client: JellyfinClient?) {
        info = [MPMediaItemPropertyTitle: item.isEpisode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ") : item.name,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue]
        if item.isEpisode, let series = item.seriesName { info[MPMediaItemPropertyArtist] = series }
        player?.aether?.setVideoNowPlayingInfo(info)
        guard let url = client?.artworkURL(item, item.isEpisode ? .landscape : .poster, width: 600) else { return }
        Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(url), let self else { return }
            self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.player?.aether?.setVideoNowPlayingInfo(self.info)
        }
    }

    /// The session lives with the engine's native host; a new host (after the route changed) brings a new one.
    private func registerCommands() {
        guard let session = player?.aether?.videoNowPlayingSession, session !== self.session else { return }
        self.session = session
        let center = session.remoteCommandCenter
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.player?.isPlaying == false { self?.player?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.player?.isPlaying == true { self?.player?.togglePlayPause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in if let player = self?.player { player.seek(to: player.position + 10) } }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in if let player = self?.player { player.seek(to: player.position - 10) } }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.player?.seek(to: position) }
            return .success
        }
        session.becomeActiveIfPossible { _ in }
    }

    private func observeExternalPlayback(_ avPlayer: AVPlayer?) {
        externalObservation = avPlayer?.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] avPlayer, _ in
            let active = avPlayer.isExternalPlaybackActive
            Task { @MainActor in
                self?.externalRoute = active ? AVAudioSession.sharedInstance().currentRoute.outputs
                    .first { $0.portType == .airPlay }?.portName ?? "AirPlay" : nil
            }
        }
        if avPlayer == nil { externalRoute = nil }
    }
}

/// The system's AirPlay picker, prioritising video receivers.
struct PlayerAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Orientation

/// iPhone plays in landscape and returns to portrait afterwards; iPad keeps whatever the viewer holds.
@MainActor
enum PlayerOrientation {
    static func enterPlayback() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        request(.landscape)
    }

    static func leavePlayback() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        request(.portrait)
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            Diagnostics.log("orientation request failed: \(error.localizedDescription)")
        }
    }
}
