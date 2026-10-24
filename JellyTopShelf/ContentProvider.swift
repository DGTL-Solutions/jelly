import TVServices

/// Jelly's Top Shelf: when Jelly sits in the Dock and has the focus, the home screen fills with what to watch next –
/// films and episodes in progress, the next episodes of series, then what's new in the library – each full-screen
/// with its summary, quality badges and the buttons Play and More Info, like Apple's own TV app.
/// Reads the active profile from the keychain group shared with the app; the buttons open the app via `jelly://`.
/// Without a profile or anything to show, tvOS falls back to the static Top Shelf image.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task { completionHandler(await Self.content()) }
    }

    /// A handful keeps it a choice rather than a catalogue.
    private static let maxItems = 10
    /// MediaSources for the 4K, HDR, Dolby Vision and Atmos badges.
    private static let fields = JellyfinClient.listFields + ",MediaSources"

    private enum Reason { case resume, nextUp, new }

    private static func content() async -> TVTopShelfContent? {
        let store = SecureStore.load(fallbackDeviceID: "topshelf")
        guard let session = store.active else {
            Diagnostics.log("topshelf: no profile, static image")
            return nil
        }
        let client = JellyfinClient(server: session.server, token: session.token, deviceID: store.deviceID)
        let newest: JellyfinClient.ItemQuery = {
            var query = JellyfinClient.ItemQuery()
            query.sortBy = "DateCreated"
            query.sortOrder = "Descending"
            query.limit = 16
            query.fields = fields
            return query
        }()
        async let resume = loaded("resume") { try await client.resume(user: session.userID, limit: 6, fields: fields) }
        async let nextUp = loaded("next up") { try await client.nextUp(user: session.userID, limit: 6, fields: fields) }
        async let latest = loaded("latest") { try await client.items(user: session.userID, newest).items }

        // One entry per film or series: an episode in progress wins over the next one and over "new".
        var picked: [(BaseItem, Reason)] = []
        var seen = Set<String>()
        func add(_ items: [BaseItem], _ reason: Reason) {
            for item in items where picked.count < maxItems && seen.insert(item.seriesId ?? item.id).inserted {
                picked.append((item, reason))
            }
        }
        let (inProgress, upcoming, recent) = await (resume, nextUp, latest)
        add(inProgress, .resume)
        add(upcoming, .nextUp)
        add(recent.filter { !$0.isWatched }, .new)
        Diagnostics.log("topshelf: \(session.server.host() ?? "?") resume=\(inProgress.count) nextUp=\(upcoming.count) latest=\(recent.count) shown=\(picked.count)")
        guard !picked.isEmpty else { return nil }
        return TVTopShelfCarouselContent(style: .details, items: picked.map { carouselItem($0.0, $0.1, client: client) })
    }

    /// A list from the server, or none when it can't be loaded – noted in the extension's diagnostics log.
    private static func loaded(_ name: String, _ load: () async throws -> [BaseItem]) async -> [BaseItem] {
        do { return try await load() } catch {
            Diagnostics.log("topshelf: \(name) failed: \(Diagnostics.redact(String(describing: error)))")
            return []
        }
    }

    private static func carouselItem(_ base: BaseItem, _ reason: Reason, client: JellyfinClient) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: base.id)
        item.title = base.isEpisode ? base.seriesName ?? base.name : base.name
        switch reason {
        case .resume:
            item.contextTitle = [String(localized: "Weiterschauen", comment: "Continue watching"), base.remainingText].compactMap { $0 }
                .joined(separator: " · ")
        case .nextUp: item.contextTitle = String(localized: "Nächste Folge", comment: "Next TV episode")
        case .new: item.contextTitle = String(localized: "Neu in deiner Mediathek")
        }
        item.summary = base.overview?.nonEmpty
        item.genre = base.genres?.prefix(2).joined(separator: ", ").nonEmpty
        if base.runtimeSeconds > 0 { item.duration = base.runtimeSeconds }
        item.creationDate = releaseDate(base)
        item.mediaOptions = mediaOptions(base.mediaSources?.first)
        if base.isEpisode {
            let episode = [base.episodeLabel, base.name].compactMap { $0 }.joined(separator: " – ")
            item.namedAttributes = [TVTopShelfNamedAttribute(name: String(localized: "Folge", comment: "TV episode"), values: [episode])]
        }
        // Full-screen 16:9: the film's or series' backdrop rather than an episode still.
        if let url = client.artworkURL(base, .backdrop, width: 1920) { item.setImageURL(url, for: .screenScale1x) }
        if let url = client.artworkURL(base, .backdrop, width: 3840) { item.setImageURL(url, for: .screenScale2x) }
        if let open = URL(string: "jelly://item/\(base.id)") { item.displayAction = TVTopShelfAction(url: open) }
        if let play = URL(string: "jelly://play/\(base.id)") { item.playAction = TVTopShelfAction(url: play) }
        return item
    }

    private static func releaseDate(_ base: BaseItem) -> Date? {
        if let text = base.premiereDate,
           let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
            return date
        }
        return base.productionYear.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 7, day: 1)) }
    }

    private static func mediaOptions(_ source: MediaSource?) -> TVTopShelfCarouselItem.MediaOptions {
        guard let source else { return [] }
        var options: TVTopShelfCarouselItem.MediaOptions = []
        switch TechInfo.resolution(source.video) {
        case "4K": options.insert(.videoResolution4K)
        case "1080p", "720p": options.insert(.videoResolutionHD)
        default: break
        }
        switch TechInfo.dynamicRange(source.video) {
        case "Dolby Vision": options.insert(.videoColorSpaceDolbyVision)
        case .some: options.insert(.videoColorSpaceHDR)
        case nil: break
        }
        if TechInfo.audioFormat(TechInfo.defaultAudio(source)) == "Dolby Atmos" { options.insert(.audioDolbyAtmos) }
        return options
    }
}
