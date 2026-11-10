import SwiftUI
import StoreKit
import AetherEngine

/// Jelly on iPhone and iPad: the same server, profiles, subscription and player engine as on Apple TV, with a touch UI.
@main
struct JellyMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: JellyAppDelegate
    @StateObject private var model = AppModel()

    init() {
        JellyfinClient.deviceName = UIDevice.current.model
        // The player engine's own log is detailed; its failures and route changes go into Jelly's diagnostics log.
        EngineLog.handler = { line in
            let lower = line.lowercased()
            guard ["error", "fail", "refus", "escalat", "fallback", "libavcodec"].contains(where: lower.contains) else { return }
            Diagnostics.log("engine " + String(Diagnostics.redact(line).prefix(300)))
        }
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(model)
                .environmentObject(model.purchases)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        ZStack {
            if model.choosingProfile && !model.accounts.isEmpty && !model.addingAccount {
                ProfilePickerScreen().transition(.opacity)
            } else if model.showsOnboarding {
                OnboardingFlow().transition(.opacity)
            } else {
                // A fresh set of tabs per profile: no detail pages or lists from the previous server linger.
                MainTabs().id(model.session?.key).transition(.opacity)
                    .fullScreenCover(isPresented: $model.showsPaywall) { MobilePaywall() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsOnboarding)
        .task(id: model.session?.key) { await model.offerTrialIfNeeded() }
        .fullScreenCover(item: $model.playback) { request in
            if let client = model.client, let session = model.session {
                MobilePlayerScreen(request: request, client: client, userID: session.userID)
            }
        }
        .onOpenURL { url in Task { await model.open(url) } }
        .parentGate()
        .sheet(item: $model.pendingSignIn) { link in SignInApprovalSheet(link: link) }
        #if DEBUG
        // Simulator testing only: JELLY_ROTATE="22:landscape,30:portrait" turns the screen at those seconds after launch.
        .task {
            guard let plan = ProcessInfo.processInfo.environment["JELLY_ROTATE"] else { return }
            var elapsed = 0.0
            for step in plan.split(separator: ",") {
                let parts = step.split(separator: ":")
                guard parts.count == 2, let at = Double(parts[0]) else { continue }
                try? await Task.sleep(for: .seconds(max(0, at - elapsed)))
                elapsed = at
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { continue }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: parts[1] == "landscape" ? .landscape : .portrait))
            }
        }
        #endif
        .task {
            model.offlineCopy = { [weak model] item in DownloadCenter.shared.offlineMedia(for: item, profileKey: model?.session?.key) }
        }
        // Back from the player right after a film or episode ran to its end is a good moment to ask for a rating –
        // never in the middle of one, and never after playback failed or was given up early.
        .onChange(of: model.playback == nil) { _, closed in
            guard closed else { return }
            // The player reports how far it got when its screen is gone, which is after this change – so check later.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard model.playback == nil, !model.showsPaywall, ReviewPrompt.shouldAsk() else { return }
                requestReview()
            }
        }
    }
}

enum MobileTab: String, Hashable { case home, movies, shows, discover, downloads, settings, search }

