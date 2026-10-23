import SwiftUI
import AetherEngine

/// Hosts one playback session at a time. "Nächste Folge" and "Erneut versuchen" swap in a fresh session.
struct PlayerView: View {
    let client: JellyfinClient
    let userID: String
    @State private var request: PlaybackRequest

    init(request: PlaybackRequest, client: JellyfinClient, userID: String) {
        self.client = client
        self.userID = userID
        _request = State(initialValue: request)
    }

    var body: some View {
        PlaybackScreen(request: request, client: client, userID: userID) { request = $0 }
            .id(request.id)
    }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case subtitles, audio, quality, chapters, sync, info
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subtitles: return "Untertitel"
        case .audio: return "Audio"
        case .quality: return "Qualität"
        case .chapters: return "Kapitel"
        case .sync: return "Synchronisation"
        case .info: return "Info"
        }
    }
}

struct PlaybackScreen: View {
    let request: PlaybackRequest
    let replace: (PlaybackRequest) -> Void

    @StateObject private var player: PlayerController
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoplayNext") private var autoplayNext = true
    @AppStorage("skipIntros") private var skipIntros = false
    @AppStorage("subtitleSize") private var subtitleSize = SubtitleSize.standard
    @AppStorage("subtitleBackground") private var subtitleBackground = SubtitleBackground.shadow
    @AppStorage("subtitleColor") private var subtitleColor = SubtitleColor.white
    @AppStorage("enginePreference") private var enginePreference = EnginePreference.automatic
    @AppStorage("debugOverlay") private var debugOverlay = false

