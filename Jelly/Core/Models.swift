import Foundation

// Jellyfin sends PascalCase keys. The decoder lowercases the first letter so models can use Swift naming.
extension JSONDecoder {
    static let jellyfin: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return AnyKey(key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

enum Ticks {
    static let perSecond: Double = 10_000_000
    static func seconds(_ ticks: Int64?) -> Double { Double(ticks ?? 0) / perSecond }
    static func from(seconds: Double) -> Int64 { Int64(max(0, seconds) * perSecond) }
}

struct Session: Codable, Equatable {
    let server: URL
    let token: String
    let userID: String
    let name: String
    var serverID: String?
    var serverName: String?
    var imageTag: String?
}

struct KnownServer: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var url: URL
    var version: String?
}

// MARK: - Server & users

struct PublicSystemInfo: Decodable {
    var id: String?
    var serverName: String?
    var version: String?
    var productName: String?
    var localAddress: String?
    var startupWizardCompleted: Bool?
}

struct UserDto: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    var primaryImageTag: String?
    var hasPassword: Bool?
    var hasConfiguredPassword: Bool?
    var configuration: Configuration?
    var policy: Policy?

    struct Policy: Decodable, Hashable {
        var isAdministrator: Bool?
        var enableVideoPlaybackTranscoding: Bool?
        var enablePlaybackRemuxing: Bool?
        var remoteClientBitrateLimit: Int?
        var maxActiveSessions: Int?
    }

    struct Configuration: Decodable, Hashable {
        var audioLanguagePreference: String?
        var subtitleLanguagePreference: String?
        var subtitleMode: String?
        var enableNextEpisodeAutoPlay: Bool?
    }

    var needsPassword: Bool { hasPassword ?? hasConfiguredPassword ?? true }
}

struct AuthenticationResult: Decodable {
    let user: UserDto
    let accessToken: String
    var serverId: String?
}

struct QuickConnectState: Decodable {
    let secret: String
    var code: String?
    var authenticated: Bool?
}

// MARK: - Library items

struct ItemsResponse: Decodable {
    var items: [BaseItem]
    var totalRecordCount: Int?
}

struct UserItemData: Decodable, Hashable {
    var playbackPositionTicks: Int64?
    var playCount: Int?
    var isFavorite: Bool?
    var played: Bool?
    var unplayedItemCount: Int?
    var playedPercentage: Double?
}

struct Person: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    var role: String?
    var type: String?
    var primaryImageTag: String?
}