/// A tab bar on iPhone; on iPad the same tabs become a sidebar the viewer can show or hide.
/// The iPhone's tab bar shows five tabs before "More" hides the rest, so there Settings opens from a profile button
/// at the top instead, as in Apple's own apps.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = MobileTab.home
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var pick = DownloadCenter.pick
    private let settingsInTabs = UIDevice.current.userInterfaceIdiom != .phone
    /// A sixth tab would push one behind "More" on iPhone; there Downloads open from a button on the start page
    /// (once something is saved) and from Settings.
    private let downloadsInTabs = UIDevice.current.userInterfaceIdiom != .phone
    @State private var showsDownloads = false
    @ObservedObject private var downloads = DownloadCenter.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house", value: MobileTab.home) {
                MobileBrowseStack(opensPendingItem: true) {
                    HomeScreen().overlay(alignment: .topTrailing) {
                        HStack(spacing: 10) {
                            TogetherStatusButton(syncPlay: model.syncPlay)
                            if !downloadsInTabs, !downloads.records(profileKey: model.session?.key).isEmpty {
                                DownloadsButton(isPresented: $showsDownloads)
                            }
                            if !settingsInTabs { SettingsButton(isPresented: $showsSettings, floating: true) }
                        }
                        .padding(.trailing)
                    }
                }
            }
            Tab("Filme", systemImage: "film", value: MobileTab.movies) {
                MobileBrowseStack {
                    LibraryScreen(title: String(localized: "Filme"), types: ["Movie"]).toolbar { settingsToolbarItem }
                }
            }
            Tab("Serien", systemImage: "tv", value: MobileTab.shows) {
                MobileBrowseStack {
                    LibraryScreen(title: String(localized: "Serien"), types: ["Series"]).toolbar { settingsToolbarItem }
                }
            }
            if !model.isKids {
                Tab("Erkunden", systemImage: "sparkles", value: MobileTab.discover) { DiscoverScreen() }
            }
            if downloadsInTabs {
                Tab("Downloads", systemImage: "arrow.down.circle", value: MobileTab.downloads) { DownloadsScreen() }
            }
            if settingsInTabs {
                Tab("Einstellungen", systemImage: "gearshape", value: MobileTab.settings) { ParentLocked { SettingsScreen() } }
            }
            Tab(value: MobileTab.search, role: .search) {
                MobileBrowseStack { SearchScreen() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showsSettings) { ParentLocked { SettingsScreen() } }
        .sheet(isPresented: $showsDownloads) { DownloadsScreen() }
        .sheet(item: $pick.current) { DownloadQualitySheet(pick: $0) }
        // Links from outside (jelly://item/…) land on the home tab's stack.
        .onChange(of: model.pendingOpen) { _, item in if item != nil { tab = .home } }
        .task {
            await model.preferHomeNetwork()
            model.connectLink()
            await model.refreshAccount()
            await syncDownloads()
            #if DEBUG
            openDebugTab()
            await model.runDebugActions()
            await debugDownload()
            #endif
        }
        // A phone moves between networks: back in the foreground, check again whether the server is reachable
        // directly at home.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.preferHomeNetwork()
                    model.connectLink()
                    await syncDownloads()
                }
            }
        }
        // Without a connection at launch the start page can't load; downloads still play.
        .onReceive(NotificationCenter.default.publisher(for: .jellyShowDownloads)) { _ in
            if downloadsInTabs { tab = .downloads } else { showsDownloads = true }
        }
    }

    private func syncDownloads() async {
        guard let client = model.client, let session = model.session else { return }
        await DownloadCenter.shared.sync(client: client, session: session)
    }

    #if DEBUG
    private static var debugTabOpened = false

    /// Simulator testing only: JELLY_TAB=movies|shows|discover|settings|search selects that tab once per launch
    /// (on iPhone, "settings" opens the settings sheet).
    private func openDebugTab() {
        guard !Self.debugTabOpened, let name = ProcessInfo.processInfo.environment["JELLY_TAB"],
              let wanted = MobileTab(rawValue: name) else { return }
        Self.debugTabOpened = true
        if wanted == .settings && !settingsInTabs { showsSettings = true } else { tab = wanted }
    }
    #endif

    /// Simulator testing only: JELLY_DOWNLOAD=<item id>[,<item id>…] opens the quality sheet for those items, or with
    /// JELLY_DOWNLOAD_QUALITY=original|better|good starts the downloads right away.
    private func debugDownload() async {
        let env = ProcessInfo.processInfo.environment
        // JELLY_PLAY_OFFLINE=<item id> plays a finished download, also without a server.
        if let id = env["JELLY_PLAY_OFFLINE"], let record = DownloadCenter.shared.record(itemID: id, profileKey: model.session?.key),
           let item = DownloadCenter.shared.item(record) {
            model.play(item)
            // JELLY_CLOSE_AFTER=<seconds> closes the player again, as the viewer would.
            if let seconds = env["JELLY_CLOSE_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(seconds))
                model.playback = nil
            }
        }
        guard let ids = env["JELLY_DOWNLOAD"]?.split(separator: ","), let client = model.client, let session = model.session else { return }
        var items: [BaseItem] = []
        for id in ids { if let item = try? await client.item(user: session.userID, id: String(id)) { items.append(item) } }
        if let quality = env["JELLY_DOWNLOAD_QUALITY"].flatMap(DownloadQuality.init(rawValue:)) {
            for item in items {
                do { try await DownloadCenter.shared.start(item, quality: quality, client: client, session: session, audioLanguage: nil) }
                catch { print("[Jelly] Debug download failed: \(error)") }
            }
        } else {
            DownloadCenter.pick.open(items, title: items.count == 1 ? items[0].name : "Test")
        }
    }

    @ToolbarContentBuilder private var settingsToolbarItem: some ToolbarContent {
        if !settingsInTabs {
            ToolbarItem(placement: .topBarTrailing) { SettingsButton(isPresented: $showsSettings) }
        }
    }
}

/// Opens the downloads on iPhone, over the start page's artwork; a ring while something is still loading.
private struct DownloadsButton: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadCenter.shared

    private var loading: [DownloadRecord] {
        downloads.records(profileKey: model.session?.key).filter { $0.state == .downloading || $0.state == .preparing }
    }

    var body: some View {
        Button { isPresented = true } label: {
            Group {
                if loading.isEmpty {
                    Image(systemName: "arrow.down.circle").font(.system(size: 20, weight: .medium))
                } else {
                    DownloadRing(progress: loading.map(\.progress).reduce(0, +) / Double(loading.count))
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(.ultraThinMaterial))
        }
        .foregroundStyle(.white)
        .accessibilityLabel(Text("Downloads"))
    }
}

/// The profile button that opens Settings on iPhone.
private struct SettingsButton: View {
    @Binding var isPresented: Bool
    /// Over artwork, without a navigation bar behind it.
    var floating = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: floating ? 20 : 17, weight: .medium))
                .frame(width: floating ? 40 : nil, height: floating ? 40 : nil)
                .background { if floating { Circle().fill(.ultraThinMaterial) } }
        }
        .foregroundStyle(floating ? .white : Theme.accent)
        .accessibilityLabel(Text("Einstellungen"))
    }
}

extension Notification.Name {
    /// "Downloads ansehen" on the offline start page.
    static let jellyShowDownloads = Notification.Name("jellyShowDownloads")
}

/// Hands background download events to `DownloadCenter` when the system wakes Jelly for them.
final class JellyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadCenter.sessionIdentifier else { return completionHandler() }
        Task { @MainActor in DownloadCenter.shared.backgroundCompletion = completionHandler }
    }
}
