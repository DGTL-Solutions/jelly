import SwiftUI
import AetherEngine

/// The touch player. Hosts one playback session at a time; "Nächste Folge" and "Erneut versuchen" swap in a fresh
/// session, like the Apple TV player. On iPhone it turns the screen to landscape while it is open.
struct MobilePlayerScreen: View {
    let client: JellyfinClient
    let userID: String
    @State private var request: PlaybackRequest

    init(request: PlaybackRequest, client: JellyfinClient, userID: String) {
        self.client = client
        self.userID = userID
        _request = State(initialValue: request)
    }

    var body: some View {
        MobilePlaybackSession(request: request, client: client, userID: userID) { request = $0 }
            .id(request.id)
            .onAppear { PlayerOrientation.enterPlayback() }
            .onDisappear { PlayerOrientation.leavePlayback() }
    }
}

enum MobilePanelTab: String, CaseIterable, Identifiable {
    case subtitles, audio, quality, chapters, sync, info
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subtitles: return String(localized: "Untertitel")
        case .audio: return String(localized: "Audio", comment: "Audio (player panel tab, info label)")
        case .quality: return String(localized: "Qualität", comment: "Player panel tab: stream quality")
        case .chapters: return String(localized: "Kapitel", comment: "Player panel tab: chapters")
        case .sync: return String(localized: "Synchronisation", comment: "Player panel tab: audio/subtitle delay")
        case .info: return String(localized: "Info", comment: "Player panel tab: playback details")
        }
    }
}

// MARK: - Interface state

/// What the player's interface shows around the picture: controls, panel, a pending jump, the scrub preview.
/// Owns the session's `PlayerController`, so both live exactly as long as the screen.
@MainActor
final class PlaybackUI: ObservableObject {
    let player: PlayerController

    @Published var controlsVisible = false
    @Published var panelOpen = false
    @Published var panelTab = MobilePanelTab.subtitles
    /// Where the next jump goes (scrubbing, double taps, the ±10 buttons); nil while nothing is pending.
    @Published var seekTarget: Double?
    @Published var scrubbing = false
    @Published var thumbnail: UIImage?
    /// Aspect fill instead of fit, toggled by pinching.
    @Published var fills = false
    @Published var skipFeedback: SkipFeedback?
    /// VoiceOver can't tap the picture to bring the controls back, so they stay.
    var keepsControls = false

    /// The tab the options button opens: the last one used from there.
    private(set) var optionsTab = MobilePanelTab.audio
    private var hideTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    struct SkipFeedback: Equatable {
        var forward: Bool
        var seconds: Int
    }

    init(item: BaseItem, client: JellyfinClient, userID: String) {
        player = PlayerController(item: item, client: client, userID: userID)
    }

    var shownPosition: Double { seekTarget ?? player.position }

    func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    func toggleControls() {
        if controlsVisible && !keepsControls {
            hideTask?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    func scheduleHide() {
        hideTask?.cancel()
        guard !keepsControls else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.player.isPlaying, self.seekTarget == nil, !self.panelOpen else { return }
            self.controlsVisible = false
        }
    }

    /// Taps add up; the jump happens once the viewer stops tapping.
    func skip(_ seconds: Double) {
        guard player.phase == .playing else { return }
        let base = seekTarget ?? player.position
        seekTarget = min(max(0, base + seconds), max(0, player.duration - 2))
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.commitSeek()
        }
        if controlsVisible { scheduleHide() }
    }

    /// Double tap on the left or right half: ∓10 seconds, with a short indicator on that side.
    func doubleTap(forward: Bool) {
        guard player.phase == .playing else { return }
        let previous = skipFeedback.flatMap { $0.forward == forward ? $0.seconds : nil } ?? 0
        skipFeedback = SkipFeedback(forward: forward, seconds: previous + 10)
        skip(forward ? 10 : -10)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.skipFeedback = nil
        }
    }

    func scrub(toFraction fraction: Double) {
        guard player.duration > 0 else { return }
        if !scrubbing {
            scrubbing = true
            seekTask?.cancel()
            hideTask?.cancel()
        }
        seekTarget = min(max(0, fraction * player.duration), max(0, player.duration - 2))
    }

    func commitSeek() {
        seekTask?.cancel()
        guard let target = seekTarget else { return }
        player.seek(to: target)
        seekTarget = nil
        scrubbing = false
        if controlsVisible { scheduleHide() }
    }

    func openPanel(_ tab: MobilePanelTab) {
        hideTask?.cancel()
        if tab != .subtitles { optionsTab = tab }
        panelTab = tab
        panelOpen = true
    }

    func selectTab(_ tab: MobilePanelTab) {
        panelTab = tab
        if tab != .subtitles { optionsTab = tab }
    }

    func closePanel() {
        panelOpen = false
        scheduleHide()
    }

    func setFill(_ fill: Bool) {
        guard fill != fills else { return }
        fills = fill
        player.aether?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    func cancelTasks() {
        hideTask?.cancel()
        seekTask?.cancel()
        feedbackTask?.cancel()
    }
}

