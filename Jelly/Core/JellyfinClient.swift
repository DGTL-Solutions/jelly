import CryptoKit
import Foundation

struct JellyfinClient: Sendable {
    let server: URL
    var token: String?
    let deviceID: String
    /// Whether GET answers are read from or written to the disk cache (only the start screen uses it).
    var cache = ResponseCache.Mode.off

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    static let listFields = "Overview,PrimaryImageAspectRatio,Genres,ProviderIds"

    var authorization: String {
        var header = #"MediaBrowser Client="Jelly", Device="Apple TV", DeviceId="\#(deviceID)", Version="\#(Self.version)""#
        if let token, !token.isEmpty { header += #", Token="\#(token)""# }
        return header
    }

    // MARK: Transport

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    func send(_ path: String, method: String = "GET", query: [String: String] = [:], body: Any? = nil, timeout: TimeInterval = 20) async throws -> Data {
        let address = url(path, query: query)
        if method == "GET", cache == .only {
            guard let data = ResponseCache.read(address) else { throw JellyError.server(0) }
            return data
        }
        var request = URLRequest(url: address, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyError.server(0) }
        switch http.statusCode {
        case 200..<300:
            if method == "GET", cache == .store { ResponseCache.write(data, for: address) }
            return data
        case 401: throw JellyError.unauthorized
        case 403: throw JellyError.forbidden
        default: throw JellyError.server(http.statusCode)
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder.jellyfin.decode(T.self, from: await send(path, query: query))
    }

    /// Jellyfin 10.9 moved user-scoped routes. Older servers answer 404 on the new paths.
    private func send(_ path: String, legacy: String, method: String = "GET", query: [String: String] = [:]) async throws -> Data {
        do { return try await send(path, method: method, query: query) }
        catch JellyError.server(404) {
            var legacyQuery = query
            legacyQuery["userId"] = nil
            return try await send(legacy, method: method, query: legacyQuery)
        }
    }

    private func get<T: Decodable>(_ path: String, legacy: String, query: [String: String] = [:]) async throws -> T {
        try JSONDecoder.jellyfin.decode(T.self, from: await send(path, legacy: legacy, query: query))
    }

    // MARK: Authentication

    func publicInfo(timeout: TimeInterval = 8) async throws -> PublicSystemInfo {
        let data = try await send("System/Info/Public", timeout: timeout)
        let info = try JSONDecoder.jellyfin.decode(PublicSystemInfo.self, from: data)
        guard info.id != nil else { throw JellyError.serverNotFound }
        return info
    }

    func publicUsers() async throws -> [UserDto] {
        try await get("Users/Public")
    }

    func authenticate(username: String, password: String) async throws -> AuthenticationResult {
        try await signIn("Users/AuthenticateByName", body: ["Username": username, "Pw": password])
    }

    /// Jellyfin answers 403 after a correct password when the account is disabled or at its session limit.
    private func signIn(_ path: String, body: [String: String]) async throws -> AuthenticationResult {
        do {
            return try JSONDecoder.jellyfin.decode(AuthenticationResult.self, from: await send(path, method: "POST", body: body))
        } catch JellyError.forbidden {
            throw JellyError.loginRejected
        }
    }

    func quickConnectEnabled() async -> Bool {
        (try? JSONDecoder().decode(Bool.self, from: await send("QuickConnect/Enabled", timeout: 6))) ?? false
    }

    func quickConnectInitiate() async throws -> QuickConnectState {
        do {
            return try JSONDecoder.jellyfin.decode(QuickConnectState.self, from: await send("QuickConnect/Initiate", method: "POST"))
        } catch JellyError.server(let code) where code == 404 || code == 405 {
            return try await get("QuickConnect/Initiate")
        } catch JellyError.unauthorized, JellyError.forbidden {
            throw JellyError.quickConnectDisabled
        }
    }

    func quickConnectState(secret: String) async throws -> QuickConnectState {
        try await get("QuickConnect/Connect", query: ["secret": secret])
    }

    func authenticate(quickConnectSecret secret: String) async throws -> AuthenticationResult {
        try await signIn("Users/AuthenticateWithQuickConnect", body: ["Secret": secret])
    }

    func currentUser() async throws -> UserDto {
        try await get("Users/Me")
    }

    func logout() async {
        _ = try? await send("Sessions/Logout", method: "POST", timeout: 5)
    }

    // MARK: Library

    private func listQuery(_ user: String, _ extra: [String: String] = [:]) -> [String: String] {
        ["userId": user, "Fields": Self.listFields, "EnableUserData": "true", "ImageTypeLimit": "1",
         "EnableImageTypes": "Primary,Backdrop,Thumb,Logo"].merging(extra) { $1 }
    }

    func views(user: String) async throws -> [BaseItem] {
        let page: ItemsResponse = try await get("UserViews", legacy: "Users/\(user)/Views", query: ["userId": user])
        return page.items
    }

    func resume(user: String, limit: Int = 16) async throws -> [BaseItem] {
        let page: ItemsResponse = try await get("UserItems/Resume", legacy: "Users/\(user)/Items/Resume",
                                                query: listQuery(user, ["Limit": "\(limit)", "MediaTypes": "Video"]))
        return page.items
    }

    func nextUp(user: String, seriesID: String? = nil, limit: Int = 16) async throws -> [BaseItem] {
        var query = listQuery(user, ["Limit": "\(limit)", "EnableResumable": "false"])
        if let seriesID { query["SeriesId"] = seriesID }
        let page: ItemsResponse = try await get("Shows/NextUp", query: query)
        return page.items
    }

    func latest(user: String, parentID: String, limit: Int = 20) async throws -> [BaseItem] {
        try await get("Items/Latest", legacy: "Users/\(user)/Items/Latest",
                      query: listQuery(user, ["ParentId": parentID, "Limit": "\(limit)", "GroupItems": "true"]))
    }

    struct ItemQuery: Equatable {
        var types = ["Movie", "Series"]
        var parentID: String?
        var search: String?
        var sortBy = "SortName"
        var sortOrder = "Ascending"
        var filters: [String] = []
        var start = 0
        var limit = 60
        var personID: String?
        /// Overrides the default list fields, e.g. "MediaSources" for bitrates.
        var fields: String?
    }

    func items(user: String, _ q: ItemQuery) async throws -> ItemsResponse {
        var query = listQuery(user, [
            "Recursive": "true", "IncludeItemTypes": q.types.joined(separator: ","), "SortBy": q.sortBy,
            "SortOrder": q.sortOrder, "StartIndex": "\(q.start)", "Limit": "\(q.limit)", "EnableTotalRecordCount": "true"
        ])
        if let parent = q.parentID { query["ParentId"] = parent }
        if let search = q.search, !search.isEmpty { query["SearchTerm"] = search }
        if !q.filters.isEmpty { query["Filters"] = q.filters.joined(separator: ",") }
        if let person = q.personID { query["PersonIds"] = person }
        if let fields = q.fields { query["Fields"] = fields }
        return try await get("Items", query: query)
    }

    func item(user: String, id: String) async throws -> BaseItem {
        try await get("Items/\(id)", legacy: "Users/\(user)/Items/\(id)", query: ["userId": user])
    }

    func seasons(user: String, seriesID: String) async throws -> [BaseItem] {
        let page: ItemsResponse = try await get("Shows/\(seriesID)/Seasons", query: listQuery(user))
        return page.items
    }

    func episodes(user: String, seriesID: String, seasonID: String? = nil) async throws -> [BaseItem] {
        var query = listQuery(user, ["Fields": "Overview,PrimaryImageAspectRatio,MediaSources"])
        if let seasonID { query["SeasonId"] = seasonID }
        let page: ItemsResponse = try await get("Shows/\(seriesID)/Episodes", query: query)
        return page.items
    }

    func similar(user: String, id: String) async throws -> [BaseItem] {
        let page: ItemsResponse = try await get("Items/\(id)/Similar", query: listQuery(user, ["Limit": "16"]))
        return page.items
    }

    func setFavorite(user: String, id: String, _ favorite: Bool) async throws {
        _ = try await send("UserFavoriteItems/\(id)", legacy: "Users/\(user)/FavoriteItems/\(id)",
                           method: favorite ? "POST" : "DELETE", query: ["userId": user])
    }

    func setPlayed(user: String, id: String, _ played: Bool) async throws {
        _ = try await send("UserPlayedItems/\(id)", legacy: "Users/\(user)/PlayedItems/\(id)",
                           method: played ? "POST" : "DELETE", query: ["userId": user])
    }

    // MARK: Images

    enum ImageKind: String { case primary = "Primary", backdrop = "Backdrop", thumb = "Thumb", logo = "Logo" }

    func imageURL(item id: String, kind: ImageKind, tag: String?, width: Int, index: Int = 0) -> URL {
        var query = ["maxWidth": "\(width)", "quality": "90"]
        if let tag { query["tag"] = tag }
        let path = kind == .backdrop ? "Items/\(id)/Images/Backdrop/\(index)" : "Items/\(id)/Images/\(kind.rawValue)"
        return url(path, query: query)
    }

    func userImageURL(user id: String, tag: String?, width: Int = 400) -> URL {
        var query = ["maxWidth": "\(width)", "quality": "90"]
        if let tag { query["tag"] = tag }
        return url("Users/\(id)/Images/Primary", query: query)
    }

    // MARK: Playback

    /// Declares that the Apple TV can play every container and codec directly. The app never asks for transcoding.
    static var deviceProfile: [String: Any] {
        let embedded = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgs", "pgssub", "dvdsub", "dvbsub", "sub", "idx", "mov_text", "ttml", "smi"]
        let external = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]
        return [
            "Name": "Jelly tvOS",
            "MaxStreamingBitrate": 1_000_000_000,
            "MaxStaticBitrate": 1_000_000_000,
            "DirectPlayProfiles": [["Type": "Video"], ["Type": "Audio"]],
            "TranscodingProfiles": [],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": embedded.map { ["Format": $0, "Method": "Embed"] } + external.map { ["Format": $0, "Method": "External"] }
        ]
    }

    struct PlaybackInfoResponse: Decodable {
        var mediaSources: [MediaSource]
        var playSessionId: String?
        var errorCode: String?
    }

    func playbackInfo(user: String, itemID: String, mediaSourceID: String? = nil) async throws -> PlaybackInfoResponse {
        var body: [String: Any] = [
            "UserId": user, "DeviceProfile": Self.deviceProfile, "EnableDirectPlay": true,
            "EnableDirectStream": false, "EnableTranscoding": false, "AllowVideoStreamCopy": false,
            "AllowAudioStreamCopy": false, "AutoOpenLiveStream": true, "MaxStreamingBitrate": 1_000_000_000
        ]
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        let data = try await send("Items/\(itemID)/PlaybackInfo", method: "POST", query: ["userId": user], body: body)
        return try JSONDecoder.jellyfin.decode(PlaybackInfoResponse.self, from: data)
    }

    /// HLS/fMP4 with stream copy. The video is copied bit for bit (Dolby Vision survives as `dvh1`/`dvcC`,
    /// HDR10+ as SEI); audio is copied or, if the plan asks for it, converted losslessly to FLAC.
    static func remuxProfile(audio: String, dolbyVisionProfile7: Bool) -> [String: Any] {
        var ranges = "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithHDR10Plus"
        if dolbyVisionProfile7 { ranges += "|DOVIWithEL|DOVIWithELHDR10Plus" }
        return [
            "Name": "Jelly tvOS",
            "MaxStreamingBitrate": 1_000_000_000,
            "MaxStaticBitrate": 1_000_000_000,
            "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "hevc,h264", "AudioCodec": "aac,ac3,eac3"]],
            "TranscodingProfiles": [[
                "Container": "mp4", "Type": "Video", "VideoCodec": "hevc,h264", "AudioCodec": audio, "Protocol": "hls",
                "Context": "Streaming", "MaxAudioChannels": "8", "MinSegments": 2, "BreakOnNonKeyFrames": true
            ]],
            "CodecProfiles": [[
                "Type": "Video", "Codec": "hevc",
                "Conditions": [["Condition": "EqualsAny", "Property": "VideoRangeType", "IsRequired": false, "Value": ranges]]
            ]],
            "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"].map { ["Format": $0, "Method": "External"] }
        ]
    }

