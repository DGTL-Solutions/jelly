import SwiftUI
import Combine
import AVFoundation
import AetherEngine

/// Live numbers for the diagnostics overlay and the stall hint.
struct PlaybackStats: Equatable {
    /// Bits per second the line delivers while it delivers (the original file: bytes the engine pulls from the server;
    /// a server stream: Apple's player's own measurement).
    var throughput: Double?
    /// Bits per second the stream needs on average.
    var required: Double = 0
    /// Last explicit measurement of the connection.
    var capacity: Double?
    var bufferAhead: Double?
    var displayFPS: Double?
    var droppedFrames = 0
    var droppedPerMinute: Double = 0
    var stalls = 0
    var avSyncMs: Double?

    enum Verdict: Equatable { case good, tight, network, decoder }

    var verdict: Verdict {
        let available = capacity ?? throughput
        if stalls > 0, let available, available < required { return .network }
        if droppedPerMinute > 30 { return .decoder }
        if stalls > 0 || (bufferAhead ?? 99) < 4 { return .tight }
        return .good
    }
}

struct TrackOption: Identifiable, Hashable {
    let id: Int
    let title: String
    var detail: String?
}

/// One playback session: picks the stream, drives AetherEngine (Apple's player for what the Apple TV decodes – Dolby
/// Vision, HDR10+, Atmos, with the display following the content –, FFmpeg decoders for the rest) and reports to Jellyfin.
@MainActor
final class PlayerController: ObservableObject {
    enum Phase: Equatable { case preparing, playing, ended, failed(String) }

    @Published private(set) var phase = Phase.preparing
    @Published private(set) var item: BaseItem
    @Published private(set) var source: MediaSource?
    @Published private(set) var engine = PlaybackEngine.direct
    @Published private(set) var plan: PlaybackPlan?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var audioIndex: Int?
    @Published private(set) var subtitleIndex: Int?
    @Published private(set) var nextEpisode: BaseItem?
    @Published private(set) var intro: ClosedRange<Double>?
    @Published private(set) var creditsStart: Double?
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var trickplay: TrickplayInfo?
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var subtitleDelay: Double = 0
    /// Short message shown over the video, e.g. when the pipeline changes.
    @Published var notice: String?
    /// Shown on the loading screen while the connection is measured.
    @Published private(set) var status: String?
    @Published private(set) var stats = PlaybackStats()
    /// 0 = original, 1 = original without unused audio tracks, otherwise a limit in Mbit/s.
    @Published private(set) var quality = 0
    /// What reaches the screen, e.g. "Dolby Vision · Profil 7 als 8.1".
    @Published private(set) var outputVideo: String?
    /// Which of the engine's pipelines plays: Apple's player (repackaged on the Apple TV or a server stream) or software.
    @Published private(set) var route: VideoRoute = .none

    /// The engine; nil only if it couldn't be created, which `start` reports.
    private(set) var aether: AetherEngine!
    /// ASS/SSA tracks render through libass with the file's own fonts instead of the engine's plain cues.
    let assOverlay = ASSOverlayModel()

    /// The pipeline in words.
    var streamTitle: String {
        if plan?.maxBitrate != nil { return String(localized: "Apple-Player · vom Server umgerechnet", comment: "Apple-Player = Apple's AVPlayer") }
        if engine == .server { return String(localized: "Apple-Player · vom Server verpackt, Bild original") }
        switch route {
        case .loopback: return String(localized: "Apple-Player · Originaldatei, auf dem Apple TV umverpackt")
        case .software: return String(localized: "Software-Decoder · Originaldatei")
        case .remoteBypass: return String(localized: "Apple-Player · Originaldatei")
        default: return String(localized: "Originaldatei", comment: "The original media file (not a server stream)")
        }
    }

    private let client: JellyfinClient
    private let userID: String
    private var preference = EnginePreference.automatic
    private var playSessionID: String?
    private var directSessionID: String?
    private var didReportStart = false
    private var reportTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var introTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var thumbnails: [Int: UIImage] = [:]
    /// Subtitle files registered with the engine for the current stream, by Jellyfin stream index.
    private var externalTracks: [Int: Int] = [:]
    /// The ASS track libass draws; it keeps running across stream switches, the script doesn't depend on the stream.
    private var assTrack: Int?
    /// The plan before any adaptation to the connection, to return to "Original".
    private var originalPlan: PlaybackPlan?
    /// Buffering right after a jump the viewer asked for is expected, not a stall.
    private var lastSeek = Date.distantPast
    private var lastBytes: (bytes: Int64, time: Date)?
    /// Bytes per interval the engine pulled from the server, for the line's rate while it delivers.
    private var transfers: [(date: Date, bytes: Int64, seconds: Double)] = []
    private var droppedSamples: [(Date, Int)] = []
    private var stallHintShown = false
    private var stallTimes: [Date] = []
    private var bufferingSince: Date?
    private var stalling = false
    /// Whether the current stream has played at all; errors before that mean the file, after that the connection.
    private var streamStarted = false
    private var reconnectAttempts = 0
    private var reconnecting = false
    private var stopped = false
    /// The viewer picked a quality in the panel; Jelly then never changes it on its own.
    private var qualityChosenByViewer = false
    private var adaptedDuringPlayback = false
    /// A better stream the line has carried for a while, waiting for a quiet moment: a jump, a pause or the next chapter.
    private var pendingUpgrade: (plan: PlaybackPlan, line: Double)?
    /// How long the line has to stay fast before Jelly steps back up; doubles whenever an upgrade had to be undone.
    private var upgradeWait: TimeInterval = 300
    private var upgradedDuringPlayback = false
    /// What the player received while playing, since the last stall or stream switch.
    private var lineSamples: [(date: Date, rate: Double)] = []

    init(item: BaseItem, client: JellyfinClient, userID: String) {
        self.item = item
        self.client = client
        self.userID = userID
        aether = try? AetherEngine()
    }

    /// Audio delay works where the engine holds the timestamps; a server stream belongs to Apple's player.
    var canDelayAudio: Bool { engine == .direct }

    var audioOptions: [TrackOption] {
        (source?.audioStreams ?? []).map { stream in
            let detail = [stream.languageName == nil ? nil : stream.title, TechInfo.audioFormat(stream), TechInfo.channels(stream)]
            return TrackOption(id: stream.index, title: stream.languageName ?? stream.title ?? String(localized: "Tonspur \(stream.index)"),
                               detail: detail.compactMap { $0 }.joined(separator: " · ").nonEmpty)
        }
    }