// MARK: - Session

/// Owns one session's state objects; the stage observes them.
struct MobilePlaybackSession: View {
    let request: PlaybackRequest
    let replace: (PlaybackRequest) -> Void
    @StateObject private var ui: PlaybackUI
    @StateObject private var pip = PlayerPictureInPicture()
    @StateObject private var system = PlayerSystemBridge()

    init(request: PlaybackRequest, client: JellyfinClient, userID: String, replace: @escaping (PlaybackRequest) -> Void) {
        self.request = request
        self.replace = replace
        _ui = StateObject(wrappedValue: PlaybackUI(item: request.item, client: client, userID: userID))
    }

    var body: some View {
        PlaybackStage(request: request, replace: replace, ui: ui, player: ui.player, pip: pip, system: system)
    }
}

/// The session logic of the Apple TV player (start with the preferred audio language, skip intro, up next with
/// countdown, notices, failure with a software retry, background handling) with a touch interface.
struct PlaybackStage: View {
    let request: PlaybackRequest
    let replace: (PlaybackRequest) -> Void
    @ObservedObject var ui: PlaybackUI
    @ObservedObject var player: PlayerController
    @ObservedObject var pip: PlayerPictureInPicture
    @ObservedObject var system: PlayerSystemBridge

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("autoplayNext") private var autoplayNext = true
    @AppStorage("skipIntros") private var skipIntros = false
    @AppStorage("subtitleSize") private var subtitleSize = SubtitleSize.standard
    @AppStorage("subtitleBackground") private var subtitleBackground = SubtitleBackground.shadow
    @AppStorage("subtitleColor") private var subtitleColor = SubtitleColor.white
    @AppStorage("enginePreference") private var enginePreference = EnginePreference.automatic
    @AppStorage("debugOverlay") private var debugOverlay = false

    @State private var upNextDismissed = false
    /// Automatic skipping happens once; seeking back into the intro afterwards is deliberate.
    @State private var introSkipped = false
    @State private var countdown = 10
    /// How far the picture follows a downward swipe that closes the player.
    @State private var dismissDrag: CGFloat = 0
    @State private var backgroundTask: Task<Void, Never>?

    private var showsSkipIntro: Bool {
        guard let intro = player.intro, player.phase == .playing, !ui.panelOpen, ui.seekTarget == nil else { return false }
        return intro.contains(player.position) && intro.upperBound - player.position > 2
    }

    private var showsUpNext: Bool {
        guard autoplayNext, player.nextEpisode != nil, !upNextDismissed, !ui.panelOpen else { return false }
        if player.phase == .ended { return true }
        if let credits = player.creditsStart, player.phase == .playing { return player.position >= credits }
        return false
    }

    private enum CreditsAction { case nextEpisode, skipCredits }

    /// During the credits without the up-next card: the next episode right away, or – for a film or a last episode –
    /// skipping the credits (counts as watched and closes).
    private var creditsAction: CreditsAction? {
        guard let credits = player.creditsStart, player.phase == .playing, !showsUpNext, !ui.panelOpen, ui.seekTarget == nil,
              player.position >= credits, player.duration - player.position > 5 else { return nil }
        return player.nextEpisode != nil ? .nextEpisode : .skipCredits
    }

