import AppKit
import AVKit
import SwiftUI

// The iPhone and iPad screens are shared with the Mac. What they use from UIKit and from iOS-only SwiftUI gets a Mac
// counterpart here, so the screens themselves stay almost free of platform checks.

typealias UIImage = NSImage
typealias UIColor = NSColor

extension NSImage {
    var pixels: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    convenience init(pixels: CGImage) { self.init(cgImage: pixels, size: .zero) }
    /// AppKit decodes when it draws; there is nothing to prepare ahead.
    func byPreparingForDisplay() async -> NSImage? { self }
    var scale: CGFloat { 1 }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGray5: NSColor { .quaternaryLabelColor }
    static var systemGray6: NSColor { .quinaryLabel }
}

/// A Mac behaves like a big iPad in the shared screens.
@MainActor
enum UIDevice {
    enum Idiom { case phone, pad, mac }
    struct Device {
        let userInterfaceIdiom = Idiom.pad
        let model = "Mac"
        var name: String { Host.current().localizedName ?? "Mac" }
    }
    static let current = Device()
}

@MainActor
enum UIScreen {
    struct Screen {
        var bounds: CGRect { NSApp.keyWindow?.contentLayoutRect ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
        var scale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }
    }
    static let main = Screen()
}

@MainActor
final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    static let openSettingsURLString = "x-apple.systempreferences:"
    var applicationState: State { NSApp.isActive ? .active : .inactive }
    @discardableResult func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    var isIdleTimerDisabled = false
}

@MainActor
final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

// MARK: iOS-only SwiftUI

enum MacTitleDisplayMode { case automatic, inline, large }
enum MacKeyboardType { case `default`, URL, numberPad, emailAddress, asciiCapable, decimalPad }
enum MacAutocapitalization { case never, words, sentences, characters }

extension View {
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }
    func keyboardType(_ type: MacKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ mode: MacAutocapitalization?) -> some View { self }
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }

    /// A cover fills the window on the Mac: there is no separate full-screen layer above a window's content.
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay {
            if isPresented.wrappedValue {
                content().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background).transition(.opacity)
                    .onDisappear { onDismiss?() }
            }
        }
    }

    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        overlay {
            if let value = item.wrappedValue {
                content(value).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background).transition(.opacity)
                    .onDisappear { onDismiss?() }
            }
        }
    }
}

enum MacDrawerDisplayMode { case automatic, always }

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: MacDrawerDisplayMode) -> SearchFieldPlacement { .automatic }
}

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}

extension PickerStyle where Self == MenuPickerStyle {
    /// A row that opens a list of choices on iPhone; a pop-up button on the Mac.
    static var navigationLink: MenuPickerStyle { .menu }
}

extension View {
    /// The Mac manages subscriptions in the App Store's account page.
    func manageSubscriptionsSheet(isPresented: Binding<Bool>) -> some View {
        onChange(of: isPresented.wrappedValue) { _, show in
            guard show else { return }
            isPresented.wrappedValue = false
            NSWorkspace.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
        }
    }
}

extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var bottomBar: ToolbarItemPlacement { .automatic }
}

// MARK: Player

/// Picture in Picture on the Mac is the window itself – it can be made small and kept on top.
@MainActor
final class PlayerPictureInPicture: ObservableObject {
    let isSupported = false
    let isPossible = false
    let isActive = false
    var onStopInBackground: (@MainActor () -> Void)?
    func bind(_ engine: Any) {}
    func toggle() {}
    func invalidatePlaybackState() {}
    func tearDown() {}
}

/// The engine publishes Now Playing itself; the Mac needs nothing staged around it.
@MainActor
final class PlayerSystemBridge: ObservableObject {
    @Published private(set) var externalRoute: String?
    func bind(player: PlayerController, client: JellyfinClient?) {}
    func tearDown() {}
}

/// The system's AirPlay picker.
struct PlayerAirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

@MainActor
enum PlayerOrientation {
    static func enterPlayback() {}
    static func leavePlayback() {}
}
