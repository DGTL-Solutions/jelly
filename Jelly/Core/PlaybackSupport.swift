import Foundation
import AVFoundation
import VideoToolbox

/// What this device decodes natively. Queried once at launch; injectable for tests.
struct DeviceCapabilities: Codable, Equatable {
    /// Dolby Vision profiles 5 and 8 (every Apple TV 4K; not the simulator or Apple TV HD).
    var dolbyVision: Bool
    /// Dual-layer profile 7 from UHD Blu-rays.
    var dolbyVisionProfile7: Bool
    var av1Hardware: Bool

    static let current: DeviceCapabilities = {
        func playable(_ codec: String) -> Bool { AVURLAsset.isPlayableExtendedMIMEType("video/mp4; codecs=\"\(codec)\"") }
        var capabilities = DeviceCapabilities(dolbyVision: playable("dvh1.05.06") && playable("dvh1.08.06"),
                                              dolbyVisionProfile7: playable("dvh1.07.06"),
                                              av1Hardware: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        #if DEBUG
        if ProcessInfo.processInfo.environment["JELLY_FORCE_REMUX"] != nil { capabilities.dolbyVision = true }
        #endif
        return capabilities
    }()
}

/// Which pipeline plays a file.
enum PlaybackEngine: String, CaseIterable, Identifiable {
    /// The original file, opened on the Apple TV by AetherEngine: Apple's player for H.264 and HEVC – Dolby Vision,
    /// HDR10+ and Atmos included, the container repackaged on the device –, its own decoders for everything else.
    case direct
    /// A stream the server packages: the original video with only the chosen audio track, or, when the viewer's line
    /// needs it, a conversion to a bitrate limit. Only used to save bandwidth.
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Originaldatei"
        case .server: return "Vom Server verpackt"
        }
    }

    var playMethod: String { self == .server ? "DirectStream" : "DirectPlay" }
}

/// The chosen pipeline plus how the server should package the stream and why.
struct PlaybackPlan: Equatable {
    var engine: PlaybackEngine
    /// Audio codecs offered to the server, in order of preference: copy when compatible, otherwise lossless FLAC.
    var remuxAudio = "eac3,ac3,aac"
    /// Set only away from home when the viewer chose a bitrate limit: the one case where the server may re-encode.
    var maxBitrate: Int?
    /// Short German reason shown in the player's info panel.
    var reason: String

    var playMethod: String { maxBitrate != nil ? "Transcode" : engine.playMethod }

    /// Server-side conversion to a bitrate the connection can carry – the only plan that re-encodes video.
    static func limited(_ limit: Int) -> PlaybackPlan {
        PlaybackPlan(engine: .server, remuxAudio: "aac,eac3,ac3", maxBitrate: limit, reason: "Angepasst an die Verbindung · höchstens \(limit / 1_000_000) Mbit/s")
    }

    /// The original video plus only the selected audio track, repackaged by the server (nothing re-encoded).
    static func compact(audio: MediaStream?) -> PlaybackPlan {
        let copies = copyableAudio.contains(audio?.codecName ?? "")
        return PlaybackPlan(engine: .server, remuxAudio: copies ? "eac3,ac3,aac" : "flac,eac3,ac3,aac",
                            reason: "Original ohne ungenutzte Tonspuren · verlustfrei")
    }

    /// Bits per second this plan pulls over the network.
    func requiredBitrate(source: MediaSource, audio: MediaStream?) -> Double {
        if let maxBitrate { return Double(maxBitrate) }
        if engine == .server, let compact = Self.compactBitrate(source: source, audio: audio) { return Double(compact) }
        return Double(source.bitrate ?? 0)
    }

    /// Video plus the chosen audio track, when the server reports per-stream bitrates.
    static func compactBitrate(source: MediaSource, audio: MediaStream?) -> Int? {
        guard let video = source.video, ["hevc", "h264"].contains(video.codecName), let videoRate = video.bitRate, videoRate > 0
        else { return nil }
        return videoRate + (audio?.bitRate ?? 0)
    }

    /// Keeps the original whenever the measured connection carries it with some headroom; otherwise the lossless
    /// compact stream if that fits, and only then a conversion sized to about 70 % of the measured throughput.
    func fitting(source: MediaSource, audio: MediaStream?, throughput: Double) -> PlaybackPlan {
        let headroom = 1.15
        if throughput >= requiredBitrate(source: source, audio: audio) * headroom { return self }
        if engine != .server, let compact = Self.compactBitrate(source: source, audio: audio),
           throughput >= Double(compact) * headroom, source.video?.isInterlaced != true {
            return Self.compact(audio: audio)
        }
        return Self.limited(max(4, Int(throughput * 0.7 / 1_000_000)) * 1_000_000)
    }

