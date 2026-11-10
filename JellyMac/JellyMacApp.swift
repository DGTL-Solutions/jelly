import SwiftUI
import AetherEngine
import UserNotifications

/// Jelly on the Mac: the iPhone and iPad app's screens in a window, with the Mac's menus and keyboard.
@main
struct JellyMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: JellyMacDelegate
    @StateObject private var model = AppModel()

    init() {
        JellyfinClient.deviceName = "Mac"
        EngineLog.handler = { line in
            let lower = line.lowercased()
            guard ["error", "fail", "refus", "escalat", "fallback", "libavcodec"].contains(where: lower.contains) else { return }
            Diagnostics.log("engine " + String(Diagnostics.redact(line).prefix(300)))
        }
    }

    var body: some Scene {
        Window("Jelly", id: "main") {
            MobileRootView()
                .environmentObject(model)
                .environmentObject(model.purchases)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // One window, no documents.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Wiedergabe") {
                Button("Wiedergabe / Pause") { PlaybackHub.shared.player?.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("10 Sekunden zurück") { if let player = PlaybackHub.shared.player { player.seek(to: player.position - 10) } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("30 Sekunden vor") { if let player = PlaybackHub.shared.player { player.seek(to: player.position + 30) } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Wiedergabe beenden") { model.playback = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

final class JellyMacDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A click on "Dein Wunsch ist da" opens the title.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: text) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
