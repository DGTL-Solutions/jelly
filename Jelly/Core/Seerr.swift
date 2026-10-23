import Foundation

/// A Jellyseerr (or Overseerr) server: discover, search and request films and series that aren't in the library yet.
/// Signs in with a session cookie, the way Jellyseerr's own web app does.
struct SeerrClient: Sendable {
    let server: URL
    var cookie: String?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    // MARK: Models

    struct Status: Decodable { var version: String }

    struct PublicSettings: Decodable {
        var applicationTitle: String?
        var localLogin: Bool?
        var mediaServerLogin: Bool?
        var partialRequestsEnabled: Bool?
        /// 1 Plex, 2 Jellyfin, 3 Emby, 4 not set up.
        var mediaServerType: Int?
        /// The Jellyfin address entered in Jellyseerr's settings for links and sign-in, if any.
        var jellyfinExternalHost: String?
    }

    struct User: Decodable {
        var id: Int
        var displayName: String?
        var jellyfinUsername: String?
        var username: String?
        var email: String?
        var name: String { displayName ?? jellyfinUsername ?? username ?? email ?? "Jellyseerr" }
    }

    struct MediaInfo: Decodable, Hashable {
        struct Season: Decodable, Hashable {
            var seasonNumber: Int
            var status: Int?
        }
        var status: Int?
        var jellyfinMediaId: String?
        var seasons: [Season]?
    }

    /// A film or series from TMDB as Jellyseerr knows it. TMDB numbers films and series separately.
    struct Title: Decodable, Identifiable, Hashable {
        let tmdbID: Int
        var mediaType: String?
        var title: String?
        var name: String?
        var releaseDate: String?
        var firstAirDate: String?
        var overview: String?
        var posterPath: String?
        var backdropPath: String?
        var voteAverage: Double?
        var mediaInfo: MediaInfo?

        enum CodingKeys: String, CodingKey {
            case tmdbID = "id", mediaType, title, name, releaseDate, firstAirDate, overview, posterPath, backdropPath, voteAverage, mediaInfo
        }

        var id: String { "\(mediaType ?? "-")-\(tmdbID)" }
        var isSeries: Bool { mediaType == "tv" }
        var displayTitle: String { title ?? name ?? "" }
        var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
        var status: SeerrStatus { SeerrStatus(mediaInfo?.status) }
        var poster: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
        var backdrop: URL? { backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") } }
    }

    struct Details: Decodable {
        struct Genre: Decodable { var name: String }
        struct Season: Decodable, Identifiable {
            var seasonNumber: Int
            var name: String?
            var episodeCount: Int?
            var id: Int { seasonNumber }
        }
        var id: Int
        var title: String?
        var name: String?
        var tagline: String?
        var overview: String?
        var runtime: Int?
        var numberOfSeasons: Int?
        var releaseDate: String?
        var firstAirDate: String?
        var voteAverage: Double?
        var genres: [Genre]?
        var seasons: [Season]?
        var posterPath: String?
        var backdropPath: String?
        var mediaInfo: MediaInfo?
    }

    struct Request: Decodable {
        struct Media: Decodable {
            var tmdbId: Int
            var mediaType: String
            var status: Int?
        }
        var id: Int
        var status: Int
        var media: Media?
    }

    // MARK: Transport