    private var showsControls: Bool {
        ui.controlsVisible && !ui.panelOpen && player.phase == .playing && dismissDrag == 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            picture
                .offset(y: dismissDrag)
                .scaleEffect(1 - min(dismissDrag, 600) / 3000)
            gestureLayer
            if player.isBuffering && player.phase == .playing && !showsControls && !pip.isActive {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }
            PlayerControlsOverlay(ui: ui, player: player, pip: pip, close: { dismiss() })
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
            if let feedback = ui.skipFeedback { PlayerSkipFeedback(feedback: feedback) }
            if debugOverlay && player.phase == .playing && !ui.panelOpen {
                PlayerDiagnosticsOverlay(player: player).transition(.opacity)
            }
            if showsSkipIntro {
                PlayerSkipButton(title: String(localized: "Intro überspringen"), systemImage: "forward.fill", lifted: showsControls) {
                    if let intro = player.intro { player.seek(to: intro.upperBound) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let action = creditsAction {
                creditsButton(action).transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if showsUpNext, let next = player.nextEpisode {
                if player.phase == .ended {
                    PlayerBackdrop(item: next).transition(.opacity)
                }
                PlayerUpNextCard(episode: next, countdown: countdown, lifted: showsControls, play: playNext) {
                    upNextDismissed = true
                    if player.phase == .ended { dismiss() }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let notice = player.notice { PlayerNotice(text: notice).transition(.move(edge: .top).combined(with: .opacity)) }
            PlayerOptionsPanel(ui: ui, player: player)
            if player.phase == .preparing {
                PlayerPreparingView(item: player.item, source: player.source, status: player.status) { dismiss() }
                    .transition(.opacity)
            }
            if case .failed(let message) = player.phase {
                PlayerFailureView(message: message, retry: {
                    // Once more, with the software decoder for everything.
                    replace(PlaybackRequest(item: player.item, mediaSourceID: request.mediaSourceID, forceSoftware: true))
                }, close: { dismiss() })
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: showsControls)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: ui.panelOpen)
        .animation(.easeInOut(duration: 0.4), value: player.phase)
        .animation(.easeInOut(duration: 0.3), value: showsSkipIntro)
        .animation(.easeInOut(duration: 0.3), value: creditsAction != nil)
        .animation(.easeInOut(duration: 0.3), value: showsUpNext)
        .animation(.easeInOut(duration: 0.3), value: player.notice)
        .animation(.easeOut(duration: 0.2), value: ui.skipFeedback)
        .sensoryFeedback(.impact(weight: .light), trigger: ui.skipFeedback) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: ui.fills)
        .task {
            // Now Playing, AirPlay and Picture in Picture hook into the engine before it loads anything.
            system.bind(player: player, client: model.client)
            if let engine = player.aether { pip.bind(engine) }
            pip.onStopInBackground = { [weak player] in player?.enterBackground() }
            await player.start(fromBeginning: request.fromBeginning, mediaSourceID: request.mediaSourceID,
                               preference: request.forceSoftware ? .software : enginePreference,
                               audioLanguage: model.user?.configuration?.audioLanguagePreference)
        }
        .onDisappear {
            backgroundTask?.cancel()
            ui.cancelTasks()
            pip.tearDown()
            system.tearDown()
            player.stop()
            model.contentChanged()
        }
        .onChange(of: voiceOver, initial: true) { _, enabled in
            ui.keepsControls = enabled
            if enabled, player.phase == .playing { ui.showControls(autoHide: false) }
        }
        .onChange(of: player.phase) { _, phase in
            switch phase {
            case .playing:
                ui.showControls()
                runDebugActions()
            case .ended:
                if !showsUpNext { dismiss() }
            case .preparing, .failed:
                break
            }
        }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { ui.scheduleHide() } else if player.phase == .playing { ui.showControls(autoHide: false) }
            pip.invalidatePlaybackState()
        }
        .onChange(of: showsSkipIntro) { _, shown in
            guard shown, skipIntros, !introSkipped, let intro = player.intro else { return }
            introSkipped = true
            player.seek(to: intro.upperBound)
            player.notice = String(localized: "Intro übersprungen")
        }
        .onChange(of: player.notice) { _, notice in
            guard notice != nil else { return }
            Task { try? await Task.sleep(for: .seconds(4)); player.notice = nil }
        }
        .task(id: showsUpNext) {
            guard showsUpNext else { return }
            countdown = 10
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown -= 1
            }
            playNext()
        }
        .task(id: ui.scrubbing ? ui.seekTarget.map { Int($0 / 5) } : nil) {
            // Thumbnail for the scrub position, at most every 5 seconds of film time: Jellyfin's trickplay tiles,
            // otherwise a still from what the engine already holds.
            guard ui.scrubbing, let target = ui.seekTarget else { ui.thumbnail = nil; return }
            if let image = await player.thumbnail(at: target) {
                ui.thumbnail = image
            } else if let engine = player.aether, engine.supportsCacheBackedStills,
                      let still = await engine.scrubThumbnail(atSeconds: target, maxWidth: 320), !Task.isCancelled {
                ui.thumbnail = UIImage(cgImage: still)
            }
        }
    }

    // MARK: Picture

    private var picture: some View {
        ZStack {
            if let engine = player.aether {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
            }
            if !pip.isActive {
                PlayerASSLayer(model: player.assOverlay, fills: ui.fills)
                if let engine = player.aether {
                    PlayerSubtitleLayer(engine: engine, delay: player.subtitleDelay, size: subtitleSize, background: subtitleBackground,
                                        color: subtitleColor == .yellow ? Color(red: 1, green: 0.88, blue: 0.3) : .white,
                                        lifted: showsControls)
                }
            }
            if pip.isActive {
                PlayerPictureInPicturePlaceholder()
            } else if let route = system.externalRoute {
                PlayerExternalPlaybackPlaceholder(route: route)
            }
        }
    }

    // MARK: Gestures

    /// Tap: controls. Double tap left/right: ∓10 s. Pinch: fill or fit. Swipe down: close.
    private var gestureLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    guard !pip.isActive else { return }
                    ui.doubleTap(forward: location.x > proxy.size.width / 2)
                }
                .onTapGesture { ui.toggleControls() }
                .gesture(dismissGesture)
                .simultaneousGesture(
                    MagnifyGesture().onEnded { value in
                        guard player.phase == .playing else { return }
                        if value.magnification > 1.08 { ui.setFill(true) } else if value.magnification < 0.92 { ui.setFill(false) }
                    }
                )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0, value.translation.height > abs(value.translation.width) else {
                    if dismissDrag != 0 { dismissDrag = 0 }
                    return
                }
                dismissDrag = value.translation.height
            }
            .onEnded { value in
                if dismissDrag > 0, value.translation.height > 140 || value.predictedEndTranslation.height > 420 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dismissDrag = 0 }
                }
            }
    }

    // MARK: Actions

    private func playNext() {
        guard let next = player.nextEpisode else { return }
        replace(PlaybackRequest(item: next))
    }

    @ViewBuilder private func creditsButton(_ action: CreditsAction) -> some View {
        switch action {
        case .nextEpisode:
            PlayerSkipButton(title: String(localized: "Nächste Folge"), systemImage: "forward.end.fill", lifted: showsControls, action: playNext)
        case .skipCredits:
            PlayerSkipButton(title: String(localized: "Abspann überspringen"), systemImage: "forward.fill", lifted: showsControls) {
                let item = player.item
                Task { await model.setWatched(item, true) }
                dismiss()
            }
        }
    }

    /// Leaving the app pauses and reports the position, as on Apple TV – unless Picture in Picture takes over, which
    /// the system starts a moment after the app leaves.
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundTask?.cancel()
            guard !pip.isActive else { return }
            guard player.isPlaying, pip.isPossible else {
                player.enterBackground()
                return
            }
            backgroundTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, !pip.isActive else { return }
                player.enterBackground()
            }
        case .active:
            backgroundTask?.cancel()
            player.enterForeground()
        default:
            break
        }
    }

    private func runDebugActions() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        func later(_ action: @escaping @MainActor () -> Void) {
            Task { try? await Task.sleep(for: .seconds(4)); action() }
        }
        if let tab = env["JELLY_PANEL"] { later { ui.openPanel(MobilePanelTab(rawValue: tab) ?? .subtitles) } }
        if env["JELLY_CONTROLS"] != nil { later { ui.showControls(autoHide: false) } }
        if env["JELLY_FILL"] != nil { later { ui.setFill(true) } }
        if env["JELLY_DOUBLETAP"] != nil { later { ui.doubleTap(forward: true); ui.doubleTap(forward: true) } }
        if env["JELLY_PIP"] != nil { later { pip.toggle() } }
        if let offset = env["JELLY_SCRUB"].flatMap(Double.init) {
            later {
                player.pause()
                ui.showControls(autoHide: false)
                ui.scrub(toFraction: (player.position + offset) / max(player.duration, 1))
            }
        }
        #endif
    }
}