    static let copyableAudio: Set = ["aac", "ac3", "eac3"]

    /// Every file plays from the original; the reason names what the Apple TV gets out of it.
    static func make(for source: MediaSource, audio: MediaStream?, device: DeviceCapabilities = .current) -> PlaybackPlan {
        let audio = audio ?? TechInfo.defaultAudio(source)
        let range = source.video?.videoRangeType ?? ""
        var reasons: [String] = []
        if TechInfo.dynamicRange(source.video) == "Dolby Vision" {
            if !device.dolbyVision {
                reasons.append("Dolby Vision als HDR10")
            } else if source.video?.dvProfile == 7 || range.hasPrefix("DOVIWithEL") {
                reasons.append("Dolby Vision Profil 7 als 8.1")
            } else {
                reasons.append("Dolby Vision")
            }
        } else if range == "HDR10Plus" {
            reasons.append("HDR10+ dynamisch")
        }
        if TechInfo.isAtmosPassthrough(audio) { reasons.append("Dolby Atmos") }
        return PlaybackPlan(engine: .direct, reason: reasons.isEmpty ? "Originaldatei" : reasons.joined(separator: " · "))
    }
}

enum TrackPreference {
    /// Jellyfin's default already honours a language set in the user's profile. Without one,
    /// the Apple TV's own language beats the file's default track (German viewers get German audio).
    static func audioIndex(for source: MediaSource, userLanguage: String?,
                           deviceLanguage: String? = Locale.preferredLanguages.first.map { String($0.prefix(2)) }) -> Int? {
        let fallback = source.defaultAudioStreamIndex ?? source.audioStreams.first?.index
        guard userLanguage?.isEmpty ?? true, let device = deviceLanguage?.lowercased() else { return fallback }
        if source.audioStreams.first(where: { $0.index == fallback })?.languageCode == device { return fallback }
        let matches = source.audioStreams.filter { $0.languageCode == device }
        let best = matches.first { $0.isDefault == true } ?? matches.max { ($0.channels ?? 0) < ($1.channels ?? 0) }
        return best?.index ?? fallback
    }
}

/// Remembers the audio and subtitle language picked in a series, so the next episode starts the same way.
struct TrackMemory: Codable, Equatable {
    var audioLanguage: String?
    /// nil means subtitles off.
    var subtitleLanguage: String?
    var subtitleForced = false

    private static func key(_ seriesID: String) -> String { "trackMemory.\(seriesID)" }

    static func load(seriesID: String, defaults: UserDefaults = .standard) -> TrackMemory? {
        defaults.data(forKey: key(seriesID)).flatMap { try? JSONDecoder().decode(TrackMemory.self, from: $0) }
    }

    func save(seriesID: String, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(seriesID))
    }

    func audioIndex(in source: MediaSource) -> Int? {
        guard let audioLanguage else { return nil }
        let matches = source.audioStreams.filter { $0.languageCode == audioLanguage }
        return (matches.first { $0.index == source.defaultAudioStreamIndex } ?? matches.first { $0.isDefault == true }
            ?? matches.max { ($0.channels ?? 0) < ($1.channels ?? 0) })?.index
    }

    /// -1 for off, nil when the remembered language isn't available in this episode.
    func subtitleIndex(in source: MediaSource) -> Int? {
        guard let subtitleLanguage else { return -1 }
        let matches = source.subtitleStreams.filter { $0.languageCode == subtitleLanguage }
        return (matches.first { ($0.isForced ?? false) == subtitleForced } ?? matches.first)?.index
    }
}

/// Which decoder may play a file. "Immer Software" is the escape hatch for a file Apple's decoder handles badly.
enum EnginePreference: String, CaseIterable, Identifiable {
    case automatic
    case software = "ffmpeg"
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatisch (empfohlen)" : "Immer Software-Decoder" }
}

/// What to do when the measured connection can't carry the original file.
enum SlowConnectionPolicy: String, CaseIterable, Identifiable {
    case adapt, original
    var id: String { rawValue }
    var title: String { self == .adapt ? "Automatisch anpassen (empfohlen)" : "Immer Original (kann stocken)" }
}

enum SubtitleBackground: String, CaseIterable, Identifiable {
    case shadow, box
    var id: String { rawValue }
    var title: String { self == .shadow ? "Schatten" : "Box" }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow
    var id: String { rawValue }
    var title: String { self == .white ? "Weiß" : "Gelb" }
}