    private func send(_ path: String, method: String = "GET", query: String? = nil, body: [String: Any]? = nil,
                      timeout: TimeInterval = 15) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: server.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)!
        // Jellyseerr rejects queries with unencoded characters, so everything but letters and digits is escaped.
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue("connect.sid=\(cookie)", forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.unreachable }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw SeerrError.signedOut
        case 403: throw SeerrError.forbidden(Self.message(data))
        default: throw SeerrError.server(http.statusCode, Self.message(data))
        }
    }

    private func get<T: Decodable>(_ path: String, query: String? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(path, query: query).0)
    }

    private static func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private var language: String { "language=de" }

    // MARK: Server & sign-in

    func status(timeout: TimeInterval = 5) async throws -> Status {
        try JSONDecoder().decode(Status.self, from: await send("status", timeout: timeout).0)
    }

    func publicSettings() async throws -> PublicSettings { try await get("settings/public") }

    /// Signs in with the Jellyfin account (Jellyseerr checks it against its Jellyfin server) or a local Jellyseerr account.
    func signIn(username: String, password: String, local: Bool) async throws -> (User, String) {
        let body: [String: Any] = local ? ["email": username, "password": password] : ["username": username, "password": password]
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await send(local ? "auth/local" : "auth/jellyfin", method: "POST", body: body)
        } catch SeerrError.signedOut {
            throw SeerrError.wrongPassword
        } catch SeerrError.forbidden(let message) {
            throw message.map { SeerrError.rejected($0) } ?? SeerrError.wrongPassword
        } catch SeerrError.server(500, _) where !local {
            // Jellyseerr signs in to Jellyfin itself and only reports a bare 500 when Jellyfin refuses.
            throw SeerrError.jellyfinRefused
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url ?? server)
            .first(where: { $0.name == "connect.sid" })?.value else { throw SeerrError.server(response.statusCode, "Keine Sitzung erhalten") }
        return (try JSONDecoder().decode(User.self, from: data), cookie)
    }

    func me() async throws -> User { try await get("auth/me") }

    func signOut() async { _ = try? await send("auth/logout", method: "POST", body: [:], timeout: 5) }

    // MARK: Discover

    enum Shelf: String, CaseIterable, Identifiable {
        case trending, popularMovies, popularSeries, upcomingMovies, upcomingSeries
        var id: String { rawValue }

        var title: String {
            switch self {
            case .trending: "Gerade angesagt"
            case .popularMovies: "Beliebte Filme"
            case .popularSeries: "Beliebte Serien"
            case .upcomingMovies: "Bald im Kino"
            case .upcomingSeries: "Neue Serien demnächst"
            }
        }

        fileprivate var path: String {
            switch self {
            case .trending: "discover/trending"
            case .popularMovies: "discover/movies"
            case .popularSeries: "discover/tv"
            case .upcomingMovies: "discover/movies/upcoming"
            case .upcomingSeries: "discover/tv/upcoming"
            }
        }
    }

    private struct Page: Decodable { var results: [Title] }

    func discover(_ shelf: Shelf) async throws -> [Title] {
        let page: Page = try await get(shelf.path, query: "page=1&\(language)")
        return page.results.filter { $0.mediaType != "person" }.map { title in
            var title = title
            if title.mediaType == nil { title.mediaType = shelf == .popularSeries || shelf == .upcomingSeries ? "tv" : "movie" }
            return title
        }
    }

    func search(_ text: String) async throws -> [Title] {
        let page: Page = try await get("search", query: "query=\(Self.encode(text))&page=1&\(language)")
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func details(_ title: Title) async throws -> Details {
        try await get("\(title.isSeries ? "tv" : "movie")/\(title.tmdbID)", query: language)
    }

    /// Asks for a film, or for the given seasons of a series. Returns Jellyseerr's request status (2 = approved).
    func request(_ title: Title, seasons: [Int]?) async throws -> Int {
        var body: [String: Any] = ["mediaType": title.isSeries ? "tv" : "movie", "mediaId": title.tmdbID]
        if title.isSeries { body["seasons"] = seasons ?? [] }
        let data = try await send("request", method: "POST", body: body).0
        return (try? JSONDecoder().decode(Request.self, from: data))?.status ?? 1
    }

    /// The signed-in user's latest requests, newest first.
    func myRequests(userID: Int) async throws -> [Request] {
        struct Response: Decodable { var results: [Request] }
        let response: Response = try await get("request", query: "take=20&skip=0&sort=added&filter=all&requestedBy=\(userID)")
        return response.results
    }

    /// The title behind a request, with poster and current status.
    func title(for request: Request) async throws -> Title? {
        guard let media = request.media else { return nil }
        let stub = Title(tmdbID: media.tmdbId, mediaType: media.mediaType)
        let details = try await details(stub)
        return Title(tmdbID: details.id, mediaType: media.mediaType, title: details.title, name: details.name,
                     releaseDate: details.releaseDate, firstAirDate: details.firstAirDate, overview: details.overview,
                     posterPath: details.posterPath, backdropPath: details.backdropPath, voteAverage: details.voteAverage,
                     mediaInfo: details.mediaInfo)
    }

    // MARK: Finding the server

    /// Likely addresses next to the Jellyfin server – jellyfin.example.com → jellyseerr.example.com, seerr.…, requests.… –
    /// and Jellyseerr's default port 5055 on the same machine.
    static func candidates(near jellyfin: [URL]) -> [URL] {
        var urls: [URL] = []
        for server in jellyfin {
            guard let host = server.host(percentEncoded: false), let scheme = server.scheme else { continue }
            var labels = host.split(separator: ".").map(String.init)
            let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
            if !isAddress, labels.count > 2, let first = labels.first {
                for name in ["jellyseerr", "seerr", "requests", "request", "overseerr", "anfragen"] where name != first {
                    labels[0] = first.lowercased().contains("jellyfin") ? first.lowercased().replacingOccurrences(of: "jellyfin", with: name) : name
                    urls.append(URL(string: "https://\(labels.joined(separator: "."))")!)
                }
            }
            urls.append(URL(string: "\(scheme)://\(host):5055")!)
            if scheme == "https" { urls.append(URL(string: "http://\(host):5055")!) }
        }
        return urls.uniqued()
    }

    /// The first candidate that answers like a Jellyseerr server, in the order given.
    static func find(near jellyfin: [URL]) async -> (URL, String)? {
        let candidates = candidates(near: jellyfin)
        let answers = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask { (index, try? await SeerrClient(server: url).status(timeout: 3).version) }
            }
            var answers: [Int: String] = [:]
            for await (index, version) in group { if let version { answers[index] = version } }
            return answers
        }
        guard let best = answers.keys.min() else { return nil }
        return (candidates[best], answers[best]!)
    }

    /// Whether a Jellyseerr found next to Jellyfin provably belongs to that Jellyfin server – the condition for signing
    /// in there on its own with the Jellyfin password: it runs on the same machine, or its settings name this Jellyfin's
    /// address. A guessed neighbour such as jellyseerr.synology.me next to name.synology.me may be a stranger's server.
    static func belongs(_ seerr: URL, settings: PublicSettings, to jellyfin: [URL]) -> Bool {
        guard settings.mediaServerType == 2, settings.mediaServerLogin != false else { return false }
        let hosts = Set(jellyfin.compactMap { $0.host(percentEncoded: false)?.lowercased() })
        if let host = seerr.host(percentEncoded: false)?.lowercased(), hosts.contains(host) { return true }
        guard let external = settings.jellyfinExternalHost?.trimmingCharacters(in: .whitespaces), !external.isEmpty,
              let url = URL(string: external.contains("://") ? external : "https://\(external)"),
              let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Accepts "jellyseerr.example.com", "192.168.1.5:5055" or a copied web link.
    static func address(from text: String) -> [URL] {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return [] }
        if value.contains("://") { return URL(string: value).map { [$0] } ?? [] }
        return ["https://\(value)", "http://\(value)", "http://\(value):5055"].compactMap(URL.init(string:))
    }
}

