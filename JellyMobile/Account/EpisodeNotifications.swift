import UserNotifications

/// Optional on iPhone and iPad: a notification when a new episode of a series in progress has arrived on the server,
/// also while Jelly is closed. Shares the background refresh of `WishNotifications`; nothing goes through other servers.
enum EpisodeNotifications {
    static let settingKey = "episodeNotifications"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Asks for permission when the viewer switches the setting on, and notes what is on the server right now so
    /// only later episodes count as new. `false` if notifications are not allowed.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: settingKey)
        if granted {
            _ = await news()
            WishNotifications.schedule()
        }
        return granted
    }

    /// Without the app's model: the active profile comes from the keychain.
    private static func news() async -> [NewEpisodes] {
        guard let (client, session) = StoredProfile.client() else { return [] }
        return await EpisodeWatcher.check(client: client, session: session)
    }

    static func check() async {
        guard isEnabled else { return }
        // A library scan can bring many series at once: a handful of notifications is enough.
        for series in await news().prefix(4) { await notify(series) }
    }

    static func notify(_ news: NewEpisodes) async {
        guard let first = news.episodes.first else { return }
        let content = UNMutableNotificationContent()
        if news.episodes.count == 1 {
            content.title = String(localized: "Neue Folge: \(news.series)", comment: "Notification title with the series' name")
            content.body = [first.episodeLabel, first.name].compactMap { $0 }.joined(separator: " – ")
        } else {
            content.title = String(localized: "Neue Folgen: \(news.series)", comment: "Notification title with the series' name")
            content.body = String(localized: "\(news.episodes.count) neue Folgen sind in deiner Mediathek.")
        }
        content.sound = .default
        content.userInfo = ["url": "jelly://item/\(news.episodes.count == 1 ? first.id : news.id)"]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "episodes-\(news.id)", content: content, trigger: nil))
    }
}
