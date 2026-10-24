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

enum MobileTab: Hashable { case home, movies, shows, discover, settings, search }

/// A tab bar on iPhone; on iPad the same tabs become a sidebar the viewer can show or hide.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = MobileTab.home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house", value: MobileTab.home) {
                MobileBrowseStack(opensPendingItem: true) { HomeScreen() }
            }
            Tab("Filme", systemImage: "film", value: MobileTab.movies) {
                MobileBrowseStack { LibraryScreen(title: String(localized: "Filme"), types: ["Movie"]) }
            }
            Tab("Serien", systemImage: "tv", value: MobileTab.shows) {
                MobileBrowseStack { LibraryScreen(title: String(localized: "Serien"), types: ["Series"]) }
            }
            Tab("Erkunden", systemImage: "sparkles", value: MobileTab.discover) { DiscoverScreen() }
            Tab("Einstellungen", systemImage: "gearshape", value: MobileTab.settings) { SettingsScreen() }
            Tab(value: MobileTab.search, role: .search) {
                MobileBrowseStack { SearchScreen() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Links from outside (jelly://item/…) land on the home tab's stack.
        .onChange(of: model.pendingOpen) { _, item in if item != nil { tab = .home } }
    }
}