/// Jellyseerr's media status, in the words of the app.
enum SeerrStatus: Equatable {
    case none, pending, processing, partial, available

    init(_ code: Int?) {
        switch code {
        case 2: self = .pending
        case 3: self = .processing
        case 4: self = .partial
        case 5: self = .available
        default: self = .none
        }
    }

    var label: String? {
        switch self {
        case .none: nil
        case .pending: "Gewünscht"
        case .processing: "Wird geladen"
        case .partial: "Teilweise da"
        case .available: "In deiner Bibliothek"
        }
    }

    var symbol: String {
        switch self {
        case .none: "plus"
        case .pending: "clock"
        case .processing: "arrow.down"
        case .partial: "circle.lefthalf.filled"
        case .available: "checkmark"
        }
    }
}

enum SeerrError: LocalizedError, Equatable {
    case unreachable, signedOut, wrongPassword, jellyfinRefused
    case rejected(String)
    case forbidden(String?)
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .unreachable: "Jellyseerr ist unter dieser Adresse nicht erreichbar."
        case .signedOut: "Die Anmeldung bei Jellyseerr ist abgelaufen."
        case .wrongPassword: "Benutzername oder Passwort stimmen nicht."
        case .jellyfinRefused: "Jellyseerr konnte dich nicht bei Jellyfin anmelden. Meist ist das Passwort falsch oder dein Jellyfin-Konto hat die erlaubte Zahl gleichzeitiger Anmeldungen erreicht – dann ein anderes Gerät abmelden und erneut versuchen."
        case .rejected(let message): "Jellyseerr lehnt die Anmeldung ab: \(message)"
        case .forbidden(let message): message.map { "Jellyseerr erlaubt das nicht: \($0)" } ?? "Dein Jellyseerr-Konto darf das nicht."
        case .server(let code, let message): "Jellyseerr meldet einen Fehler (\(code))\(message.map { ": \($0)" } ?? "")."
        }
    }
}

/// The Jellyseerr sign-in of one Jellyfin profile.
struct SeerrAccount: Codable, Equatable {
    var server: URL
    var cookie: String
    var userID: Int
    var name: String

    var client: SeerrClient { SeerrClient(server: server, cookie: cookie) }
}