    var subtitleOptions: [TrackOption] {
        [TrackOption(id: -1, title: String(localized: "Aus", comment: "Subtitles off"))] + (source?.subtitleStreams ?? []).map { stream in
            let switches = engine == .server && stream.isImageSubtitle
            let detail = [stream.languageName == nil ? nil : stream.title,
                          stream.isForced == true ? String(localized: "Erzwungen", comment: "Forced subtitles") : nil,
                          stream.isExternal == true ? String(localized: "Extern", comment: "Subtitles from a separate file") : nil,
                          stream.subtitleFormat,
                          switches ? String(localized: "Originaldatei", comment: "The original media file (not a server stream)") : nil]
            return TrackOption(id: stream.index, title: stream.languageName ?? stream.title ?? String(localized: "Untertitel \(stream.index)"),
                               detail: detail.compactMap { $0 }.joined(separator: " · ").nonEmpty)
        }
    }

    /// What reaches the receiver, for the info panel.
    var audioOutput: String? {
        guard let stream = source?.audioStreams.first(where: { $0.index == audioIndex }), let aether else { return nil }
        let format = TechInfo.audioFormat(stream) ?? "", channels = TechInfo.channels(stream) ?? ""
        if plan?.maxBitrate != nil { return String(localized: "AAC · vom Server umgerechnet") }
        switch aether.audioDelivery {
        case .streamCopy, .playerManaged:
            return TechInfo.isAtmosPassthrough(stream) ? "Dolby Atmos (Bitstream)" : String(localized: "\(format) \(channels) · unverändert")
        case .bridged:
            return bridgeMode == .lossless ? String(localized: "Verlustfrei · PCM \(channels)")
                : String(localized: "Dolby Digital+ \(channels) · umgewandelt")
        case .decoded:
            return String(localized: "PCM \(channels) · auf dem Apple TV decodiert")
        case .droppedNoPipeline:
            return String(localized: "Diese Tonspur kann nicht wiedergegeben werden")
        default:
            return nil
        }
    }

    /// Codecs that can't travel into Apple's player as they are (TrueHD, DTS …) become lossless PCM for a receiver,
    /// Dolby Digital+ for two speakers.
    private var bridgeMode: AudioBridgeMode {
        AVAudioSession.sharedInstance().maximumOutputNumberOfChannels > 2 ? .lossless : .surroundCompat
    }

    // MARK: Start

