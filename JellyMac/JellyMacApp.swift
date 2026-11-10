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
                // Settings and other forms as grouped cards, like on iPad, instead of the Mac's label columns.
                .formStyle(.grouped)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // One window, no documents.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Wiedergabe") {
                // Plain keys, so only while a film is open: otherwise the space bar belongs to the search field.
                Group {
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
                .disabled(model.playback == nil)
            }
        }
    }
}

final class JellyMacDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        // Testing without a screen to look at: JELLY_SHOT=<seconds> writes the window's picture to the app's temporary
        // folder (shot.png) at that interval.
        if let seconds = ProcessInfo.processInfo.environment["JELLY_SHOT"].flatMap(Double.init) {
            Timer.scheduledTimer(withTimeInterval: max(0.5, seconds), repeats: true) { _ in
                MainActor.assumeIsolated {
                    // The window as the window server draws it (materials, video and all); a process may always
                    // picture its own windows. The call left the SDK, not the system.
                    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                    // Commands for the running app, one per line in command.txt next to the picture: "tab:movies",
                    // "stop", or a jelly:// link. Each file is taken once.
                    let commands = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("command.txt")
                    if let text = try? String(contentsOf: commands, encoding: .utf8) {
                        try? FileManager.default.removeItem(at: commands)
                        for line in text.split(separator: "\n").map(String.init) {
                            if line.hasPrefix("jelly://"), let url = URL(string: line) { NSWorkspace.shared.open(url) }
                            else { NotificationCenter.default.post(name: Notification.Name("jellyDebugCommand"), object: line) }
                        }
                    }
                    // JELLY_WINDOW=1440x900 gives the window that size, for App Store screenshots.
                    if let size = ProcessInfo.processInfo.environment["JELLY_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
                       let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }), window.frame.size != CGSize(width: size[0], height: size[1]) {
                        let top = window.screen?.visibleFrame.maxY ?? window.frame.maxY
                        window.setFrame(CGRect(x: window.screen?.visibleFrame.minX ?? 0, y: top - size[1], width: size[0], height: size[1]), display: true)
                    }
                    // In Stage Manager a window in the background is a small tilted thumbnail: screenshots need Jelly in front.
                    if ProcessInfo.processInfo.environment["JELLY_WINDOW"] != nil, !NSApp.isActive {
                        NSApp.windows.first { $0.isVisible && $0.frame.width > 300 }?.orderFrontRegardless()
                        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    }
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }),
                          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                          let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
                    else { return }
                    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("shot.png"))
                }
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A click on "Dein Wunsch ist da" opens the title.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: text) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
