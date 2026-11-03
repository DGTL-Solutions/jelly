import Foundation

/// The sizes a film or episode can be saved in on iPhone and iPad: the file itself, or a copy the server converts.
enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, better, good

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return String(localized: "Original", comment: "Download quality: the file itself")
        case .better: return String(localized: "Besser", comment: "Download quality: high, converted by the server")
        case .good: return String(localized: "Gut", comment: "Download quality: compact, converted by the server")
        }
    }

    /// Ceiling for the converted picture; nil for the original.
    var videoBitrate: Int? { [.better: 8_000_000, .good: 3_000_000][self] }
    var maxHeight: Int? { [.better: 1080, .good: 720][self] }
    var maxWidth: Int? { [.better: 1920, .good: 1280][self] }
    /// "Besser" keeps surround sound (copied when it is Dolby Digital, otherwise AAC 5.1); "Gut" is stereo.
    var audioChannels: Int { self == .good ? 2 : 6 }
    var audioBitrate: Int { self == .good ? 192_000 : 640_000 }
}

/// One choice in the download sheet: what it costs on the device and what it looks like.
struct DownloadOption: Identifiable, Equatable, Sendable {
    var quality: DownloadQuality
    var bytes: Int64
    /// "4K", "1080p", "720p".
    var resolution: String?
    /// Converted sizes are known only once the server has written them; the estimate is the ceiling.
    var isEstimate: Bool
    var id: DownloadQuality { quality }
}

enum DownloadPlanner {
    /// Left free on the device after a download, so the system and other apps keep breathing room.
    static let reserve: Int64 = 1_000_000_000
    /// A converted copy is only worth offering when it saves at least half of the next better one.
    static let worthwhileShare = 0.5

    /// The options for one file, best first. Smaller copies only appear when the step down is big.
    static func options(source: MediaSource, runtime: Double, audio: MediaStream?, canConvert: Bool = true) -> [DownloadOption] {
        let seconds = max(runtime, Ticks.seconds(source.runTimeTicks))
        let originalBytes = source.size ?? Int64(Double(source.bitrate ?? 0) * seconds / 8)
        var options = [DownloadOption(quality: .original, bytes: originalBytes, resolution: TechInfo.resolution(source.video), isEstimate: source.size == nil)]
        guard canConvert, seconds > 0 else { return options }
        let sourceVideo = source.video?.bitRate ?? source.bitrate.map { max(0, $0 - (audio?.bitRate ?? 0)) }
        for quality in [DownloadQuality.better, .good] {
            guard let ceiling = quality.videoBitrate, let maxHeight = quality.maxHeight else { continue }
            let video = min(ceiling, sourceVideo ?? ceiling)
            let copiesAudio = quality == .better && PlaybackPlan.copyableAudio.contains(audio?.codecName ?? "")
            let sound = copiesAudio ? audio?.bitRate ?? quality.audioBitrate : quality.audioBitrate
            let bytes = Int64(Double(video + sound) * seconds / 8)
            guard let previous = options.last, Double(bytes) <= Double(previous.bytes) * worthwhileShare else { continue }
            let height = min(maxHeight, source.video?.height ?? maxHeight)
            options.append(DownloadOption(quality: quality, bytes: bytes,
                                          resolution: TechInfo.resolution(MediaStream(type: "Video", index: 0, width: height * 16 / 9, height: height)),
                                          isEstimate: true))
        }
        return options
    }

    static func fits(_ option: DownloadOption, free: Int64?) -> Bool {
        guard let free else { return true }
        return option.bytes + reserve <= free
    }

    /// "Besser" when there is one – sharp on any iPhone or iPad screen at a fraction of the size –, otherwise the original;
    /// then the next smaller option that still fits.
    static func recommended(_ options: [DownloadOption], free: Int64?, preferred: DownloadQuality = .better) -> DownloadQuality? {
        let order = DownloadQuality.allCases
        let start = options.contains { $0.quality == preferred } ? preferred : .original
        guard let first = order.firstIndex(of: start) else { return nil }
        return order[first...].lazy.compactMap { quality in options.first { $0.quality == quality } }
            .first { fits($0, free: free) }?.quality
    }