enum SubtitleSize: String, CaseIterable, Identifiable {
    case small, standard, large
    var id: String { rawValue }
    var title: String { ["small": "Klein", "standard": "Standard", "large": "Groß"][rawValue]! }
    var points: CGFloat { ["small": 46, "standard": 56, "large": 68][rawValue]! }
}

/// Human-readable technical labels for a media source ("4K", "Dolby Vision", "Dolby Atmos", "5.1").
enum TechInfo {
    static func resolution(_ video: MediaStream?) -> String? {
        guard let width = video?.width, let height = video?.height else { return nil }
        if width >= 3200 || height >= 2000 { return "4K" }
        if width >= 1900 || height >= 1000 { return "1080p" }
        if width >= 1200 || height >= 700 { return "720p" }
        return "SD"
    }

    static func dynamicRange(_ video: MediaStream?) -> String? {
        guard let video else { return nil }
        let type = video.videoRangeType ?? ""
        if type.hasPrefix("DOVI"), type != "DOVIInvalid" { return "Dolby Vision" }
        if (video.dvProfile ?? 0) > 0 { return "Dolby Vision" }
        switch type {
        case "HDR10Plus": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        default: return video.videoRange == "HDR" ? "HDR" : nil
        }
    }

    static func audioFormat(_ stream: MediaStream?) -> String? {
        guard let stream else { return nil }
        let profile = (stream.profile ?? "").lowercased()
        if profile.contains("atmos") { return "Dolby Atmos" }
        if profile.contains("dts:x") || profile.contains("dts-x") { return "DTS:X" }
        if profile.contains("dts-hd ma") { return "DTS-HD MA" }
        switch stream.codecName {
        case "truehd": return "Dolby TrueHD"
        case "eac3": return "Dolby Digital+"
        case "ac3": return "Dolby Digital"
        case "dts": return "DTS"
        case "flac": return "FLAC"
        case "aac": return "AAC"
        case "opus": return "Opus"
        default: return stream.codec?.uppercased()
        }
    }

    /// E-AC-3 with Atmos objects (JOC). Only Apple's player hands it to the receiver as Atmos;
    /// TrueHD Atmos can't leave an Apple TV as a bitstream at all.
    static func isAtmosPassthrough(_ stream: MediaStream?) -> Bool {
        guard let stream, stream.codecName == "eac3" else { return false }
        return (stream.profile ?? "").lowercased().contains("atmos")
    }

    static func channels(_ stream: MediaStream?) -> String? {
        guard let channels = stream?.channels else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) Kanäle"
        }
    }

    static func defaultAudio(_ source: MediaSource?) -> MediaStream? {
        guard let source else { return nil }
        return source.audioStreams.first { $0.index == source.defaultAudioStreamIndex }
            ?? source.audioStreams.first { $0.isDefault == true } ?? source.audioStreams.first
    }

    static func badges(_ source: MediaSource?) -> [String] {
        guard let source else { return [] }
        let audio = defaultAudio(source)
        var badges = [resolution(source.video), dynamicRange(source.video)].compactMap { $0 }
        if let format = audioFormat(audio), ["Dolby Atmos", "DTS:X", "DTS-HD MA", "Dolby TrueHD"].contains(format) { badges.append(format) }
        if let channels = channels(audio), channels == "5.1" || channels == "7.1" { badges.append(channels) }
        if !source.subtitleStreams.isEmpty { badges.append("UT") }
        return badges
    }

    static func videoDescription(_ video: MediaStream?) -> String? {
        guard let video else { return nil }
        var parts = [String]()
        if let width = video.width, let height = video.height { parts.append("\(width)×\(height)") }
        parts.append([video.codec?.uppercased(), video.profile].compactMap { $0 }.joined(separator: " "))
        if let range = dynamicRange(video) {
            parts.append(range + ((video.dvProfile).map { range == "Dolby Vision" ? " Profil \($0)" : "" } ?? ""))
        } else { parts.append("SDR") }
        if let fps = video.realFrameRate ?? video.averageFrameRate, fps > 0 { parts.append(String(format: "%.3g fps", fps)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func audioDescription(_ stream: MediaStream?) -> String? {
        guard let stream else { return nil }
        return [stream.languageName, audioFormat(stream), channels(stream)].compactMap { $0 }.joined(separator: " · ")
    }

    static func bitrate(_ source: MediaSource?) -> String? {
        guard let bitrate = source?.bitrate, bitrate > 0 else { return nil }
        return String(format: "%.1f Mbit/s", Double(bitrate) / 1_000_000)
    }
}