    @State private var controlsVisible = false
    @State private var panelOpen = false
    @State private var panelTab = PanelTab.subtitles
    @State private var seekTarget: Double?
    @State private var scrubbing = false
    @State private var scrubBase: Double = 0
    @State private var thumbnail: UIImage?
    @State private var hideTask: Task<Void, Never>?
    @State private var seekTask: Task<Void, Never>?
    @State private var upNextDismissed = false
    /// Automatic skipping happens once; seeking back into the intro afterwards is deliberate.
    @State private var introSkipped = false
    @State private var countdown = 10
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case tab(PanelTab), subtitle(Int), audio(Int), quality(Int), chapter(Int), retry }

    init(request: PlaybackRequest, client: JellyfinClient, userID: String, replace: @escaping (PlaybackRequest) -> Void) {
        self.request = request
        self.replace = replace
        _player = StateObject(wrappedValue: PlayerController(item: request.item, client: client, userID: userID))
    }

    private var shownPosition: Double { seekTarget ?? player.position }

    private var showsSkipIntro: Bool {
        guard let intro = player.intro, player.phase == .playing, !panelOpen, seekTarget == nil else { return false }
        return intro.contains(player.position) && intro.upperBound - player.position > 2
    }

    private var showsUpNext: Bool {
        guard autoplayNext, player.nextEpisode != nil, !upNextDismissed, !panelOpen else { return false }
        if player.phase == .ended { return true }
        if let credits = player.creditsStart, player.phase == .playing { return player.position >= credits }
        return false
    }

    private var tabs: [PanelTab] { PanelTab.allCases.filter { $0 != .chapters || !player.chapters.isEmpty } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = player.aether {
                AetherPlayerSurface(engine: engine)
                    .ignoresSafeArea()
            }
            RemoteInput(isActive: !panelOpen && (player.phase == .playing || player.phase == .ended),
                        onSelect: select, onPlayPause: playPause, onMenu: exit, onMove: move, onPan: pan)
                .ignoresSafeArea()
            ASSOverlay(model: player.assOverlay)
            if let engine = player.aether {
                SubtitleOverlay(engine: engine, clock: engine.clock, delay: player.subtitleDelay, size: subtitleSize.points,
                                background: subtitleBackground,
                                color: subtitleColor == .yellow ? Color(red: 1, green: 0.88, blue: 0.3) : .white,
                                lifted: controlsVisible && !panelOpen)
            }
            if player.isBuffering && player.phase == .playing {
                ProgressView().controlSize(.large)
            }
            controls
                .opacity(controlsVisible && !panelOpen && player.phase == .playing ? 1 : 0)
                .allowsHitTesting(false)
            if debugOverlay && player.phase == .playing { DiagnosticsOverlay(player: player).transition(.opacity) }
            if showsSkipIntro { skipIntroHint.transition(.move(edge: .trailing).combined(with: .opacity)) }
            if showsUpNext, let next = player.nextEpisode {
                if player.phase == .ended {
                    BackdropView(item: next, receded: false).opacity(0.6).transition(.opacity)
                }
                UpNextCard(episode: next, countdown: countdown).transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let notice = player.notice { noticeView(notice).transition(.move(edge: .top).combined(with: .opacity)) }
            if panelOpen { panel.transition(.move(edge: .top).combined(with: .opacity)) }
            if player.phase == .preparing {
                PreparingView(item: player.item, source: player.source, status: player.status).transition(.opacity)
            }
            if case .failed(let message) = player.phase { failure(message) }
        }
        .animation(.easeInOut(duration: 0.3), value: controlsVisible)
        .animation(.easeInOut(duration: 0.35), value: panelOpen)
        .animation(.easeInOut(duration: 0.4), value: player.phase)
        .animation(.easeInOut(duration: 0.3), value: showsSkipIntro)
        .animation(.easeInOut(duration: 0.3), value: showsUpNext)
        .animation(.easeInOut(duration: 0.3), value: player.notice)
        .persistentSystemOverlays(.hidden)
        // The remote layer handles presses while the panel is closed; these cover the open panel.
        .onPlayPauseCommand(perform: playPause)
        .onExitCommand(perform: exit)
        .task {
            await player.start(fromBeginning: request.fromBeginning, mediaSourceID: request.mediaSourceID,
                               preference: request.forceSoftware ? .software : enginePreference,
                               audioLanguage: model.user?.configuration?.audioLanguagePreference)
        }
        .onDisappear {
            hideTask?.cancel()
            seekTask?.cancel()
            player.stop()
            model.contentChanged()
        }
        .onChange(of: player.phase) { _, phase in
            switch phase {
            case .playing:
                showControls()
                #if DEBUG
                let env = ProcessInfo.processInfo.environment
                if env["JELLY_PANEL"] != nil { Task { try? await Task.sleep(for: .seconds(4)); openPanel(env["JELLY_PANEL"].flatMap { PanelTab(rawValue: $0) } ?? .subtitles) } }
                if env["JELLY_CONTROLS"] != nil { Task { try? await Task.sleep(for: .seconds(4)); showControls(autoHide: false) } }
                if let offset = env["JELLY_SCRUB"].flatMap(Double.init) {
                    Task { try? await Task.sleep(for: .seconds(4)); player.pause(); scrubbing = true; seekTarget = player.position + offset; showControls(autoHide: false) }
                }
                #endif
            case .ended:
                if !showsUpNext { dismiss() }
            case .failed:
                focus = .retry
            case .preparing:
                break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.enterBackground() }
            if phase == .active { player.enterForeground() }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleHide() } else if player.phase == .playing { showControls(autoHide: false) }
        }
        .onChange(of: showsSkipIntro) { _, shown in
            guard shown, skipIntros, !introSkipped, let intro = player.intro else { return }
            introSkipped = true
            player.seek(to: intro.upperBound)
            player.notice = "Intro übersprungen"
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
        .task(id: seekTarget.map { Int($0 / 5) }) {
            // Trickplay thumbnail for the scrub position, at most every 5 seconds of movie time.
            guard let target = seekTarget else { thumbnail = nil; return }
            thumbnail = await player.thumbnail(at: target)
        }
    }

    // MARK: Remote

    private func select() {
        if seekTarget != nil {
            commitSeek()
        } else if showsSkipIntro, let intro = player.intro {
            player.seek(to: intro.upperBound)
        } else if showsUpNext {
            playNext()
        } else {
            player.togglePlayPause()
            showControls()
        }
    }

    private func playPause() {
        guard player.phase == .playing else { return }
        if seekTarget != nil { commitSeek(); return }
        player.togglePlayPause()
        showControls()
    }

    private func move(_ direction: MoveCommandDirection) {
        guard player.phase == .playing, !panelOpen else { return }
        switch direction {
        case .left: skip(-10)
        case .right: skip(10)
        case .down: openPanel(.subtitles)
        case .up: showControls()
        @unknown default: break
        }
    }

    /// Swipes on the touch surface: scrub while paused, otherwise just reveal the controls.
    private func pan(_ phase: RemoteInput.Pan) {
        guard player.phase == .playing, !panelOpen else { return }
        switch phase {
        case .began:
            if !player.isPlaying || scrubbing {
                seekTask?.cancel()
                scrubbing = true
                scrubBase = seekTarget ?? player.position
            }
            showControls(autoHide: !scrubbing)
        case .changed(let distance):
            guard scrubbing else { return }
            // A full swipe covers about 8 % of the runtime, at least two minutes.
            let secondsPerPoint = max(120, player.duration * 0.08) / 1000
            seekTarget = min(max(0, scrubBase + Double(distance) * secondsPerPoint), max(0, player.duration - 2))
        case .ended:
            break
        }
    }

    private func exit() {
        if panelOpen {
            closePanel()
        } else if seekTarget != nil {
            // Cancel scrubbing and stay where playback was.
            seekTask?.cancel()
            seekTarget = nil
            scrubbing = false
        } else if showsUpNext {
            upNextDismissed = true
            if player.phase == .ended { dismiss() }
        } else if controlsVisible && player.isPlaying {
            controlsVisible = false
        } else {
            dismiss()
        }
    }

    /// Repeated presses add up; the seek happens once the viewer stops pressing (or right away when scrubbing).
    private func skip(_ seconds: Double) {
        let base = seekTarget ?? player.position
        seekTarget = min(max(0, base + seconds), max(0, player.duration - 2))
        showControls(autoHide: false)
        seekTask?.cancel()
        guard !scrubbing else { return }
        seekTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            commitSeek()
        }
    }

    private func commitSeek() {
        seekTask?.cancel()
        guard let target = seekTarget else { return }
        player.seek(to: target)
        seekTarget = nil
        scrubbing = false
        scheduleHide()
    }

    private func showControls(autoHide: Bool = true) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, player.isPlaying, seekTarget == nil, !panelOpen else { return }
            controlsVisible = false
        }
    }

    private func openPanel(_ tab: PanelTab) {
        hideTask?.cancel()
        panelTab = tab
        panelOpen = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            focus = .tab(tab)
        }
    }

    private func closePanel() {
        panelOpen = false
        focus = nil
        scheduleHide()
    }

    private func playNext() {
        guard let next = player.nextEpisode else { return }
        replace(PlaybackRequest(item: next))
    }

    // MARK: Overlays

    private var controls: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.5), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Label("Untertitel, Audio & Kapitel", systemImage: "chevron.compact.down")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 20)
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                HStack(alignment: .bottom, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        if player.item.isEpisode {
                            Text(player.item.seriesName ?? "").font(.callout).foregroundStyle(.secondary)
                            Text([player.item.episodeLabel, player.item.name].compactMap { $0 }.joined(separator: " – "))
                                .font(.title3.weight(.bold))
                        } else {
                            Text(player.item.name).font(.title2.weight(.bold))
                        }
                        if let chapter = currentChapter { Text(chapter).font(.caption).foregroundStyle(.secondary) }
                    }
                    .lineLimit(1)
                    Spacer()
                    TechBadges(badges: TechInfo.badges(player.source).filter { $0 != "UT" })
                }
                ProgressTrack(progress: player.duration > 0 ? shownPosition / player.duration : 0, emphasized: seekTarget != nil,
                              intro: player.intro.map { ($0.lowerBound / max(player.duration, 1))...($0.upperBound / max(player.duration, 1)) },
                              chapters: player.chapters.map { $0.start / max(player.duration, 1) }, thumbnail: seekTarget == nil ? nil : thumbnail,
                              label: seekTarget.map { Format.clock($0) })
                    // Room for the time bubble (and thumbnail) above the playhead while seeking.
                    .padding(.top, seekTarget == nil ? 0 : thumbnail == nil ? 54 : 200)
                    .animation(.easeOut(duration: 0.2), value: seekTarget == nil)
                HStack(spacing: 16) {
                    Image(systemName: scrubbing ? "hand.draw" : player.isPlaying ? "play.fill" : "pause.fill")
                    Text(Format.clock(shownPosition))
                    if let target = seekTarget {
                        let delta = Int((target - player.position).rounded())
                        Text(delta >= 0 ? "+\(Format.clock(Double(delta)))" : "−\(Format.clock(Double(-delta)))").foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text(scrubbing ? "Klicken zum Springen · Zurück zum Abbrechen" : "Endet um \(Date().addingTimeInterval(max(0, player.duration - shownPosition)).formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Text("−" + Format.clock(player.duration - shownPosition))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 60)
        }
    }

    private var currentChapter: String? {
        player.chapters.last { $0.start <= shownPosition }?.name.flatMap { name in
            name.lowercased().hasPrefix("chapter") ? nil : name
        }
    }

    private var skipIntroHint: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Label("Intro überspringen", systemImage: "forward.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 34).padding(.vertical, 18)
                    .background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            }
        }
        .padding(.trailing, 90)
        .padding(.bottom, controlsVisible ? 250 : 110)
    }

    private func noticeView(_ text: String) -> some View {
        VStack {
            Label(text, systemImage: "info.circle")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 30).padding(.vertical, 16)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 50)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: Panel

    private var panel: some View {
        VStack {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 14) {
                    ForEach(tabs) { tab in
                        Button(tab.title) { panelTab = tab }
                            .buttonStyle(PillButtonStyle(selected: panelTab == tab))
                            .focused($focus, equals: .tab(tab))
                    }
                }
                .focusSection()
                .onChange(of: focus) { _, value in
                    // Tabs switch on focus, like Apple's info panel.
                    if case .tab(let tab) = value { panelTab = tab }
                }
                Group {
                    switch panelTab {
                    case .subtitles: subtitlesTab
                    case .audio: audioTab
                    case .quality: qualityTab
                    case .chapters: chaptersTab
                    case .sync: syncTab
                    case .info: PlaybackInfoColumn(player: player)
                    }
                }
                .frame(height: 470, alignment: .top)
                .focusSection()
            }
            .padding(44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            .padding(.horizontal, 70)
            .padding(.top, 40)
            Spacer()
        }
    }

    private var subtitlesTab: some View {
        HStack(alignment: .top, spacing: 60) {
            TrackColumn(title: "Spur", options: player.subtitleOptions, selected: player.subtitleIndex ?? -1,
                        focus: $focus, focusValue: Focus.subtitle) { player.selectSubtitle($0) }
            VStack(alignment: .leading, spacing: 26) {
                choice("Größe", SubtitleSize.allCases, $subtitleSize) { $0.title }
                choice("Hintergrund", SubtitleBackground.allCases, $subtitleBackground) { $0.title }
                choice("Farbe", SubtitleColor.allCases, $subtitleColor) { $0.title }
            }
        }
    }

    private var audioTab: some View {
        HStack(alignment: .top, spacing: 60) {
            TrackColumn(title: "Spur", options: player.audioOptions, selected: player.audioIndex ?? Int.min,
                        focus: $focus, focusValue: Focus.audio) { player.selectAudio($0) }
            VStack(alignment: .leading, spacing: 10) {
                Text("AUSGABE").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                Text(player.audioOutput ?? "–").font(.callout)
                Text("TrueHD und DTS gibt das Apple TV verlustfrei als Mehrkanal-PCM aus; Atmos-Objekte überträgt tvOS nur aus Dolby Digital Plus.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var qualityTab: some View {
        HStack(alignment: .top, spacing: 60) {
            TrackColumn(title: "Stream", options: player.qualityOptions, selected: player.quality,
                        focus: $focus, focusValue: Focus.quality) { player.selectQuality($0) }
            VStack(alignment: .leading, spacing: 14) {
                Text("VERBINDUNG").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                if let capacity = player.stats.capacity ?? player.stats.throughput {
                    Text(String(format: "%.0f Mbit/s verfügbar", capacity / 1_000_000)).font(.callout)
                }
                Text(String(format: "%.0f Mbit/s benötigt", player.stats.required / 1_000_000)).font(.callout)
                Text("„Original“ spielt die Datei unverändert. „Nur gewählte Tonspur“ bleibt verlustfrei. Bei einer Bitrate-Grenze rechnet der Server das Bild herunter – nur sinnvoll, wenn die Leitung nicht reicht.")
                    .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var chaptersTab: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 30) {
                ForEach(Array(player.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        player.seek(to: chapter.start)
                        closePanel()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                Theme.placeholder
                                if let tag = chapter.imageTag {
                                    RemoteImage(url: model.client?.url("Items/\(player.item.id)/Images/Chapter/\(index)", query: ["tag": tag, "maxWidth": "600"]))
                                } else {
                                    Text("\(index + 1)").font(.system(size: 64, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .frame(width: 360, height: 202)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text(chapter.name ?? "Kapitel \(index + 1)").font(.caption.weight(.semibold)).lineLimit(1)
                            Text(Format.clock(chapter.start)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 360)
                    }
                    .buttonStyle(.card)
                    .focused($focus, equals: .chapter(index))
                }
            }
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 34) {
            stepper("Untertitel", value: player.subtitleDelay, step: 0.1, unit: "s",
                    hint: "Positiv: Untertitel erscheinen später") { player.setSubtitleDelay($0) }
            if player.canDelayAudio {
                stepper("Ton", value: player.audioDelay, step: 0.05, unit: "s",
                        hint: "Positiv: Ton kommt später als das Bild") { player.setAudioDelay($0) }
            } else {
                Text("Die Ton-Synchronisation übernimmt bei diesem Titel Apples Player selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stepper(_ title: String, value: Double, step: Double, unit: String, hint: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 520, alignment: .leading)
            Button { set(value - step) } label: { Image(systemName: "minus") }.buttonBorderShape(.circle)
            Text(String(format: "%+.2f %@", value, unit)).font(.callout.monospacedDigit()).frame(width: 180)
            Button { set(value + step) } label: { Image(systemName: "plus") }.buttonBorderShape(.circle)
            Button("Zurücksetzen") { set(0) }.disabled(value == 0)
        }
        .focusSection()
    }

    private func choice<Value: Hashable & Identifiable>(_ title: String, _ values: [Value], _ binding: Binding<Value>,
                                                         label: @escaping (Value) -> String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(values) { value in
                    Button(label(value)) { binding.wrappedValue = value }
                        .buttonStyle(PillButtonStyle(selected: binding.wrappedValue == value))
                }
            }
            .focusSection()
        }
    }

    private func failure(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 26) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 72)).foregroundStyle(.orange)
                Text("Wiedergabe nicht möglich").font(.title2.weight(.bold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 900)
                HStack(spacing: 30) {
                    Button("Erneut versuchen") {
                        // Once more, with the software decoder for everything.
                        replace(PlaybackRequest(item: player.item, mediaSourceID: request.mediaSourceID, forceSoftware: true))
                    }
                    .focused($focus, equals: .retry)
                    Button("Zurück") { dismiss() }
                }
                .padding(.top, 10)
            }
            .padding(60)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        }
    }
}

// MARK: - Pieces

struct ProgressTrack: View {
    let progress: Double
    var emphasized = false
    var intro: ClosedRange<Double>?
    var chapters: [Double] = []
    var thumbnail: UIImage?
    var label: String?

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                if let intro {
                    Capsule().fill(.white.opacity(0.18))
                        .frame(width: proxy.size.width * (intro.upperBound - intro.lowerBound))
                        .offset(x: proxy.size.width * intro.lowerBound)
                }
                Capsule().fill(.white).frame(width: max(14, proxy.size.width * clamped))
                ForEach(chapters.filter { $0 > 0.005 && $0 < 0.995 }, id: \.self) { mark in
                    Rectangle().fill(.black.opacity(0.6)).frame(width: 3).offset(x: proxy.size.width * mark)
                }
                if let label {
                    preview(label)
                        .position(x: min(max(170, proxy.size.width * clamped), proxy.size.width - 170), y: thumbnail == nil ? -40 : -130)
                }
            }
        }
        .frame(height: emphasized ? 16 : 10)
        .animation(.easeOut(duration: 0.15), value: emphasized)
    }

    private func preview(_ time: String) -> some View {
        VStack(spacing: 8) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 320, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.8), lineWidth: 3))
            }
            Text(time).font(.callout.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
    }
}

