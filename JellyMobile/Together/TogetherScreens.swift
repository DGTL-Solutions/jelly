import SwiftUI

/// On a title's page: play it on another device (the Apple TV in the living room) or start it for a group.
struct PlayElsewhereMenu: View {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel
    @AppStorage(SyncPlay.settingKey) private var syncPlayEnabled = false
    @State private var sessions: [RemoteSession] = []
    @State private var remote: RemoteSession?
    @State private var showsGroups = false
    @State private var sent = 0

    private var showsSyncPlay: Bool { syncPlayEnabled && SyncPlay.isAllowed(model.user) }

    var body: some View {
        // A stack, not a group: it exists (and loads) even while it shows nothing.
        ZStack {
            if !sessions.isEmpty || showsSyncPlay {
                Menu {
                    ForEach(sessions) { session in
                        Button { play(on: session) } label: {
                            Label("Auf \(session.deviceName ?? session.client ?? "Gerät") abspielen", systemImage: session.symbol)
                        }
                    }
                    if showsSyncPlay {
                        Button { showsGroups = true } label: { Label("Gemeinsam schauen …", systemImage: "person.2") }
                    }
                } label: {
                    Image(systemName: model.syncPlay.group != nil ? "person.2.fill" : "tv.badge.wifi")
                }
                .accessibilityLabel("Woanders abspielen")
            }
        }
        .task(id: model.refreshID) {
            guard let client = model.client, let session = model.session else { return }
            sessions = (try? await client.controllableSessions(user: session.userID)) ?? []
        }
        .sheet(item: $remote) { RemoteSheet(session: $0) }
        .sheet(isPresented: $showsGroups) { SyncPlayGroupsView(onClose: { showsGroups = false }, syncPlay: model.syncPlay) }
        .sensoryFeedback(.success, trigger: sent)
    }

    private func play(on session: RemoteSession) {
        guard let client = model.client else { return }
        Task {
            try? await client.play(on: session.id, itemID: item.id, seconds: item.progress > 0.97 ? 0 : item.resumeSeconds)
            sent += 1
            remote = session
        }
    }
}

/// A remote for what plays on another device: where it stands, pause, jump, stop.
struct RemoteSheet: View {
    let session: RemoteSession
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var live: RemoteSession?
    @State private var scrub: Double?

    private var current: RemoteSession { live ?? session }
    private var item: BaseItem? { current.nowPlayingItem }
    private var position: Double { scrub ?? Ticks.seconds(current.playState?.positionTicks) }
    private var duration: Double { item?.runtimeSeconds ?? 0 }
    private var paused: Bool { current.playState?.isPaused ?? false }

    var body: some View {
        VStack(spacing: 22) {
            Label(current.deviceName ?? "Jellyfin", systemImage: current.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let item {
                VStack(spacing: 6) {
                    Text(item.isEpisode ? item.seriesName ?? item.name : item.name).font(.title3.bold()).multilineTextAlignment(.center)
                    if item.isEpisode {
                        Text([item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { position }, set: { scrub = $0 }), in: 0...max(1, duration)) { editing in
                        if !editing, let target = scrub { send("Seek", seconds: target) }
                    }
                    HStack {
                        Text(Format.clock(position)); Spacer(); Text(Format.clock(duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 34) {
                    Button { send("Seek", seconds: max(0, position - 10)) } label: { Image(systemName: "gobackward.10") }
                    Button { send(paused ? "Unpause" : "Pause") } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 44)).frame(width: 60)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button { send("Seek", seconds: min(duration, position + 30)) } label: { Image(systemName: "goforward.30") }
                }
                .font(.system(size: 30)).foregroundStyle(.primary)
                Button(role: .destructive) { send("Stop"); dismiss() } label: { Label("Wiedergabe beenden", systemImage: "stop.fill") }
                    .padding(.top, 4)
            } else {
                Spacer(minLength: 10)
                ProgressView()
                Text("Wartet auf \(current.deviceName ?? "das Gerät") …").foregroundStyle(.secondary)
                Spacer(minLength: 10)
            }
        }
        .padding(26)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func refresh() async {
        guard let client = model.client, let user = model.session?.userID,
              let sessions = try? await client.controllableSessions(user: user) else { return }
        if let found = sessions.first(where: { $0.id == session.id }) {
            live = found
            if scrub != nil, abs(Ticks.seconds(found.playState?.positionTicks) - (scrub ?? 0)) < 3 { scrub = nil }
        }
    }

    private func send(_ command: String, seconds: Double? = nil) {
        guard let client = model.client else { return }
        if command == "Pause" { live?.playState?.isPaused = true }
        if command == "Unpause" { live?.playState?.isPaused = false }
        if let seconds { scrub = seconds }
        Task { try? await client.control(session.id, command, seconds: seconds) }
    }
}

/// On the start page: appears while something of this account plays on another device, or while in a SyncPlay group.
struct TogetherStatusButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var syncPlay: SyncPlay
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: RemoteSession?
    @State private var remote: RemoteSession?
    @State private var showsGroups = false

    var body: some View {
        // A stack, not a group: it exists (and loads) even while it shows nothing.
        ZStack {
            if syncPlay.group != nil {
                button("person.2.fill", label: "Gemeinsam schauen") { showsGroups = true }
            } else if let playing {
                button(playing.symbol, label: "Fernbedienung") { remote = playing }
            }
        }
        .task(id: "\(model.refreshID)-\(scenePhase == .active)") {
            guard scenePhase == .active, let client = model.client, let user = model.session?.userID else { return }
            playing = (try? await client.controllableSessions(user: user))?.first { $0.nowPlayingItem != nil }
        }
        .sheet(item: $remote) { RemoteSheet(session: $0) }
        .sheet(isPresented: $showsGroups) { SyncPlayGroupsView(onClose: { showsGroups = false }, syncPlay: syncPlay) }
    }

    private func button(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40)
                .background { Circle().fill(.ultraThinMaterial) }
        }
        .foregroundStyle(Theme.accent)
        .accessibilityLabel(Text(label))
    }
}