struct BaseItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    var type: String?
    var collectionType: String?
    var overview: String?
    var taglines: [String]?
    var genres: [String]?
    var productionYear: Int?
    var premiereDate: String?
    var officialRating: String?
    var communityRating: Double?
    var criticRating: Double?
    var runTimeTicks: Int64?
    var status: String?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var seasonName: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var childCount: Int?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var parentLogoItemId: String?
    var parentLogoImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var seriesPrimaryImageTag: String?
    var primaryImageAspectRatio: Double?
    var userData: UserItemData?
    var mediaSources: [MediaSource]?
    var mediaStreams: [MediaStream]?
    var people: [Person]?
    var chapters: [Chapter]?
    var providerIds: [String: String]?
    /// Jellyfin 10.9+ scrubbing thumbnails: media source ID → tile width → layout.
    var trickplay: [String: [String: TrickplayInfo]]?

    static func == (lhs: BaseItem, rhs: BaseItem) -> Bool {
        lhs.id == rhs.id && lhs.userData == rhs.userData && lhs.name == rhs.name
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isSeries: Bool { type == "Series" }
    var imdbID: String? { providerIds?["Imdb"]?.nonEmpty }
    var isEpisode: Bool { type == "Episode" }
    var isMovie: Bool { type == "Movie" }
    var isPlayable: Bool { ["Movie", "Episode", "Video", "MusicVideo", "Trailer"].contains(type ?? "") }
    var isFolder: Bool { ["CollectionFolder", "BoxSet", "Folder", "Season", "Playlist"].contains(type ?? "") }

    var resumeSeconds: Double { Ticks.seconds(userData?.playbackPositionTicks) }
    var runtimeSeconds: Double { Ticks.seconds(runTimeTicks) }
    var isWatched: Bool { userData?.played ?? false }
    var isFavorite: Bool { userData?.isFavorite ?? false }

    var progress: Double {
        guard let total = runTimeTicks, total > 0 else { return 0 }
        return min(1, max(0, Double(userData?.playbackPositionTicks ?? 0) / Double(total)))
    }

    var episodeLabel: String? {
        guard isEpisode else { return nil }
        let season = parentIndexNumber.map { "S\($0)" } ?? ""
        let episode = indexNumber.map { "F\($0)" } ?? ""
        let label = [season, episode].filter { !$0.isEmpty }.joined(separator: " · ")
        return label.isEmpty ? nil : label
    }

    var runtimeText: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return Format.duration(Ticks.seconds(ticks))
    }

    var remainingText: String? {
        guard progress > 0, runtimeSeconds > 0 else { return nil }
        return "Noch " + Format.duration(runtimeSeconds - resumeSeconds)
    }

    /// Year, age rating, runtime and rating joined for metadata rows.
    var metadataLine: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(year)) }
        if isSeries, let status, status == "Continuing" { parts.append("Laufend") }
        if let rating = officialRating, !rating.isEmpty { parts.append(rating) }
        if !isSeries, let runtime = runtimeText { parts.append(runtime) }
        return parts.joined(separator: "  ·  ")
    }

    var subtitleLine: String {
        if isEpisode {
            return [seriesName, episodeLabel].compactMap { $0 }.joined(separator: " · ")
        }
        return [productionYear.map(String.init), isSeries ? "Serie" : runtimeText].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Playback metadata

struct Chapter: Decodable, Hashable {
    var startPositionTicks: Int64
    var name: String?
    var imageTag: String?

    var start: Double { Ticks.seconds(startPositionTicks) }

    /// Chapter titles commonly used for openings and end credits, in the languages found in typical rips.
    var isIntro: Bool { Self.matches(name, ["intro", "opening", "vorspann", "op"]) }
    var isCredits: Bool { Self.matches(name, ["credits", "end credits", "abspann", "outro", "ending", "ed"]) }

    private static func matches(_ name: String?, _ words: [String]) -> Bool {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return words.contains(name) || words.contains { $0.count > 2 && name.hasPrefix($0) }
    }
}

struct TrickplayInfo: Decodable, Hashable {
    var width: Int
    var height: Int
    var tileWidth: Int
    var tileHeight: Int
    var thumbnailCount: Int
    /// Milliseconds between thumbnails.
    var interval: Int
}

struct MediaSource: Decodable, Hashable, Identifiable {
    let id: String
    var name: String?
    var path: String?
    var container: String?
    var size: Int64?
    var bitrate: Int?
    var `protocol`: String?
    var isRemote: Bool?
    var requiresOpening: Bool?
    var supportsDirectPlay: Bool?
    var runTimeTicks: Int64?
    var mediaStreams: [MediaStream]?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var transcodingUrl: String?
    var mediaAttachments: [MediaAttachment]?

    var streams: [MediaStream] { mediaStreams ?? [] }
    var video: MediaStream? { streams.first { $0.type == "Video" } }
    var audioStreams: [MediaStream] { streams.filter { $0.type == "Audio" } }
    var subtitleStreams: [MediaStream] { streams.filter { $0.type == "Subtitle" } }
}

/// Files embedded in the container, e.g. the fonts an ASS subtitle track was authored with.
struct MediaAttachment: Decodable, Hashable {
    var index: Int
    var codec: String?
    var fileName: String?
    var mimeType: String?

    var isFont: Bool {
        let type = "\(mimeType ?? "") \(codec ?? "") \(fileName ?? "")".lowercased()
        return ["font", "ttf", "otf", "ttc"].contains { type.contains($0) }
    }
}

struct MediaStream: Decodable, Hashable, Identifiable {
    var type: String
    var index: Int
    var codec: String?
    var codecTag: String?
    var profile: String?
    var language: String?
    var title: String?
    var displayTitle: String?
    var isDefault: Bool?
    var isForced: Bool?
    var isExternal: Bool?
    var isInterlaced: Bool?
    var isTextSubtitleStream: Bool?
    var width: Int?
    var height: Int?
    var bitDepth: Int?
    var bitRate: Int?
    var channels: Int?
    var channelLayout: String?
    var videoRange: String?
    var videoRangeType: String?
    var dvProfile: Int?
    var realFrameRate: Double?
    var averageFrameRate: Double?

    var id: Int { index }
    var codecName: String { (codec ?? "").lowercased() }

    var languageName: String? {
        guard let language, !language.isEmpty, language != "und" else { return nil }
        return Locale(identifier: "de").localizedString(forLanguageCode: language) ?? language
    }

    var label: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        return [languageName, title].compactMap { $0 }.joined(separator: " – ").nonEmpty ?? "Spur \(index)"
    }

    /// Bitmap subtitles (PGS, VobSub, DVB) that only the FFmpeg pipeline can render.
    var isImageSubtitle: Bool {
        if let text = isTextSubtitleStream { return !text }
        return ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "dvb_subtitle", "dvbsub", "xsub", "vobsub"].contains(codecName)
    }

    var isASS: Bool { ["ass", "ssa"].contains(codecName) }

    var subtitleFormat: String? {
        let names = ["pgssub": "PGS", "hdmv_pgs_subtitle": "PGS", "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA",
                     "dvd_subtitle": "VobSub", "dvdsub": "VobSub", "dvb_subtitle": "DVB", "webvtt": "WebVTT", "mov_text": "Text"]
        return names[codecName] ?? codec?.uppercased()
    }

    /// ISO 639-2 code ("ger", "deu", "eng") reduced to the two-letter code ("de", "en").
    var languageCode: String? {
        guard let language = language?.lowercased(), !language.isEmpty, language != "und" else { return nil }
        let bibliographic = ["ger": "de", "deu": "de", "eng": "en", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "dut": "nl",
                             "nld": "nl", "por": "pt", "pol": "pl", "tur": "tr", "rus": "ru", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh"]
        return bibliographic[language] ?? (language.count == 2 ? language : nil)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds) / 60)
        let hours = total / 60, minutes = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours) Std. \(minutes) Min." : "\(hours) Std." }
        return "\(max(minutes, 1)) Min."
    }

    static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = value / 3600, m = (value % 3600) / 60, s = value % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum JellyError: LocalizedError, Equatable {
    case invalidURL, serverNotFound, unauthorized, forbidden, loginRejected, server(Int), unsupported, keychain, quickConnectDisabled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Diese Adresse sieht nicht richtig aus. Beispiel: 192.168.1.20 oder jellyfin.meinedomain.de"
        case .serverNotFound: return "Unter dieser Adresse wurde kein Jellyfin-Server gefunden."
        case .unauthorized: return "Benutzername oder Passwort stimmen nicht."
        case .forbidden: return "Dafür fehlt deinem Konto die Berechtigung."
        case .loginRejected: return "Der Server hat die Anmeldung abgelehnt. Meist ist das Geräte-Limit deines Kontos erreicht – melde ein anderes Gerät ab oder bitte den Admin, das Limit zu erhöhen."
        case .server(let code): return "Der Server hat mit Fehler \(code) geantwortet."
        case .unsupported: return "Für diesen Titel ist keine abspielbare Datei verfügbar."
        case .keychain: return "Die Anmeldung konnte nicht sicher gespeichert werden."
        case .quickConnectDisabled: return "Quick Connect ist auf diesem Server deaktiviert."
        }
    }
}
