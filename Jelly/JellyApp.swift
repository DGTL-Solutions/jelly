import SwiftUI
import AetherEngine

@main
struct JellyApp: App {
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
            RootView()
                .environmentObject(model)
                .environmentObject(model.purchases)
                .preferredColorScheme(.dark)
                .task { Diagnostics.logDevice() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            if model.choosingProfile && !model.accounts.isEmpty && !model.addingAccount {
                ProfilePickerView().transition(.opacity)
            } else if model.showsOnboarding {
                OnboardingView().transition(.opacity)
            } else {
                // A fresh set of tabs per profile: no detail pages or lists from the previous server linger.
                MainView().id(model.session?.key).transition(.opacity)
                    // The subscription offer full screen: everything App Review asks for has to fit and stay reachable.
                    .fullScreenCover(isPresented: $model.showsPaywall) { PaywallView() }
            }
        }
        .task(id: model.session?.key) { await model.offerTrialIfNeeded() }
        .fullScreenCover(item: $model.playback) { request in
            if let client = model.client, let session = model.session {
                PlayerView(request: request, client: client, userID: session.userID)
            }
        }
        .onOpenURL { url in Task { await model.open(url) } }
        .onAppear {
            IdleMonitor.shared.isAllowed = { [weak model] in
                guard let model else { return false }
                return model.session != nil && model.playback == nil && !model.showsOnboarding
            }
            IdleMonitor.shared.start()
        }
        .onChange(of: model.playback?.id) { _, id in if id != nil { IdleMonitor.shared.dismiss() } }
    }
}

/// "Wer schaut gerade?" – switches between profiles saved on this Apple TV without signing in again.
struct ProfilePickerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 70) {
            Text("Wer schaut gerade?").font(.system(size: 64, weight: .bold))
            HStack(spacing: 64) {
                ForEach(model.accounts, id: \.key) { account in
                    Button { model.switchTo(account) } label: {
                        VStack(spacing: 10) {
                            ProfileTile(user: UserDto(id: account.userID, name: account.name, primaryImageTag: account.imageTag), server: account.server)
                            if model.servers.count > 1 {
                                Text(account.serverName ?? account.server.host() ?? "").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(ProfileButtonStyle())
                }
                Button { model.addProfile() } label: { AddProfileTile() }
                    .buttonStyle(ProfileButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.background
                RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.45), .clear], center: .top, startRadius: 20, endRadius: 1200)
            }
            .ignoresSafeArea()
        }
        // Back returns to the current profile when the picker was opened from the settings.
        .onExitCommand { if model.session != nil { withAnimation { model.choosingProfile = false } } }
    }
}

private struct AddProfileTile: View {
    @Environment(\.isFocused) private var focused
    var body: some View {
        VStack(spacing: 26) {
            Circle().strokeBorder(.white.opacity(focused ? 1 : 0.4), style: StrokeStyle(lineWidth: 6, dash: [14, 10]))
                .frame(width: 230, height: 230)
                .overlay { Image(systemName: "plus").font(.system(size: 80, weight: .medium)) }
                .scaleEffect(focused ? 1.12 : 1)
            Text("Profil hinzufügen").font(.headline).foregroundStyle(focused ? .primary : .secondary).offset(y: focused ? 12 : 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: focused)
    }
}
