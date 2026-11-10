import AppIntents
import Foundation

/// Siri, Shortcuts and Spotlight: "Spiele Fallout in Jelly", "Weiterschauen in Jelly".
struct MediaEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Film oder Serie")
    static let defaultQuery = MediaQuery()

    let id: String
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }

    init(_ item: BaseItem) {
        id = item.id
        title = item.isEpisode ? item.seriesName ?? item.name : item.name
        subtitle = item.isEpisode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ")
            : item.productionYear.map(String.init)
    }
}

struct MediaQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MediaEntity] {
        guard let (client, session) = StoredProfile.client() else { return [] }
        var found: [MediaEntity] = []
        for id in identifiers {
            if let item = try? await client.item(user: session.userID, id: id) { found.append(MediaEntity(item)) }
        }
        return found
    }

    func entities(matching string: String) async throws -> [MediaEntity] {
        guard let (client, session) = StoredProfile.client() else { return [] }
        let query = JellyfinClient.ItemQuery(types: ["Movie", "Series"], search: string, limit: 12)
        return try await client.items(user: session.userID, query).items.map(MediaEntity.init)
    }

    func suggestedEntities() async throws -> [MediaEntity] {
        await StoredProfile.continueWatching(limit: 8).map(MediaEntity.init)
    }
}

struct PlayMediaIntent: AppIntent {
    static let title: LocalizedStringResource = "Film oder Serie abspielen"
    static let description = IntentDescription("Spielt einen Film oder die nächste Folge einer Serie aus deiner Jellyfin-Mediathek.")
    static let openAppWhenRun = true

    @Parameter(title: "Titel") var media: MediaEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.open("jelly://play/\(media.id)")
        return .result()
    }
}

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Weiterschauen"
    static let description = IntentDescription("Setzt fort, was du zuletzt in Jelly geschaut hast.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = await StoredProfile.continueWatching(limit: 1).first else {
            return .result(dialog: "In Jelly läuft gerade nichts, das du fortsetzen könntest.")
        }
        IntentRouter.open("jelly://play/\(item.id)")
        return .result(dialog: "\(item.isEpisode ? item.seriesName ?? item.name : item.name)")
    }
}

struct JellyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueWatchingIntent(), phrases: ["Weiterschauen in \(.applicationName)", "In \(.applicationName) weiterschauen"],
                    shortTitle: "Weiterschauen", systemImageName: "play.circle")
        AppShortcut(intent: PlayMediaIntent(), phrases: ["Spiele \(\.$media) in \(.applicationName)", "Spiele etwas in \(.applicationName)"],
                    shortTitle: "Abspielen", systemImageName: "film")
    }
}

/// Hands a link from an intent to the running app.
@MainActor
enum IntentRouter {
    static var handler: ((URL) -> Void)?
    private static var waiting: URL?

    static func open(_ text: String) {
        guard let url = URL(string: text) else { return }
        if let handler { handler(url) } else { waiting = url }
    }

    /// The app's root view registers itself; a link that arrived before it existed is delivered now.
    static func attach(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let waiting { self.waiting = nil; handler(waiting) }
    }
}
