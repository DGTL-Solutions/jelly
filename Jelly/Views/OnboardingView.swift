import SwiftUI

struct ServerTarget: Hashable {
    let url: URL
    let id: String
    let name: String
    var version: String?

    init(url: URL, id: String, name: String, version: String? = nil) {
        self.url = url
        self.id = id
        self.name = name
        self.version = version
    }

    init(url: URL, info: PublicSystemInfo) {
        self.init(url: url, id: info.id ?? url.absoluteString, name: info.serverName ?? url.host() ?? "Jellyfin", version: info.version)
    }

    var info: PublicSystemInfo { PublicSystemInfo(id: id, serverName: name, version: version) }
}

enum OnboardingRoute: Hashable {
    case manualServer
    case users(ServerTarget)
    case password(ServerTarget, UserDto)
    case manualLogin(ServerTarget)
    case quickConnect(ServerTarget)
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [OnboardingRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ServerPickerView(path: $path)
                .navigationDestination(for: OnboardingRoute.self) { route in
                    switch route {
                    case .manualServer: ManualServerView(path: $path)
                    case .users(let server): UserPickerView(server: server, path: $path)
                    case .password(let server, let user): PasswordView(server: server, user: user, path: $path)
                    case .manualLogin(let server): ManualLoginView(server: server)
                    case .quickConnect(let server): QuickConnectView(server: server)
                    }
                }
        }
        .onAppear {
            if let server = model.preselectedServer {
                path = [.users(ServerTarget(url: server.url, id: server.id, name: server.name, version: server.version))]
            }
        }
        // Adding a profile can be abandoned with the remote's back button from the first screen.
        .onExitCommand { if model.addingAccount && path.isEmpty { model.cancelAddingProfile() } }
    }
}

/// Shared two-column layout: brand on the left, the current step on the right.
struct OnboardingLayout<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 28) {
                AppMark(size: 160)
                Text(title).font(.system(size: 64, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 640, alignment: .leading)
            content.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.background
                RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.55), .clear], center: .topLeading, startRadius: 40, endRadius: 1300)
                RadialGradient(colors: [Color(red: 0.0, green: 0.45, blue: 0.7).opacity(0.35), .clear], center: .bottomTrailing, startRadius: 40, endRadius: 1100)
            }
            .ignoresSafeArea()
        }
    }
}

/// Jelly's logo as in the app icon: a flat play button in the brand gradient. `size` is its width.
struct AppMark: View {
    var size: CGFloat = 120
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(Theme.brand)
            .frame(width: size, height: size / 1.42)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.012)
            }
            .shadow(color: Color(red: 0.4, green: 0.3, blue: 0.9).opacity(0.35), radius: 24, y: 8)
    }
}

// MARK: - Server

struct ServerPickerView: View {
    @Binding var path: [OnboardingRoute]
    @EnvironmentObject private var model: AppModel
    @StateObject private var discovery = ServerDiscovery()
    @State private var connecting: String?
    @State private var error: String?
    @FocusState private var focusedServer: String?

    private var found: [DiscoveredServer] {
        discovery.servers.filter { server in !model.knownServers.contains { $0.id == server.id } }
    }

