import TVServices

/// "Weiterschauen" and "Nächste Folgen" on the Apple TV home screen when Jelly sits in the top row.
/// Reads the active profile from the keychain group shared with the app; links open the app via `jelly://`.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task { completionHandler(await Self.content()) }
    }

    private static func content() async -> TVTopShelfContent? {
        let store = SecureStore.load(fallbackDeviceID: "topshelf")
        guard let session = store.active else { return nil }
        let client = JellyfinClient(server: session.server, token: session.token, deviceID: store.deviceID)
        async let resume = try? client.resume(user: session.userID, limit: 12)
        async let nextUp = try? client.nextUp(user: session.userID, limit: 12)
        let continuing = await resume ?? []
        let upcoming = (await nextUp ?? []).filter { episode in !continuing.contains { $0.id == episode.id } }
        let sections = [("Weiterschauen", continuing), ("Nächste Folgen", upcoming)]
            .filter { !$0.1.isEmpty }
            .map { title, items -> TVTopShelfItemCollection<TVTopShelfSectionedItem> in
                let collection = TVTopShelfItemCollection(items: items.map { shelfItem($0, client: client) })
                collection.title = title
                return collection
            }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func shelfItem(_ base: BaseItem, client: JellyfinClient) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: base.id)
        item.title = base.isEpisode ? [base.seriesName, base.episodeLabel].compactMap { $0 }.joined(separator: " · ") : base.name
        item.imageShape = .hdtv
        if let url = client.artworkURL(base, .landscape, width: 960) { item.setImageURL(url, for: .screenScale1x) }
        if let url = client.artworkURL(base, .landscape, width: 1920) { item.setImageURL(url, for: .screenScale2x) }
        if base.progress > 0.01 { item.playbackProgress = base.progress }
        if let open = URL(string: "jelly://item/\(base.id)") { item.displayAction = TVTopShelfAction(url: open) }
        if let play = URL(string: "jelly://play/\(base.id)") { item.playAction = TVTopShelfAction(url: play) }
        return item
    }
}
