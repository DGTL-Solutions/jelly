import Foundation

/// A wish (Jellyseerr request) that has arrived in the library.
struct ArrivedWish: Identifiable, Equatable {
    let id: String
    let title: String
    /// The title in Jellyfin, once Jellyseerr knows it.
    let jellyfinID: String?
}

/// "Dein Wunsch ist da": remembers which of the profile's wishes are still on their way and notices when one becomes
/// available. Nothing is reported for wishes that were already there the first time it looks.
enum WishWatcher {
    private static func key(_ profileKey: String) -> String { "wishes:\(profileKey)" }

    static func check(account: SeerrAccount, profileKey: String) async -> [ArrivedWish] {
        guard let requests = try? await account.client.myRequests(userID: account.userID) else { return [] }
        let defaults = UserDefaults.standard
        var waiting = defaults.dictionary(forKey: key(profileKey)) as? [String: String] ?? [:]
        var arrived: [ArrivedWish] = []
        for request in requests {
            guard let media = request.media else { continue }
            // Jellyseerr: 5 = available, 4 = partly available (the first episodes of a series are there).
            if [4, 5].contains(media.info.status ?? 1) {
                if let title = waiting.removeValue(forKey: media.key) {
                    arrived.append(ArrivedWish(id: media.key, title: title, jellyfinID: media.info.jellyfinMediaId))
                }
            } else if waiting[media.key] == nil, request.status != 3 {
                // 3 = declined. The name is fetched once, while the wish is new.
                waiting[media.key] = (try? await account.client.title(for: request))?.displayTitle ?? ""
            }
        }
        defaults.set(waiting, forKey: key(profileKey))
        return arrived
    }
}

extension AppModel {
    /// Looks for arrived wishes at most every few minutes; the first one found is shown.
    func checkWishes() async {
        guard let account = seerr, let session, !isKids, Date().timeIntervalSince(lastWishCheck) > 300 else { return }
        lastWishCheck = Date()
        if let wish = await WishWatcher.check(account: account, profileKey: session.key).first { arrivedWish = wish }
    }

    func open(_ wish: ArrivedWish) async {
        guard let id = wish.jellyfinID, let client, let session, let item = try? await client.item(user: session.userID, id: id) else { return }
        pendingOpen = item
    }
}