    var body: some View {
        OnboardingLayout(title: model.addingAccount ? String(localized: "Server hinzufügen") : String(localized: "Willkommen bei Jelly"),
                         subtitle: model.addingAccount
                            ? String(localized: "Verbinde einen weiteren Jellyfin-Server. Deine bisherigen Anmeldungen bleiben erhalten; gewechselt wird in den Einstellungen.")
                            : String(localized: "Wähle deinen Jellyfin-Server. Server in deinem Netzwerk werden automatisch gefunden.")) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(model.knownServers) { server in
                    serverButton(id: server.id, name: server.name, url: server.url,
                                 detail: model.accounts.contains { $0.serverKey == server.id }
                                    ? String(localized: "Verbunden", comment: "Server status: signed in")
                                    : String(localized: "Zuletzt verwendet", comment: "Server status: used before"))
                        .contextMenu { Button("Server entfernen", role: .destructive) { model.forget(server) } }
                }
                ForEach(found) { server in
                    serverButton(id: server.id, name: server.name, url: server.url, detail: server.version.map { "Jellyfin \($0)" })
                }
                if discovery.isSearching {
                    HStack(spacing: 20) {
                        ProgressView()
                        Text("Suche im Netzwerk …").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20).padding(.horizontal, 30)
                } else if found.isEmpty && model.knownServers.isEmpty {
                    Text("Kein Server automatisch gefunden. Gib die Adresse einfach ein.")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                Button { path.append(.manualServer) } label: {
                    Label("Adresse eingeben", systemImage: "keyboard").frame(maxWidth: .infinity, alignment: .leading)
                }
                if !discovery.isSearching {
                    Button { Task { await discovery.search() } } label: {
                        Label("Erneut suchen", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            }
            .frame(maxWidth: 820)
            .animation(.easeOut, value: discovery.servers)
        }
        .defaultFocus($focusedServer, model.knownServers.first?.id)
        .task { await discovery.search() }
        .onChange(of: discovery.servers) { _, servers in servers.forEach(model.noteDiscovered) }
        .onChange(of: found.first?.id) { _, id in
            // The first server found takes focus so a single click connects.
            if focusedServer == nil, model.knownServers.isEmpty, let id { focusedServer = id }
        }
    }

    private func serverButton(id: String, name: String, url: URL, detail: String?) -> some View {
        Button {
            Task { await connect(id: id, url: url) }
        } label: {
            HStack(spacing: 26) {
                Image(systemName: "server.rack").font(.title2).frame(width: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text([url.host(percentEncoded: false).map { host in url.port.map { "\(host):\($0)" } ?? host }, detail]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if connecting == id { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
            }
            .padding(.vertical, 10)
        }
        .focused($focusedServer, equals: id)
        .disabled(connecting != nil)
    }

    private func connect(id: String, url: URL) async {
        connecting = id
        error = nil
        defer { connecting = nil }
        do {
            let info = try await model.anonymousClient(url).publicInfo()
            path.append(.users(ServerTarget(url: url, info: info)))
        } catch {
            let host = url.host() ?? String(localized: "Server", comment: "The Jellyfin server")
            self.error = String(localized: "\(host) ist gerade nicht erreichbar.", comment: "<server address> is currently unreachable")
        }
    }
}

struct ManualServerView: View {
    @Binding var path: [OnboardingRoute]
    @State private var address = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OnboardingLayout(title: String(localized: "Server-Adresse"),
                         subtitle: String(localized: "Eine IP-Adresse oder Domain reicht – Protokoll und Port probiert Jelly automatisch aus.")) {
            VStack(alignment: .leading, spacing: 26) {
                TextField("z. B. 192.168.1.20 oder jellyfin.example.com", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .onSubmit(connect)
                Button(action: connect) {
                    HStack {
                        Text(busy ? "Verbinde …" : "Verbinden")
                        Spacer()
                        if busy { ProgressView() } else { Image(systemName: "arrow.right") }
                    }
                }
                .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            }
            .frame(maxWidth: 820)
        }
        .onAppear { fieldFocused = true }
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let (url, info) = try await ServerLocator.resolve(address)
                path.removeLast()
                path.append(.users(ServerTarget(url: url, info: info)))
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? JellyError.serverNotFound.errorDescription
            }
        }
    }
}

// MARK: - Users

struct UserPickerView: View {
    let server: ServerTarget
    @Binding var path: [OnboardingRoute]
    @EnvironmentObject private var model: AppModel
    @State private var users: [UserDto] = []
    @State private var quickConnect = false
    @State private var loaded = false
    @State private var busyUser: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 60) {
            VStack(spacing: 14) {
                Text(users.isEmpty ? "Anmelden" : "Wer schaut gerade?").font(.system(size: 64, weight: .bold))
                Text(server.name).font(.title3).foregroundStyle(.secondary)
            }
            if !loaded {
                ProgressView().frame(height: 300)
            } else if !users.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 64) {
                        ForEach(users) { user in
                            Button { select(user) } label: {
                                ProfileTile(user: user, server: server.url, busy: busyUser == user.id)
                            }
                            .buttonStyle(ProfileButtonStyle())
                            .disabled(busyUser != nil)
                        }
                    }
                    .padding(40)
                    .frame(minWidth: 1700)
                }
                .scrollClipDisabled()
            }
            HStack(spacing: 40) {
                if quickConnect {
                    Button { path.append(.quickConnect(server)) } label: {
                        Label("Mit Code anmelden", systemImage: "iphone.and.arrow.forward")
                    }
                }
                Button { path.append(.manualLogin(server)) } label: {
                    Label(users.isEmpty ? "Benutzername & Passwort" : "Anderer Benutzer", systemImage: "person.badge.key")
                }
            }
            .opacity(loaded ? 1 : 0)
            if let error { Text(error).foregroundStyle(.orange) }
            if quickConnect {
                Text("Mit Code anmelden: Bestätige die Anmeldung in der Jellyfin-App auf deinem Handy – ganz ohne Tippen.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .task {
            let client = model.anonymousClient(server.url)
            async let users = try? client.publicUsers()
            async let quick = client.quickConnectEnabled()
            self.users = await users ?? []
            quickConnect = await quick
            withAnimation { loaded = true }
        }
    }

    private func select(_ user: UserDto) {
        guard user.needsPassword else {
            busyUser = user.id
            Task {
                defer { busyUser = nil }
                do {
                    let result = try await model.anonymousClient(server.url).authenticate(username: user.name, password: "")
                    model.signIn(server: server.url, info: server.info, result: result, password: "")
                } catch {
                    path.append(.password(server, user))
                }
            }
            return
        }
        path.append(.password(server, user))
    }
}

