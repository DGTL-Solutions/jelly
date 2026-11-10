import Foundation

/// The active profile straight from the keychain, for code that runs without the app's model: widgets, Siri and
/// Shortcuts, background refresh.
enum StoredProfile {
    static func client() -> (client: JellyfinClient, session: Session)? {
        let store = SecureStore.load(fallbackDeviceID: "extension")
        guard let session = store.active else { return nil }
        return (JellyfinClient(server: session.server, token: session.token, deviceID: store.deviceID, maxRating: KidsPIN.rating(for: session)), session)
    }

    /// What "Weiterschauen" would show first: titles in progress, then the next episodes.
    static func continueWatching(limit: Int) async -> [BaseItem] {
        guard let (client, session) = client() else { return [] }
        async let resume = try? client.resume(user: session.userID, limit: limit)
        async let nextUp = try? client.nextUp(user: session.userID, limit: limit)
        var seen = Set<String>()
        return ((await resume ?? []) + (await nextUp ?? [])).filter { seen.insert($0.seriesId ?? $0.id).inserted }.prefix(limit).map { $0 }
    }
}
