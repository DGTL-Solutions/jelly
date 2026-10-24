import SwiftUI
import AetherEngine

/// Jelly on iPhone and iPad: the same server, profiles, subscription and player engine as on Apple TV, with a touch UI.
@main
struct JellyMobileApp: App {
    @StateObject private var model = AppModel()

    init() {
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
    }
}

enum MobileTab: String, Hashable { case home, movies, shows, discover, settings, search }

/// A tab bar on iPhone; on iPad the same tabs become a sidebar the viewer can show or hide.
/// The iPhone's tab bar shows five tabs before "More" hides the rest, so there Settings opens from a profile button
/// at the top instead, as in Apple's own apps.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = MobileTab.home
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase
    private let settingsInTabs = UIDevice.current.userInterfaceIdiom != .phone

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house", value: MobileTab.home) {
                MobileBrowseStack(opensPendingItem: true) {
                    HomeScreen().overlay(alignment: .topTrailing) {
                        if !settingsInTabs { SettingsButton(isPresented: $showsSettings, floating: true).padding(.trailing) }
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
            Tab("Erkunden", systemImage: "sparkles", value: MobileTab.discover) { DiscoverScreen() }
            if settingsInTabs {
                Tab("Einstellungen", systemImage: "gearshape", value: MobileTab.settings) { SettingsScreen() }
            }
            Tab(value: MobileTab.search, role: .search) {
                MobileBrowseStack { SearchScreen() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
        // Links from outside (jelly://item/…) land on the home tab's stack.
        .onChange(of: model.pendingOpen) { _, item in if item != nil { tab = .home } }
        .task {
            await model.preferHomeNetwork()
            await model.refreshAccount()
            #if DEBUG
            openDebugTab()
            await model.runDebugActions()
            #endif
        }
        // A phone moves between networks: back in the foreground, check again whether the server is reachable
        // directly at home.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.preferHomeNetwork() } }
        }
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

    @ToolbarContentBuilder private var settingsToolbarItem: some ToolbarContent {
        if !settingsInTabs {
            ToolbarItem(placement: .topBarTrailing) { SettingsButton(isPresented: $showsSettings) }
        }
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