struct ProfileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ProfileTile: View {
    let user: UserDto
    let server: URL
    var busy = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(spacing: 26) {
            Avatar(user: user, server: server, size: 230)
                .overlay(Circle().strokeBorder(.white, lineWidth: focused ? 8 : 0))
                .overlay { if busy { ProgressView().padding(30).background(.ultraThinMaterial, in: Circle()) } }
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: 30, y: 20)
            Text(user.name)
                .font(.headline)
                .foregroundStyle(focused ? .primary : .secondary)
                .offset(y: focused ? 12 : 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: focused)
    }
}

struct Avatar: View {
    let user: UserDto
    let server: URL
    var size: CGFloat = 200
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            Text(user.name.prefix(1).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if user.primaryImageTag != nil {
                RemoteImage(url: model.anonymousClient(server).userImageURL(user: user.id, tag: user.primaryImageTag))
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }

    private var gradient: LinearGradient {
        let palette: [(Color, Color)] = [
            (Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.25, green: 0.18, blue: 0.62)),
            (Color(red: 0.0, green: 0.62, blue: 0.86), Color(red: 0.0, green: 0.3, blue: 0.55)),
            (Color(red: 0.95, green: 0.45, blue: 0.4), Color(red: 0.6, green: 0.16, blue: 0.3)),
            (Color(red: 0.2, green: 0.75, blue: 0.55), Color(red: 0.05, green: 0.38, blue: 0.35)),
            (Color(red: 0.96, green: 0.68, blue: 0.2), Color(red: 0.7, green: 0.32, blue: 0.1))
        ]
        let seed = user.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let pair = palette[seed % palette.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Sign in

struct PasswordView: View {
    let server: ServerTarget
    let user: UserDto
    @Binding var path: [OnboardingRoute]
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 40) {
            Avatar(user: user, server: server.url, size: 220)
            Text("Hallo \(user.name)").font(.system(size: 56, weight: .bold))
            VStack(spacing: 24) {
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .focused($fieldFocused)
                    .onSubmit(signIn)
                Button(action: signIn) {
                    HStack {
                        Text(busy ? "Anmelden …" : "Anmelden")
                        Spacer()
                        if busy { ProgressView() } else { Image(systemName: "arrow.right") }
                    }
                }
                .disabled(busy)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .frame(width: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { fieldFocused = true }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.anonymousClient(server.url).authenticate(username: user.name, password: password)
                model.signIn(server: server.url, info: server.info, result: result, password: password)
            } catch {
                password = ""
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ManualLoginView: View {
    let server: ServerTarget
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        OnboardingLayout(title: String(localized: "Anmelden"),
                         subtitle: String(localized: "Melde dich bei \(server.name) an. Tipp: Mit der iPhone-Tastatur kannst du gespeicherte Passwörter einsetzen.")) {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Benutzername", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)
                Button(action: signIn) {
                    HStack {
                        Text(busy ? "Anmelden …" : "Anmelden")
                        Spacer()
                        if busy { ProgressView() } else { Image(systemName: "arrow.right") }
                    }
                }
                .disabled(busy || username.isEmpty)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .frame(maxWidth: 820)
        }
    }

    private func signIn() {
        guard !busy, !username.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.anonymousClient(server.url).authenticate(username: username, password: password)
                model.signIn(server: server.url, info: server.info, result: result, password: password)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct QuickConnectView: View {
    let server: ServerTarget
    @EnvironmentObject private var model: AppModel
    @State private var code: String?
    @State private var error: String?

    var body: some View {
        OnboardingLayout(title: String(localized: "Mit Code anmelden"),
                         subtitle: String(localized: "Öffne Jellyfin auf deinem Handy oder Computer, tippe auf dein Profil › Quick Connect und gib diesen Code ein.")) {
            VStack(spacing: 44) {
                if let code {
                    HStack(spacing: 18) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                            Text(String(digit))
                                .font(.system(size: 92, weight: .bold, design: .rounded)).monospacedDigit()
                                .frame(width: 112, height: 150)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 2))
                        }
                    }
                    HStack(spacing: 18) {
                        ProgressView()
                        Text("Warte auf Bestätigung …").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Erneut versuchen") { self.error = nil }
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: error == nil) {
            guard error == nil else { return }
            await run()
        }
    }

    private func run() async {
        let client = model.anonymousClient(server.url)
        do {
            var state = try await client.quickConnectInitiate()
            code = state.code
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                state = try await client.quickConnectState(secret: state.secret)
                if state.authenticated == true {
                    let result = try await client.authenticate(quickConnectSecret: state.secret)
                    model.signIn(server: server.url, info: server.info, result: result)
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            code = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Der Code ist abgelaufen. Bitte erneut versuchen.")
        }
    }
}
