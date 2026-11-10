#if !os(macOS)
import BackgroundTasks
#endif
import UserNotifications

/// Optional on iPhone and iPad: a notification when a Jellyseerr wish has arrived, also while Jelly is closed.
/// The system wakes Jelly now and then (background refresh) to ask Jellyseerr; nothing goes through other servers.
enum WishNotifications {
    static let settingKey = "wishNotifications"
    static let taskID = "de.jelly.wishes"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Asks for permission when the viewer switches the setting on. `false` if notifications are not allowed.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: settingKey)
        if granted { schedule() }
        return granted
    }

    static func register() {
        #if !os(macOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            schedule()
            let work = Task { await check(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    /// Asks the system for the next wake-up, about once an hour at best. (A Mac only looks while Jelly is open.)
    static func schedule() {
        #if !os(macOS)
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// Without the app's model: the active profile and its Jellyseerr sign-in come from the keychain.
    private static func check() async {
        guard isEnabled, let session = SecureStore.load(fallbackDeviceID: "").active, KidsPIN.rating(for: session) == nil,
              let data = SecureStore.data(for: "seerr:\(session.key)"), let account = try? JSONDecoder().decode(SeerrAccount.self, from: data) else { return }
        for wish in await WishWatcher.check(account: account, profileKey: session.key) { await notify(wish) }
    }

    static func notify(_ wish: ArrivedWish) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Dein Wunsch ist da")
        content.body = String(localized: "„\(wish.title)“ ist jetzt in deiner Mediathek.")
        content.sound = .default
        if let id = wish.jellyfinID { content.userInfo = ["url": "jelly://item/\(id)"] }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wish-\(wish.id)", content: content, trigger: nil))
    }
}