    /// Text for a size: "4,2 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension DownloadPlanner {
    /// Several files at once: the sum per quality, each file contributing its own size or, without that option, the
    /// next larger one it has.
    static func combined(_ perItem: [[DownloadOption]]) -> [DownloadOption] {
        guard perItem.count != 1 else { return perItem.first ?? [] }
        return DownloadQuality.allCases.compactMap { quality in
            guard perItem.contains(where: { $0.contains { $0.quality == quality } }) else { return nil }
            let rank = DownloadQuality.allCases.firstIndex(of: quality)!
            let picks = perItem.compactMap { options in
                options.last { DownloadQuality.allCases.firstIndex(of: $0.quality)! <= rank }
            }
            return DownloadOption(quality: quality, bytes: picks.reduce(0) { $0 + $1.bytes },
                                  resolution: picks.first { $0.quality == quality }?.resolution,
                                  isEstimate: picks.contains(where: \.isEstimate))
        }
    }
}

/// What the player needs to play a download without the server: the file, its stream layout, sidecar subtitles and the
/// markers saved with it.
struct OfflineMedia: Equatable, Sendable {
    var file: URL
    var source: MediaSource
    /// Text subtitles saved next to the file, by Jellyfin stream index.
    var subtitles: [Int: URL] = [:]
    /// Fonts of the file's ASS tracks.
    var fonts: [URL] = []
    var intro: ClosedRange<Double>?
    var creditsStart: Double?
    var nextEpisode: BaseItem?
    /// The original file keeps every track at Jellyfin's index; a converted copy holds only the track it was saved with.
    var keepsStreamIndexes = true
}

extension JellyfinClient {
    /// The original through Jellyfin's download endpoint (it honours the profile's download permission), or a copy the
    /// server converts while it sends it: H.264 or HEVC – whichever the server may encode – in MP4, at most 1080p or 720p,
    /// with the chosen audio track and without subtitles (those are saved separately).
    func downloadURL(itemID: String, source: MediaSource, quality: DownloadQuality, audioIndex: Int?) -> URL {
        guard let videoBitrate = quality.videoBitrate, let maxWidth = quality.maxWidth, let maxHeight = quality.maxHeight else {
            return url("Items/\(itemID)/Download", query: ["mediaSourceId": source.id])
        }
        var query = [
            "Static": "false", "MediaSourceId": source.id, "DeviceId": deviceID, "PlaySessionId": UUID().uuidString,
            "VideoCodec": "hevc,h264", "VideoBitrate": "\(videoBitrate)", "MaxWidth": "\(maxWidth)", "MaxHeight": "\(maxHeight)",
            "AudioCodec": quality == .better ? "aac,ac3,eac3" : "aac", "MaxAudioChannels": "\(quality.audioChannels)",
            "AudioBitrate": "\(quality.audioBitrate)", "SubtitleMethod": "Drop", "EnableAutoStreamCopy": "true"
        ]
        if let audioIndex { query["AudioStreamIndex"] = "\(audioIndex)" }
        return url("Videos/\(itemID)/stream.mp4", query: query)
    }

    /// Raw answers kept with a download, decoded again when it plays offline.
    func itemData(user: String, id: String) async throws -> Data {
        do { return try await send("Items/\(id)", query: ["userId": user]) }
        catch JellyError.server(404) { return try await send("Users/\(user)/Items/\(id)") }
    }

    func playbackInfoData(user: String, itemID: String, mediaSourceID: String?) async throws -> Data {
        var body: [String: Any] = [
            "UserId": user, "DeviceProfile": Self.deviceProfile, "EnableDirectPlay": true, "EnableDirectStream": false,
            "EnableTranscoding": false, "AutoOpenLiveStream": false, "MaxStreamingBitrate": 1_000_000_000
        ]
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        return try await send("Items/\(itemID)/PlaybackInfo", method: "POST", query: ["userId": user], body: body)
    }

    /// Position and watched state measured while offline, sent once the server is reachable again.
    func saveUserData(user: String, itemID: String, seconds: Double, played: Bool) async throws {
        let body: [String: Any] = ["PlaybackPositionTicks": Ticks.from(seconds: seconds), "Played": played]
        do { _ = try await send("UserItems/\(itemID)/UserData", method: "POST", query: ["userId": user], body: body) }
        catch JellyError.server(404) {
            if played { try await setPlayed(user: user, id: itemID, true) }
        }
    }
}