    /// Reasons that only concern the container or audio. Anything else would mean re-encoding the video.
    static let copyOnlyReasons: Set = ["ContainerNotSupported", "ContainerBitrateExceedsLimit", "AudioCodecNotSupported",
                                       "AudioChannelsNotSupported", "AudioProfileNotSupported", "AudioSampleRateNotSupported",
                                       "AudioBitDepthNotSupported", "AudioBitrateNotSupported", "SubtitleCodecNotSupported"]

    struct RemuxStream { let url: URL; let playSessionID: String?; let reasons: [String] }

    func remuxStream(user: String, itemID: String, sourceID: String, audioIndex: Int?, plan: PlaybackPlan) async throws -> RemuxStream {
        var profile = Self.remuxProfile(audio: plan.remuxAudio, dolbyVisionProfile7: DeviceCapabilities.current.dolbyVisionProfile7)
        if let limit = plan.maxBitrate { profile["MaxStreamingBitrate"] = limit }
        var body: [String: Any] = [
            "UserId": user, "DeviceProfile": profile,
            "MediaSourceId": sourceID, "SubtitleStreamIndex": -1,
            "EnableDirectPlay": false, "EnableDirectStream": true, "EnableTranscoding": true,
            "AllowVideoStreamCopy": true, "AllowAudioStreamCopy": true, "AutoOpenLiveStream": true,
            "MaxStreamingBitrate": plan.maxBitrate ?? 1_000_000_000
        ]
        if let audioIndex { body["AudioStreamIndex"] = audioIndex }
        let data = try await send("Items/\(itemID)/PlaybackInfo", method: "POST", query: ["userId": user], body: body)
        let info = try JSONDecoder.jellyfin.decode(PlaybackInfoResponse.self, from: data)
        guard let path = info.mediaSources.first(where: { $0.id == sourceID })?.transcodingUrl ?? info.mediaSources.first?.transcodingUrl,
              let url = URL(string: server.absoluteString.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression) + path)
        else { throw JellyError.unsupported }
        let reasons = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "TranscodeReasons" }?.value?.split(separator: ",").map(String.init) ?? []
        // Away from home with a limit, the server may convert; let AVFoundation pick from the master playlist.
        if plan.maxBitrate != nil { return RemuxStream(url: url, playSessionID: info.playSessionId, reasons: reasons) }
        guard reasons.allSatisfy(Self.copyOnlyReasons.contains) else { throw JellyError.unsupported }
        return RemuxStream(url: try await copyVariant(of: url), playSessionID: info.playSessionId, reasons: reasons)
    }

    /// The master playlist also offers SDR fallbacks that re-encode the video. Only the stream-copy variant is used.
    private func copyVariant(of master: URL) async throws -> URL {
        var request = URLRequest(url: master, timeoutInterval: 20)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        let variants = zip(lines, lines.dropFirst()).filter { $0.0.hasPrefix("#EXT-X-STREAM-INF") }.map(\.1)
        guard let variant = variants.first(where: { !$0.contains("AllowVideoStreamCopy=false") }),
              let url = URL(string: variant, relativeTo: master)?.absoluteURL else { throw JellyError.unsupported }
        return url
    }

    /// Ends the server's packaging job right away instead of waiting for its idle timeout.
    func stopEncoding(playSessionID: String?) async {
        guard let playSessionID else { return }
        _ = try? await send("Videos/ActiveEncodings", method: "DELETE", query: ["deviceId": deviceID, "playSessionId": playSessionID], timeout: 5)
    }

    /// Original file bytes (`Static=true`). Jellyfin never transcodes this endpoint.
    func streamURL(itemID: String, source: MediaSource, playSessionID: String?) -> URL {
        var query = ["Static": "true", "MediaSourceId": source.id, "DeviceId": deviceID]
        if let playSessionID { query["PlaySessionId"] = playSessionID }
        return url("Videos/\(itemID)/stream.\(Self.fileExtension(container: source.container))", query: query)
    }

    static func fileExtension(container: String?) -> String {
        let parts = (container ?? "").lowercased().split(separator: ",").map(String.init)
        if parts.contains("mp4") { return "mp4" }
        if parts.contains("matroska") || parts.contains("mkv") { return "mkv" }
        return parts.first ?? "mkv"
    }

    func subtitleURL(itemID: String, sourceID: String, stream: MediaStream) -> URL {
        let format: String
        switch stream.codecName {
        case "ass": format = "ass"
        case "ssa": format = "ssa"
        case "webvtt", "vtt": format = "vtt"
        default: format = "srt"
        }
        return url("Videos/\(itemID)/\(sourceID)/Subtitles/\(stream.index)/Stream.\(format)")
    }

    struct ProgressReport {
        var itemID: String
        var sourceID: String
        var playSessionID: String?
        var seconds: Double
        var isPaused: Bool
        var audioIndex: Int?
        var subtitleIndex: Int?
        var playMethod = "DirectPlay"
    }

    enum ReportKind: String { case start = "", progress = "/Progress", stopped = "/Stopped" }

    func report(_ kind: ReportKind, _ report: ProgressReport) async throws {
        var body: [String: Any] = [
            "ItemId": report.itemID, "MediaSourceId": report.sourceID, "PositionTicks": Ticks.from(seconds: report.seconds),
            "IsPaused": report.isPaused, "CanSeek": true, "PlayMethod": report.playMethod
        ]
        if let id = report.playSessionID { body["PlaySessionId"] = id }
        if let index = report.audioIndex { body["AudioStreamIndex"] = index }
        body["SubtitleStreamIndex"] = report.subtitleIndex ?? -1
        _ = try await send("Sessions/Playing\(kind.rawValue)", method: "POST", body: body)
    }
}

/// Last answers for the start screen on disk, so it appears instantly at launch and refreshes moments later.
/// Keyed by the full address, which contains the user, so profiles never see each other's rows.
enum ResponseCache {
    enum Mode: Sendable { case off, only, store }

    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Responses", isDirectory: true)

    private static func file(_ url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }

    static func read(_ url: URL) -> Data? { try? Data(contentsOf: file(url)) }

    static func write(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(url), options: .atomic)
    }
}