    func start(fromBeginning: Bool, mediaSourceID: String?, preference: EnginePreference, audioLanguage: String?) async {
        phase = .preparing
        self.preference = preference
        guard aether != nil else {
            phase = .failed(String(localized: "Der Player konnte nicht gestartet werden."))
            return
        }
        bindEngine()
        do {
            let info: JellyfinClient.PlaybackInfoResponse
            if mediaSourceID == nil, let prepared = Self.prepared.removeValue(forKey: item.id), Date().timeIntervalSince(prepared.date) < 600 {
                item = prepared.item
                info = prepared.info
            } else {
                async let fullItem = try? client.item(user: userID, id: item.id)
                info = try await client.playbackInfo(user: userID, itemID: item.id, mediaSourceID: mediaSourceID)
                if let full = await fullItem { item = full }
            }
            guard let source = info.mediaSources.first(where: { $0.id == mediaSourceID }) ?? info.mediaSources.first(where: { $0.requiresOpening != true })
                ?? info.mediaSources.first else { throw JellyError.unsupported }
            self.source = source

            // Series memory beats the device language, which beats Jellyfin's file default.
            let memory = item.seriesId.flatMap { TrackMemory.load(seriesID: $0) }
            audioIndex = memory?.audioIndex(in: source) ?? TrackPreference.audioIndex(for: source, userLanguage: audioLanguage)
            var subtitleChoice = memory?.subtitleIndex(in: source) ?? source.defaultSubtitleStreamIndex ?? -1
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let index = env["JELLY_SUBTITLE"].flatMap(Int.init) { subtitleChoice = index }
            if env["JELLY_SUBTITLE"] == "ass", let ass = source.subtitleStreams.first(where: \.isASS) { subtitleChoice = ass.index }
            #endif
            let audio = source.audioStreams.first { $0.index == audioIndex }
            let subtitle = source.subtitleStreams.first { $0.index == subtitleChoice }

            var start = fromBeginning || item.progress > 0.97 ? 0 : item.resumeSeconds
            #if DEBUG
            if let fromEnd = env["JELLY_FROM_END"].flatMap(Double.init) {
                start = max(0, Ticks.seconds(source.runTimeTicks ?? item.runTimeTicks) - fromEnd)
            }
            if let value = env["JELLY_START"].flatMap(Double.init) { start = value }
            if let wait = env["JELLY_UPGRADE_WAIT"].flatMap(Double.init) { upgradeWait = wait }
            #endif
            directSessionID = info.playSessionId
            playSessionID = info.playSessionId
            var plan = PlaybackPlan.make(for: source, audio: audio)
            originalPlan = plan
            plan = await adaptToConnection(plan, source: source, audio: audio)
            #if DEBUG
            if env["JELLY_PLAN"] == "compact" { plan = .compact(audio: audio) }
            // Starts as if Jelly had lowered the quality itself, to try stepping back up on a fast line.
            if let limit = env["JELLY_LIMIT"].flatMap(Int.init) {
                plan = .limited(limit * 1_000_000)
                quality = limit
            }
            #endif
            Diagnostics.log("play \"\(item.name)\" \(source.container ?? "?") \(source.video?.codecName ?? "?")/"
                + "\(source.video?.videoRangeType ?? "?") audio=\(audio?.codecName ?? "-")/\(audio?.profile ?? "") "
                + "sub=\(subtitle?.codecName ?? "off") plan=\(plan.engine.rawValue) \"\(plan.reason)\"")
            duration = Ticks.seconds(source.runTimeTicks ?? item.runTimeTicks)
            position = start
            chapters = item.chapters ?? []
            trickplay = Self.bestTrickplay(item.trickplay?[source.id])
            subtitleIndex = subtitle?.index
            try await open(plan, at: start)
            Task { await loadExtras() }
        } catch is CancellationError {
            return
        } catch {
            Diagnostics.log("start failed \"\(item.name)\": \(error)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func bestTrickplay(_ layouts: [String: TrickplayInfo]?) -> TrickplayInfo? {
        layouts?.values.min { abs($0.width - 320) < abs($1.width - 320) }
    }

    /// Opens `newPlan` at `seconds` – the start, a quality change, a reconnect. The server only packages for the
    /// compact and limited plans; if it would re-encode without a limit, the original file plays instead.
    /// `paused` keeps a paused film paused on the new stream.
    private func open(_ newPlan: PlaybackPlan, at seconds: Double, paused: Bool = false) async throws {
        guard let source, let aether else { return }
        var plan = newPlan
        let previous = engine == .server ? playSessionID : nil
        var url = client.streamURL(itemID: item.id, source: source, playSessionID: directSessionID)
        var session = directSessionID
        if plan.engine == .server {
            do {
                let stream = try await client.remuxStream(user: userID, itemID: item.id, sourceID: source.id, audioIndex: audioIndex, plan: plan)
                url = stream.url
                session = stream.playSessionID
                Diagnostics.log("server stream reasons=\(stream.reasons.joined(separator: ",")) audio=\(plan.remuxAudio)")
            } catch {
                // Never accept re-encoded video without a limit: play the original file instead.
                Diagnostics.log("server stream refused: \(error) → original")
                plan = PlaybackPlan.make(for: source, audio: source.audioStreams.first { $0.index == audioIndex })
            }
        }
        self.plan = plan
        engine = plan.engine
        playSessionID = session
        stats.required = plan.requiredBitrate(source: source, audio: source.audioStreams.first { $0.index == audioIndex })
        pendingUpgrade = nil
        lineSamples.removeAll()
        transfers.removeAll()
        lastBytes = nil
        externalTracks = [:]
        streamStarted = false

        var options = LoadOptions()
        options.httpHeaders = ["Authorization": client.authorization]
        options.matchContentEnabled = DisplayCapabilities.current().matchingEnabled
        options.audioBridgeMode = bridgeMode
        options.autoplay = !paused
        options.audioDelaySeconds = audioDelay
        options.preferredDecodePath = preference == .software ? .software : .automatic
        // A server stream is HLS: straight to Apple's player, no probing as a file first.
        options.nativeRemoteHLS = plan.engine == .server
        // The original file, repackaged on the Apple TV: hand Apple's player each piece while it is still being written,
        // so a jump on a slow line (files with keyframes far apart) waits for the first fragment rather than the whole
        // piece – and AVPlayer doesn't give up after 4 s and ask again. Reading about two minutes ahead (instead of 40 s)
        // usually has the end of an intro cached before "Intro überspringen" is pressed.
        options.progressiveSegmentDelivery = true
        options.forwardBufferSegments = 30
        // The engine picks the stream index Jellyfin names; a server stream carries only that one track.
        let audioStream = plan.engine == .direct ? audioIndex.map(Int32.init) : nil
        _ = try await aether.load(url: url, startPosition: seconds > 1 ? seconds : nil, options: options, audioSourceStreamIndex: audioStream)
        if let previous { await client.stopEncoding(playSessionID: previous) }
        if let index = subtitleIndex { showSubtitle(index) }
    }

    /// Big files from a server outside the home network: measure what the line really delivers (cached for 30 min)
    /// and pick the best stream that fits, unless the viewer insists on the original.
    private func adaptToConnection(_ plan: PlaybackPlan, source: MediaSource, audio: MediaStream?) async -> PlaybackPlan {
        let policy = SlowConnectionPolicy(rawValue: UserDefaults.standard.string(forKey: "slowConnection") ?? "") ?? .adapt
        let required = plan.requiredBitrate(source: source, audio: audio)
        stats.required = required
        guard required > 15_000_000, !ServerLocator.isPrivate(client.server) else { return plan }
        if NetworkProbe.recent(for: client.server) == nil { status = String(localized: "Verbindung wird geprüft …") }
        let measured: NetworkProbe.Result?
        if let recent = NetworkProbe.recent(for: client.server) {
            measured = recent
        } else {
            measured = await NetworkProbe.measure(client: client, itemID: item.id, source: source)
        }
        status = nil
        guard let measured else { return plan }
        stats.capacity = measured.throughput
        let fitted = plan.fitting(source: source, audio: audio, throughput: measured.throughput)
        guard fitted != plan else { return plan }
        if policy == .adapt { stats.required = fitted.requiredBitrate(source: source, audio: audio) }
        let line = String(format: "%.0f", measured.megabits), need = String(format: "%.0f", required / 1_000_000)
        if policy == .original {
            notice = String(localized: "Deine Verbindung schafft \(line) von \(need) Mbit/s – es kann stocken")
            return plan
        }
        quality = fitted.maxBitrate.map { $0 / 1_000_000 } ?? 1
        notice = fitted.maxBitrate == nil
            ? String(localized: "Leitung: \(line) Mbit/s – Jelly lässt ungenutzte Tonspuren weg, das Bild bleibt original")
            : String(localized: "Leitung: \(line) von \(need) Mbit/s – angepasste Qualität. Original unter ↓ › Qualität",
                     comment: "↓ › Qualität: swipe down, then the Quality tab of the player panel")
        Diagnostics.log("adapt \(line)/\(need) Mbit/s → \(fitted.reason)")
        return fitted
    }

    // MARK: Engine state

    private func bindEngine() {
        guard let aether else { return }
        subscriptions.removeAll()
        aether.$playbackPhase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.handle(phase) }
            .store(in: &subscriptions)
        aether.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.tick(time) }
            .store(in: &subscriptions)
        aether.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, value.isFinite, value > 0, abs(value - self.duration) > 1 else { return }
                self.duration = value
            }
            .store(in: &subscriptions)
        aether.$videoRoute
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in self?.route = route }
            .store(in: &subscriptions)
        Publishers.CombineLatest3(aether.$videoFormat, aether.$sourceDVProfile, aether.$dolbyVisionConversion)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format, profile, conversion in
                self?.outputVideo = Self.describe(format, profile: profile, conversion: conversion)
            }
            .store(in: &subscriptions)
    }

    private static func describe(_ format: VideoFormat, profile: Int?, conversion: DolbyVisionConversion?) -> String {
        switch format {
        case .dolbyVision:
            if conversion == .profile7ToProfile81 { return String(localized: "Dolby Vision · Profil 7 als 8.1") }
            return profile.map { String(localized: "Dolby Vision · Profil \($0)") } ?? "Dolby Vision"
        case .hdr10Plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .sdr: return "SDR"
        }
    }

    private func handle(_ engineState: PlaybackPhase) {
        guard !stopped else { return }
        switch engineState {
        case .loading:
            isBuffering = true
        case .playing:
            isPlaying = true
            isBuffering = false
            stalling = false
            bufferingSince = nil
            let first = !streamStarted
            streamStarted = true
            if reconnecting {
                reconnecting = false
                reconnectAttempts = 0
                notice = nil
                Diagnostics.log("reconnected at \(Int(position))s")
            }
            if phase == .preparing { phase = .playing }
            if first { logReady() }
            if !didReportStart {
                didReportStart = true
                Task { await report(.start) }
                startReporting()
                startStats()
            } else {
                Task { await report(.progress) }
            }
        case .paused:
            if phase == .preparing, streamStarted || aether?.hasFirstFrameReadyForDisplay == true { phase = .playing }
            let wasPlaying = isPlaying
            isPlaying = false
            isBuffering = false
            stalling = false
            if wasPlaying { Task { await report(.progress) } }
        case .seeking:
            isBuffering = true
        case .rebuffering, .stalled:
            isPlaying = true
            isBuffering = true
            if bufferingSince == nil { bufferingSince = Date() }
            // A stall is buffering the viewer didn't ask for: not at the start, not right after a jump.
            if !stalling, phase == .playing, streamStarted, Date().timeIntervalSince(lastSeek) > 4 {
                stalling = true
                recordStall()
            }
        case .ended:
            isPlaying = false
            isBuffering = false
            phase = .ended
        case .error(let message):
            let kind = aether?.errorInfo.map { "\($0.kind)" } ?? "?"
            Diagnostics.log("player error \(kind) at \(Int(position))s started=\(streamStarted): \(message)")
            if streamStarted || reconnecting {
                // It played before, so the file is fine: the connection dropped.
                Task { await reconnect() }
            } else if engine == .server, let originalPlan {
                // Apple's player refused the server's package, or it never arrived: the original file instead.
                notice = nil
                quality = 0
                Task { try? await open(originalPlan, at: position) }
            } else {
                phase = .failed(String(localized: "Die Datei konnte nicht geöffnet werden."))
            }
        case .idle:
            break
        }
    }

    private func logReady() {
        guard let aether else { return }
        Diagnostics.log("ready route=\(aether.videoRoute.rawValue) video=\(outputVideo ?? "?") decoder=\(aether.activeVideoDecoder ?? "?") "
            + "audio=\(aether.activeAudioDecoder ?? "?") delivery=\(aether.audioDelivery.rawValue) "
            + "outChannels=\(AVAudioSession.sharedInstance().outputNumberOfChannels)")
    }

    private func tick(_ current: Double) {
        guard current.isFinite, !stopped, streamStarted || current > 0 else { return }
        // A new chapter is a scene change: the least noticeable moment for the short reload of an upgrade.
        if pendingUpgrade != nil, isPlaying, current > position, current - position < 2,
           chapters.contains(where: { $0.start > 1 && $0.start > position && $0.start <= current }) {
            upgrade(at: current, moment: "chapter")
        }
        if abs(current - position) >= 0.5 { position = current }
        if !nextPrepared, nextEpisode != nil, duration > 0,
           current > (creditsStart ?? duration) - 45 || duration - current < 120 {
            prepareNextEpisode()
        }
    }

    // MARK: Quality

    var qualityOptions: [TrackOption] {
        guard let source else { return [] }
        let audio = source.audioStreams.first { $0.index == audioIndex }
        let original = Double(source.bitrate ?? 0) / 1_000_000
        var options = [TrackOption(id: 0, title: String(localized: "Original", comment: "Quality: the original file"),
                                   detail: original > 0 ? String(localized: "\(original, specifier: "%.0f") Mbit/s · Datei unverändert") : nil)]
        if let compact = PlaybackPlan.compactBitrate(source: source, audio: audio), Double(compact) / 1_000_000 < original - 2 {
            let rate = Double(compact) / 1_000_000
            let detail = String(localized: "\(rate, specifier: "%.0f") Mbit/s · verlustfrei, der Server lässt ungenutzte Spuren weg")
            options.append(TrackOption(id: 1, title: String(localized: "Original, nur gewählte Tonspur"), detail: detail))
        }
        for limit in [40, 30, 20, 15, 10, 6] where Double(limit) < original {
            options.append(TrackOption(id: limit, title: String(localized: "Höchstens \(limit) Mbit/s"),
                                       detail: String(localized: "Der Server rechnet das Bild herunter")))
        }
        return options
    }

    func selectQuality(_ id: Int) {
        guard id != quality, let source, let base = originalPlan else { return }
        let audio = source.audioStreams.first { $0.index == audioIndex }
        let plan: PlaybackPlan = id == 0 ? base : id == 1 ? .compact(audio: audio) : .limited(id * 1_000_000)
        quality = id
        qualityChosenByViewer = true
        reload(plan, at: currentTime, paused: !isPlaying)
    }

    /// The engine's own clock, read directly; `position` follows it at half-second steps.
    private var currentTime: Double {
        let time = aether?.clock.currentTime ?? position
        return time.isFinite && time > 1 ? time : position
    }

    private func reload(_ plan: PlaybackPlan, at seconds: Double, paused: Bool) {
        Diagnostics.log("reload at \(Int(seconds))s → \(plan.engine.rawValue) \"\(plan.reason)\"")
        Task {
            do { try await open(plan, at: seconds, paused: paused) } catch is CancellationError {} catch {
                Diagnostics.log("reload failed: \(error)")
                await reconnect()
            }
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        guard let aether else { return }
        if isPlaying {
            aether.pause()
            if pendingUpgrade != nil { upgradeWhilePaused() }
        } else {
            aether.play()
        }
    }

    func pause() { aether?.pause() }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 2) : seconds)
        position = target
        lastSeek = Date()
        // A jump buffers anyway, so a better stream that is waiting costs nothing extra here.
        if pendingUpgrade != nil {
            upgrade(at: target, moment: "jump")
            return
        }
        Task { await aether?.seek(to: target) }
    }

    func stop() {
        stopped = true
        reportTask?.cancel()
        statsTask?.cancel()
        introTask?.cancel()
        position = currentTime
        assOverlay.stop()
        aether?.stop()
        let report = progressReport(paused: true)
        let client = client
        let reportStop = didReportStart && Self.reportsProgress
        let packagingSession = engine == .server ? playSessionID : nil
        Task.detached {
            if reportStop { try? await client.report(.stopped, report) }
            await client.stopEncoding(playSessionID: packagingSession)
        }
        subscriptions.removeAll()
    }

    // MARK: Interruptions

    /// The TV button or the Apple TV going to sleep: pause and tell the server exactly where the film stands, so
    /// "Weiterschauen" is right even if tvOS ends the app later.
    func enterBackground() {
        guard phase == .playing, !stopped else { return }
        position = currentTime
        aether?.pause()
        Diagnostics.log("background at \(Int(position))s")
        Task { await report(.progress, paused: true) }
    }

    /// Back from the home screen: tvOS released the picture meanwhile, so the stream reopens at the same second, paused.
    func enterForeground() {
        guard let aether, phase == .playing, !stopped, aether.needsForegroundVideoRestore else { return }
        Diagnostics.log("foreground restore at \(Int(position))s")
        Task {
            do {
                try await aether.reloadAtCurrentPosition { $0.autoplay = false }
            } catch {
                Diagnostics.log("foreground restore failed: \(error)")
                if let plan { try? await open(plan, at: position, paused: true) }
            }
        }
    }

    /// A dropped connection mid-film: open the same stream again at the same second, up to three times
    /// with growing pauses, before showing an error.
    private func reconnect() async {
        guard !stopped, let plan else { return }
        guard reconnectAttempts < 3 else {
            reconnecting = false
            Diagnostics.log("reconnect gave up at \(Int(position))s")
            phase = .failed(String(localized: "Die Verbindung zum Server ist abgebrochen."))
            return
        }
        reconnectAttempts += 1
        reconnecting = true
        notice = String(localized: "Verbindung unterbrochen – Jelly verbindet neu …")
        Diagnostics.log("reconnect #\(reconnectAttempts) at \(Int(position))s")
        try? await Task.sleep(for: .seconds(Double(1 << reconnectAttempts)))
        guard !stopped else { return }
        do {
            try await open(plan, at: position)
        } catch {
            Diagnostics.log("reconnect #\(reconnectAttempts) failed: \(error)")
            await reconnect()
        }
    }

    /// Buffering that doesn't end: a slower line gets a fitting quality, otherwise the stream is opened again.
    private func recoverFromHang() async {
        guard !reconnecting, !stopped else { return }
        bufferingSince = nil
        Diagnostics.log("hang at \(Int(position))s")
        if await adaptDuringPlayback() { return }
        await reconnect()
    }

    private var adaptsToConnection: Bool {
        (SlowConnectionPolicy(rawValue: UserDefaults.standard.string(forKey: "slowConnection") ?? "") ?? .adapt) == .adapt
    }

    /// The line got slower during the film (e.g. busy evenings): pick the best stream that fits now – only with
    /// "anpassen" and only if the viewer hasn't chosen a quality; again only after Jelly stepped back up in between.
    /// While stalling the engine downloads as fast as it can, so its own rate shows what the line manages.
    private func adaptDuringPlayback() async -> Bool {
        guard adaptsToConnection, !qualityChosenByViewer, !adaptedDuringPlayback, let source, let current = plan,
              let base = originalPlan, let line = stats.throughput, line > 0 else { return false }
        let audio = source.audioStreams.first { $0.index == audioIndex }
        let fitted = base.fitting(source: source, audio: audio, throughput: line)
        guard fitted.requiredBitrate(source: source, audio: audio) < current.requiredBitrate(source: source, audio: audio) * 0.9
        else { return false }
        adaptedDuringPlayback = true
        // The last upgrade came too early: wait twice as long before the next one.
        if upgradedDuringPlayback { upgradeWait *= 2 }
        stallHintShown = true
        stats.capacity = line
        quality = fitted.maxBitrate.map { $0 / 1_000_000 } ?? 1
        notice = String(localized:
            "Leitung gerade bei \(line / 1_000_000, specifier: "%.0f") Mbit/s – Jelly schaltet auf angepasste Qualität. Original unter ↓ › Qualität",
            comment: "↓ › Qualität: swipe down, then the Quality tab of the player panel")
        Diagnostics.log(String(format: "adapt during playback at %.0fs: line %.1f Mbit → %@", position, line / 1_000_000, fitted.reason))
        // The next film starts with the line as it is now instead of an older, faster measurement.
        NetworkProbe.remember(throughput: line, for: client.server)
        reload(fitted, at: currentTime, paused: false)
        return true
    }

    /// The line has carried clearly more than the reduced stream for `upgradeWait` without a stall: keep the better
    /// stream ready for the next quiet moment. Only for reductions Jelly made itself, and not in the last ten minutes,
    /// where a reload costs more than it brings. The slowest second of the window decides, so a brief peak doesn't count.
    private func checkForUpgrade(_ now: Date) {
        guard pendingUpgrade == nil, let current = plan, let limit = current.maxBitrate, adaptsToConnection, !qualityChosenByViewer,
              phase == .playing, !reconnecting, let source, let base = originalPlan, duration - position > 600,
              let first = lineSamples.first, now.timeIntervalSince(first.date) >= upgradeWait - 5,
              let line = lineSamples.map(\.rate).min() else { return }
        let audio = source.audioStreams.first { $0.index == audioIndex }
        let better = base.fitting(source: source, audio: audio, throughput: line)
        guard better != current, better.requiredBitrate(source: source, audio: audio) >= Double(limit) * 1.5 else { return }
        pendingUpgrade = (better, line)
        NetworkProbe.remember(throughput: line, for: client.server)
        Diagnostics.log(String(format: "upgrade ready at %.0fs: line %.1f Mbit for %.0f s → %@", position, line / 1_000_000,
                               upgradeWait, better.reason))
    }

    /// Returns to the better stream at `seconds`. The short reload happens at a moment the viewer chose (jump, pause)
    /// or at a scene change, never in the middle of a scene.
    private func upgrade(at seconds: Double, moment: String, paused: Bool = false) {
        guard let (better, line) = pendingUpgrade, let base = originalPlan else { return }
        pendingUpgrade = nil
        upgradedDuringPlayback = true
        // Should the line drop again, Jelly may step down again.
        adaptedDuringPlayback = false
        stallTimes.removeAll()
        stats.capacity = line
        quality = better.maxBitrate.map { $0 / 1_000_000 } ?? (better == base ? 0 : 1)
        notice = better.maxBitrate.map {
            String(localized: "Leitung wieder bei \(line / 1_000_000, specifier: "%.0f") Mbit/s – bessere Qualität (bis \($0 / 1_000_000) Mbit/s)")
        } ?? String(localized: "Leitung wieder bei \(line / 1_000_000, specifier: "%.0f") Mbit/s – zurück zur Originalqualität")
        Diagnostics.log(String(format: "upgrade at %.0fs (%@): line %.1f Mbit → %@", seconds, moment, line / 1_000_000, better.reason))
        reload(better, at: seconds, paused: paused)
    }

    /// The viewer paused: if the film stays paused for a moment, switch to the better stream meanwhile.
    private func upgradeWhilePaused() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard pendingUpgrade != nil, !stopped, !isPlaying, phase == .playing, UIApplication.shared.applicationState == .active
            else { return }
            upgrade(at: currentTime, moment: "pause", paused: true)
        }
    }

    // MARK: Scrubbing thumbnails

    /// Thumbnail from Jellyfin's trickplay tiles (server setting "Trickplay-Bilder extrahieren").
    func thumbnail(at seconds: Double) async -> UIImage? {
        guard let info = trickplay, let source, info.interval > 0, info.thumbnailCount > 0 else { return nil }
        let index = min(info.thumbnailCount - 1, max(0, Int(seconds * 1000) / info.interval))
        if let cached = thumbnails[index] { return cached }
        let perTile = info.tileWidth * info.tileHeight
        let url = client.url("Videos/\(item.id)/Trickplay/\(info.width)/\(index / perTile).jpg", query: ["mediaSourceId": source.id])
        guard let tile = await ImagePipeline.shared.image(url, authorization: client.authorization)?.cgImage else { return nil }
        let cell = index % perTile
        let scale = CGFloat(tile.width) / CGFloat(info.width * info.tileWidth)
        let frame = CGRect(x: CGFloat(cell % info.tileWidth * info.width) * scale, y: CGFloat(cell / info.tileWidth * info.height) * scale,
                           width: CGFloat(info.width) * scale, height: CGFloat(info.height) * scale)
        guard let cropped = tile.cropping(to: frame) else { return nil }
        let image = UIImage(cgImage: cropped)
        thumbnails[index] = image
        return image
    }

    // MARK: Tracks

    /// Jellyfin numbers embedded streams the way the container does, like the engine; failing that, the n-th track of the kind.
    private func engineTrack(for stream: MediaStream, in tracks: [TrackInfo], among streams: [MediaStream]) -> Int? {
        let embedded = tracks.filter { !$0.isExternal }
        if embedded.contains(where: { $0.id == stream.index }) { return stream.index }
        guard let order = streams.filter({ $0.isExternal != true }).firstIndex(where: { $0.index == stream.index }),
              order < embedded.count else { return nil }
        return embedded[order].id
    }

    func selectAudio(_ index: Int) {
        remember(audio: index)
        guard index != audioIndex, let source, let aether, let stream = source.audioStreams.first(where: { $0.index == index }) else { return }
        audioIndex = index
        if engine == .server, var next = plan {
            // The server's package carries one audio track, so switching asks for a new package at the same second.
            if next.maxBitrate == nil { next = .compact(audio: stream) }
            reload(next, at: currentTime, paused: !isPlaying)
        } else if let id = engineTrack(for: stream, in: aether.audioTracks, among: source.audioStreams) {
            aether.selectAudioTrack(index: id)
        }
        Task { await report(.progress) }
    }

    func selectSubtitle(_ index: Int) {
        remember(subtitle: index)
        subtitleIndex = index >= 0 ? index : nil
        guard index >= 0, engine == .server, let base = originalPlan,
              source?.subtitleStreams.first(where: { $0.index == index })?.isImageSubtitle == true else {
            showSubtitle(index)
            return
        }
        // Picture subtitles exist only in the original file, not in the server's package.
        notice = String(localized: "Für diese Untertitel spielt Jelly die Originaldatei")
        qualityChosenByViewer = true
        quality = 0
        reload(base, at: currentTime, paused: !isPlaying)
    }

    /// Shows a subtitle track on the current stream: ASS through libass, everything else through the engine's cues –
    /// embedded tracks straight from the file, sidecar files (and every text track of a server stream) from Jellyfin.
    private func showSubtitle(_ index: Int) {
        guard let aether else { return }
        aether.clearSubtitle()
        let stream = index >= 0 ? source?.subtitleStreams.first(where: { $0.index == index }) : nil
        if let stream, stream.isASS, assTrack == stream.index, assOverlay.isActive { return }
        assOverlay.stop()
        assTrack = nil
        guard let source, let stream else { return }
        if stream.isASS {
            assTrack = stream.index
            Task { await startASS(stream) }
        } else if stream.isExternal == true || engine == .server {
            let id = externalTracks[stream.index] ?? {
                let track = aether.addExternalSubtitleTrack(ExternalSubtitleTrack(
                    url: client.subtitleURL(itemID: item.id, sourceID: source.id, stream: stream), name: stream.label,
                    language: stream.languageCode, isForced: stream.isForced ?? false))
                externalTracks[stream.index] = track.id
                return track.id
            }()
            aether.selectSubtitleTrack(index: id)
        } else if let id = engineTrack(for: stream, in: aether.subtitleTracks, among: source.subtitleStreams) {
            aether.selectSubtitleTrack(index: id)
        } else {
            Diagnostics.log("subtitle \(stream.index) not found among \(aether.subtitleTracks.map(\.id))")
        }
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = max(-2, min(2, (seconds * 20).rounded() / 20))
        aether?.setAudioDelay(audioDelay)
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (seconds * 10).rounded() / 10
        assOverlay.delay = subtitleDelay
    }

    /// Loads the full ASS script plus the fonts embedded in the file, then hands both to libass.
    private func startASS(_ stream: MediaStream) async {
        guard let source else { return }
        func fetch(_ url: URL) async -> Data? {
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue(client.authorization, forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        let hint = slowLoadingHint()
        defer { hint.cancel() }
        guard let script = await fetch(client.subtitleURL(itemID: item.id, sourceID: source.id, stream: stream)) else {
            notice = String(localized: "Untertitel konnten nicht geladen werden")
            return
        }
        var fonts: [(name: String, data: Data)] = []
        for attachment in (source.mediaAttachments ?? []).filter(\.isFont) {
            if let data = await fetch(client.url("Videos/\(item.id)/\(source.id)/Attachments/\(attachment.index)")) {
                fonts.append((attachment.fileName ?? "font\(attachment.index)", data))
            }
        }
        guard subtitleIndex == stream.index else { return }
        let video = CGSize(width: source.video?.width ?? 1920, height: source.video?.height ?? 1080)
        // The source time of the frame on screen, the axis ASS events are timed on.
        assOverlay.clock = { [weak self] in self?.aether?.clock.sourceTime ?? 0 }
        assOverlay.delay = subtitleDelay
        assOverlay.start(script: script, fonts: fonts, video: video, screen: UIScreen.main.bounds.size, scale: UIScreen.main.scale)
        Diagnostics.log("ass track \(stream.index) bytes=\(script.count) fonts=\(fonts.count) active=\(assOverlay.isActive)")
    }

    private func remember(audio: Int? = nil, subtitle: Int? = nil) {
        guard let seriesID = item.seriesId, let source else { return }
        var memory = TrackMemory.load(seriesID: seriesID) ?? TrackMemory(
            audioLanguage: source.audioStreams.first { $0.index == audioIndex }?.languageCode,
            subtitleLanguage: source.subtitleStreams.first { $0.index == subtitleIndex }?.languageCode)
        if let audio { memory.audioLanguage = source.audioStreams.first { $0.index == audio }?.languageCode }
        if let subtitle {
            let stream = source.subtitleStreams.first { $0.index == subtitle }
            memory.subtitleLanguage = stream?.languageCode
            memory.subtitleForced = stream?.isForced ?? false
        }
        memory.save(seriesID: seriesID)
    }

    /// The server extracts embedded subtitles from the whole file the first time, which can take a while.
    private func slowLoadingHint() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.notice = String(localized: "Untertitel werden vorbereitet – beim ersten Mal kann das etwas dauern")
        }
    }

    // MARK: Intro, credits, next episode

    private func loadExtras() async {
        if let seriesID = item.seriesId, item.isEpisode {
            nextEpisode = try? await client.nextEpisode(user: userID, seriesID: seriesID, after: item.id)
        }
        let segments = await client.mediaSegments(itemID: item.id)
        if let introSegment = segments.first(where: { $0.type == "Intro" }) {
            intro = Ticks.seconds(introSegment.startTicks)...Ticks.seconds(introSegment.endTicks)
        }
        if let outro = segments.first(where: { $0.type == "Outro" }) {
            creditsStart = Ticks.seconds(outro.startTicks)
        }
        // Without the Intro Skipper plugin, chapters named "Intro" or "Credits" do the same job.
        let sorted = chapters.sorted { $0.startPositionTicks < $1.startPositionTicks }
        let runtime = max(duration, item.runtimeSeconds)
        if intro == nil, let index = sorted.firstIndex(where: \.isIntro), index + 1 < sorted.count, sorted[index].start < runtime * 0.3 {
            intro = sorted[index].start...sorted[index + 1].start
        }
        if creditsStart == nil, let credits = sorted.last(where: \.isCredits), duration > 0, credits.start > duration * 0.7 {
            creditsStart = credits.start
        }
        // Otherwise Jelly finds intro and credits itself by comparing the sound with neighbouring episodes – also more
        // exact than chapters.
        let findsIntro = !segments.contains { $0.type == "Intro" }
        let findsCredits = !segments.contains { $0.type == "Outro" }
        if item.isEpisode, findsIntro || findsCredits {
            introTask = Task { await findMarkers(intro: findsIntro, credits: findsCredits) }
        }
    }

    /// Stored results apply at once; a first analysis waits until playback has settled. Then the next episode's intro is
    /// prepared, so it's known from its first second, and finally this episode's credits, so "Nächste Folge" appears
    /// when they begin instead of at the very end.
    private func findMarkers(intro findsIntro: Bool, credits findsCredits: Bool) async {
        let finder = IntroFinder.shared
        if findsIntro {
            if let known = await finder.known(item.id, .intro) {
                if let known { intro = known }
            } else {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                if let found = await finder.find(.intro, for: item, client: client, user: userID) { intro = found }
            }
            if !Task.isCancelled, let next = nextEpisode, await finder.known(next.id, .intro) == nil {
                _ = await finder.find(.intro, for: next, client: client, user: userID)
            }
        }
        guard findsCredits, !Task.isCancelled, nextEpisode != nil else { return }
        let credits = await finder.find(.credits, for: item, client: client, user: userID)
        // Chapters may have filled the gap meanwhile; the sound comparison wins, it marks where the credits really start.
        if let credits, credits.lowerBound > position { creditsStart = credits.lowerBound }
    }

    private struct Prepared {
        let item: BaseItem
        let info: JellyfinClient.PlaybackInfoResponse
        let date: Date
    }

    /// The next episode's details and stream info, fetched while the credits run.
    private static var prepared: [String: Prepared] = [:]
    private var nextPrepared = false

    /// Fetches what the next episode needs to start – and measures the line if the file is big and the last
    /// measurement is old, while this one still has buffer to spare – so it starts right away.
    func prepareNextEpisode() {
        guard let next = nextEpisode, !nextPrepared else { return }
        nextPrepared = true
        let client = client, user = userID, spare = stats.bufferAhead ?? 0
        Task {
            async let full = try? client.item(user: user, id: next.id)
            guard let info = try? await client.playbackInfo(user: user, itemID: next.id), let item = await full else { return }
            Self.prepared = Self.prepared.filter { Date().timeIntervalSince($0.value.date) < 600 }
            Self.prepared[next.id] = Prepared(item: item, info: info, date: Date())
            Diagnostics.log("prepared next \"\(item.name)\"")
            if let source = info.mediaSources.first, Double(source.bitrate ?? 0) > 15_000_000, !ServerLocator.isPrivate(client.server),
               NetworkProbe.recent(for: client.server) == nil, spare > 15 {
                _ = await NetworkProbe.measure(client: client, itemID: next.id, source: source)
            }
        }
    }

    // MARK: Live statistics

    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sampleStats()
            }
        }
    }

    private func sampleStats() {
        guard let aether, !stopped else { return }
        var next = stats
        let now = Date()
        let telemetry = aether.diagnostics.liveTelemetry
        if route == .remoteBypass {
            // A server stream: Apple's player measures the line itself.
            if let mbps = telemetry?.networkThroughputMbps { next.throughput = mbps * 1_000_000 }
        } else if let bytes = telemetry?.demuxerBytesFetched {
            // The original file: what the engine pulls from the server, over the seconds it actually received data.
            // It reads ahead in bursts and rests while the buffer is full, so a plain average would understate the line.
            if let last = lastBytes, bytes >= last.bytes {
                transfers.append((now, bytes - last.bytes, now.timeIntervalSince(last.time)))
            }
            lastBytes = (bytes, now)
            transfers.removeAll { now.timeIntervalSince($0.date) > 10 }
            let active = transfers.filter { $0.bytes > 0 }
            let seconds = active.reduce(0) { $0 + $1.seconds }
            if seconds > 0.5 { next.throughput = Double(active.reduce(0) { $0 + $1.bytes }) * 8 / seconds }
        }
        next.displayFPS = telemetry?.observedFps
        if let dropped = telemetry?.droppedFrameCount { next.droppedFrames = dropped }
        next.avSyncMs = telemetry?.avSyncGapMs
        next.bufferAhead = telemetry?.forwardBufferSeconds ?? max(0, aether.clock.bufferedPosition - aether.clock.currentTime)
        droppedSamples.append((now, next.droppedFrames))
        droppedSamples.removeAll { now.timeIntervalSince($0.0) > 60 }
        if let first = droppedSamples.first, now.timeIntervalSince(first.0) > 5 {
            next.droppedPerMinute = Double(next.droppedFrames - first.1) * 60 / now.timeIntervalSince(first.0)
        }
        if next != stats { stats = next }
        if isPlaying, !isBuffering, streamStarted, let rate = next.throughput, rate > 0 { lineSamples.append((now, rate)) }
        lineSamples.removeAll { now.timeIntervalSince($0.date) > upgradeWait }
        checkForUpgrade(now)
        // 20 seconds of buffering without a jump the viewer asked for: the stream is stuck.
        if isBuffering, phase == .playing, streamStarted, !reconnecting, let since = bufferingSince,
           now.timeIntervalSince(since) > 20, now.timeIntervalSince(lastSeek) > 20 {
            Task { await recoverFromHang() }
        }
    }

    /// Repeated buffering on a line slower than the stream: say why and where to change it.
    private func recordStall() {
        stats.stalls += 1
        Diagnostics.log(String(format: "stall #%d at %.0fs buffer=%.1fs rate=%.1fMbit need=%.1fMbit", stats.stalls, position,
                               stats.bufferAhead ?? 0, (stats.throughput ?? 0) / 1_000_000, stats.required / 1_000_000))
        stallTimes.append(Date())
        stallTimes.removeAll { Date().timeIntervalSince($0) > 300 }
        // The line isn't reliably fast: the time it has to prove itself starts over.
        lineSamples.removeAll()
        if pendingUpgrade != nil {
            pendingUpgrade = nil
            Diagnostics.log("upgrade dropped after stall")
        }
        if stallTimes.count >= 2, !adaptedDuringPlayback, !qualityChosenByViewer {
            Task {
                // Give the stall a few seconds so the engine's download rate reflects the line.
                try? await Task.sleep(for: .seconds(3))
                if await adaptDuringPlayback() { return }
                showStallHint()
            }
            return
        }
        showStallHint()
    }

    private func showStallHint() {
        guard stats.stalls >= 2, !stallHintShown else { return }
        stallHintShown = true
        let available = stats.capacity ?? stats.throughput
        if let available, available < stats.required {
            let have = available / 1_000_000, need = stats.required / 1_000_000
            notice = String(localized: "Verbindung zu langsam: \(have, specifier: "%.0f") von \(need, specifier: "%.0f") Mbit/s – ↓ › Qualität",
                            comment: "↓ › Qualität: swipe down, then the Quality tab of the player panel")
        } else {
            notice = String(localized: "Die Wiedergabe stockt – Details unter ↓ › Info",
                            comment: "↓ › Info: swipe down, then the Info tab of the player panel")
        }
    }

    // MARK: Reporting

    private func startReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.report(.progress)
                tick += 1
                if tick % 3 == 0 { self?.logPerformance() }
            }
        }
    }

    /// Every 30 s: frame rate, dropped frames and the line, to judge e.g. software AV1 on real hardware.
    private func logPerformance() {
        guard isPlaying else { return }
        Diagnostics.log("perf \(route.rawValue) fps=\(stats.displayFPS.map { String(format: "%.1f", $0) } ?? "-") dropped=\(stats.droppedFrames) "
            + String(format: "line=%.1fMbit buffer=%.0fs stalls=%d", (stats.throughput ?? 0) / 1_000_000, stats.bufferAhead ?? 0, stats.stalls))
    }

    private func progressReport(paused: Bool) -> JellyfinClient.ProgressReport {
        JellyfinClient.ProgressReport(itemID: item.id, sourceID: source?.id ?? item.id, playSessionID: playSessionID,
                                      seconds: position, isPaused: paused, audioIndex: audioIndex, subtitleIndex: subtitleIndex,
                                      playMethod: plan?.playMethod ?? engine.playMethod)
    }

    /// Simulator test runs use a real account; they must not overwrite its "continue watching" positions.
    private static var reportsProgress: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["JELLY_REPORT"] != nil
        #else
        true
        #endif
    }

    private func report(_ kind: JellyfinClient.ReportKind, paused: Bool? = nil) async {
        guard Self.reportsProgress else { return }
        try? await client.report(kind, progressReport(paused: paused ?? !isPlaying))
    }
}

extension JellyfinClient {
    struct MediaSegment: Decodable {
        var type: String
        var startTicks: Int64
        var endTicks: Int64
    }

    /// Intro/credits markers (Jellyfin 10.10+, e.g. from the Intro Skipper plugin). Empty on older servers.
    func mediaSegments(itemID: String) async -> [MediaSegment] {
        struct Response: Decodable { var items: [MediaSegment] }
        let response: Response? = try? await get("MediaSegments/\(itemID)")
        return response?.items ?? []
    }

    func nextEpisode(user: String, seriesID: String, after episodeID: String) async throws -> BaseItem? {
        let page: ItemsResponse = try await get("Shows/\(seriesID)/Episodes", query: [
            "userId": user, "StartItemId": episodeID, "Limit": "2", "Fields": Self.listFields, "EnableUserData": "true"
        ])
        guard page.items.first?.id == episodeID, page.items.count > 1 else { return nil }
        return page.items[1]
    }
}