/// The engine's subtitle cues – text (SRT, WebVTT, also from server streams) in the viewer's style, picture subtitles
/// (PGS, VobSub, DVB) where the disc placed them. ASS/SSA draws `ASSOverlay` instead.
struct SubtitleOverlay: View {
    @ObservedObject var engine: AetherEngine
    /// Ten ticks a second; cues carry the source time of the frame on screen.
    @ObservedObject var clock: PlaybackClock
    var delay: Double = 0
    let size: CGFloat
    var background = SubtitleBackground.shadow
    var color = Color.white
    let lifted: Bool

    var body: some View {
        let time = clock.sourceTime - delay
        let cues = engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
        GeometryReader { proxy in
            ZStack {
                ForEach(cues) { cue in
                    if case .image(let image) = cue.body {
                        let rect = Self.place(image, in: proxy.size)
                        Image(decorative: image.cgImage, scale: 1).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                let lines = cues.filter { $0.text != nil }
                let top = lines.filter { (7...9).contains($0.placement?.alignment ?? 2) }
                let bottom = lines.filter { !(7...9).contains($0.placement?.alignment ?? 2) }
                VStack {
                    ForEach(top) { styled(text(for: $0)) }
                    Spacer()
                    ForEach(bottom) { styled(text(for: $0)) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 140)
                .padding(.top, 60)
                .padding(.bottom, lifted ? 260 : 70)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lifted)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Bold and italic from the file; size, colour and background follow the viewer's settings.
    private func text(for cue: SubtitleCue) -> Text {
        guard case .richText(let runs) = cue.body else { return Text(cue.text ?? "") }
        return runs.reduce(Text("")) { result, run in
            var piece = Text(run.text)
            if run.isBold { piece = piece.bold() }
            if run.isItalic { piece = piece.italic() }
            if run.isUnderlined { piece = piece.underline() }
            return result + piece
        }
    }

    /// The picture's canvas (the video frame it was authored for) fitted into the screen like the video itself.
    static func place(_ image: SubtitleImage, in screen: CGSize) -> CGRect {
        let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0 ? image.canvasSize : screen
        let scale = min(screen.width / canvas.width, screen.height / canvas.height)
        let origin = CGPoint(x: (screen.width - canvas.width * scale) / 2, y: (screen.height - canvas.height * scale) / 2)
        return CGRect(x: origin.x + image.position.minX * scale, y: origin.y + image.position.minY * scale,
                      width: image.position.width * scale, height: image.position.height * scale)
    }

    @ViewBuilder private func styled(_ text: Text) -> some View {
        let base = text
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
        switch background {
        case .shadow:
            base.shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1).shadow(color: .black.opacity(0.7), radius: 8)
        case .box:
            base.padding(.horizontal, 18).padding(.vertical, 6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct TrackColumn: View {
    let title: String
    let options: [TrackOption]
    let selected: Int
    let focus: FocusState<PlaybackScreen.Focus?>.Binding
    let focusValue: (Int) -> PlaybackScreen.Focus
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary).padding(.leading, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(options) { option in
                        Button { choose(option.id) } label: {
                            HStack(spacing: 18) {
                                Image(systemName: "checkmark").font(.callout.weight(.bold)).opacity(option.id == selected ? 1 : 0)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).font(.callout).lineLimit(1)
                                    if let detail = option.detail { Text(detail).font(.caption2).opacity(0.65).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(PanelRowStyle())
                        .focused(focus, equals: focusValue(option.id))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 420)
            .padding(.horizontal, -10)
        }
        .frame(width: 640)
        .focusSection()
    }
}

struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .padding(.horizontal, 22).padding(.vertical, 14)
                .foregroundStyle(focused ? .black : .white)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(focused ? .white : .clear))
                .scaleEffect(focused ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

struct PlaybackInfoColumn: View {
    @ObservedObject var player: PlayerController
    @State private var display = DisplayCapabilities(matchingEnabled: false, hdrFormats: [])

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 18) {
                row("Video", TechInfo.videoDescription(player.source?.video))
                row("Audio", TechInfo.audioDescription(player.source?.audioStreams.first { $0.index == player.audioIndex }))
                row("Ausgabe", player.audioOutput)
                row("Datei", [JellyfinClient.fileExtension(container: player.source?.container).uppercased(), TechInfo.bitrate(player.source)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .frame(width: 760, alignment: .leading)
            VStack(alignment: .leading, spacing: 18) {
                row("Wiedergabe", player.streamTitle)
                row("Bildausgabe", player.outputVideo)
                row("Warum", player.plan?.reason)
                row("Bildschirm", display.matchingEnabled ? "Passt sich dem Inhalt an" : "Inhalt anpassen ist aus")
            }
        }
        .onAppear { display = DisplayCapabilities.current() }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.caption)
            }
        }
    }
}

struct PreparingView: View {
    let item: BaseItem
    let source: MediaSource?
    var status: String?

    var body: some View {
        ZStack {
            BackdropView(item: item)
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 36) {
                TitleLogo(item: item, maxWidth: 720, maxHeight: 240, font: .system(size: 64, weight: .bold))
                if item.isEpisode {
                    Text([item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ")).font(.title3)
                }
                ProgressView().controlSize(.large)
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                TechBadges(badges: TechInfo.badges(source).filter { $0 != "UT" })
            }
        }
    }
}

/// Live numbers that explain stutter: what the line delivers versus what the stream needs, buffer, stalls,
/// dropped frames. Enabled in Einstellungen › Diagnose.
struct DiagnosticsOverlay: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        let stats = player.stats
        VStack(alignment: .leading, spacing: 6) {
            Label(verdictText(stats), systemImage: verdictIcon(stats.verdict))
                .font(.caption.weight(.bold))
                .foregroundStyle(verdictColor(stats.verdict))
            Divider().overlay(.white.opacity(0.3))
            row("Weg", player.streamTitle)
            row("Grund", player.plan?.reason)
            row("Datei", [TechInfo.videoDescription(player.source?.video), rate(Double(player.source?.bitrate ?? 0))]
                .compactMap { $0 }.joined(separator: " · "))
            row("Bild", player.outputVideo)
            row("Ton", player.audioOutput)
            row("Netz", rate(stats.throughput).map { "\($0) ankommend" })
            row("Leitung", rate(stats.capacity).map { "\($0) gemessen" })
            row("Bedarf", rate(stats.required).map { "\($0) für diesen Stream" })
            row("Puffer", stats.bufferAhead.map { String(format: "%.1f s voraus", $0) })
            row("Hänger", "\(stats.stalls)")
            row("Bilder", [stats.displayFPS.map { String(format: "%.1f fps", $0) },
                           "\(stats.droppedFrames) verloren", String(format: "%.0f/min", stats.droppedPerMinute)]
                .compactMap { $0 }.joined(separator: " · "))
            row("A/V-Sync", stats.avSyncMs.map { String(format: "%+.0f ms", $0) })
        }
        .font(.system(size: 20, design: .monospaced))
        .padding(22)
        .frame(width: 720, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.leading, 60)
        .padding(.top, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).foregroundStyle(.white.opacity(0.55)).frame(width: 120, alignment: .leading)
                Text(value).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private func rate(_ bits: Double?) -> String? {
        guard let bits, bits > 0 else { return nil }
        return String(format: "%.1f Mbit/s", bits / 1_000_000)
    }

    private func verdictText(_ stats: PlaybackStats) -> String {
        switch stats.verdict {
        case .good: return "Läuft flüssig"
        case .tight: return "Puffer knapp – Leitung am Limit"
        case .network:
            let available = (stats.capacity ?? stats.throughput ?? 0) / 1_000_000
            return String(format: "Netzwerk zu langsam: %.0f von %.0f Mbit/s", available, stats.required / 1_000_000)
        case .decoder: return "Decoder kommt nicht hinterher"
        }
    }

    private func verdictIcon(_ verdict: PlaybackStats.Verdict) -> String {
        verdict == .good ? "checkmark.circle.fill" : verdict == .tight ? "exclamationmark.circle.fill" : "xmark.octagon.fill"
    }

    private func verdictColor(_ verdict: PlaybackStats.Verdict) -> Color {
        verdict == .good ? .green : verdict == .tight ? .yellow : Color(red: 1, green: 0.4, blue: 0.35)
    }
}

struct UpNextCard: View {
    let episode: BaseItem
    let countdown: Int

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 28) {
                    ItemArtwork(item: episode, style: .landscape, pixelWidth: 640)
                        .frame(width: 320, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NÄCHSTE FOLGE IN \(countdown) S").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                        Text([episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " – "))
                            .font(.callout.weight(.semibold)).lineLimit(2)
                        Text("Klicken: jetzt abspielen · Zurück: schließen").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 480, alignment: .leading)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .padding(.trailing, 90)
        .padding(.bottom, 90)
    }
}
