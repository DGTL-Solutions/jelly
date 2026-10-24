import SwiftUI

/// A Jellyfin server the onboarding talks to, with what its public info said about it.
struct OnboardingServer: Hashable {
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

enum OnboardingStep: Hashable {
    case users(OnboardingServer)
    case password(OnboardingServer, UserDto)
    case manualLogin(OnboardingServer)
    case quickConnect(OnboardingServer)
}

/// First launch and "Server hinzufügen" / "Profil hinzufügen": server, profile, sign-in.
struct OnboardingFlow: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [OnboardingStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen(path: $path)
                .navigationDestination(for: OnboardingStep.self) { step in
                    Group {
                        switch step {
                        case .users(let server): ProfileChoiceScreen(server: server, path: $path)
                        case .password(let server, let user): PasswordScreen(server: server, user: user)
                        case .manualLogin(let server): ManualLoginScreen(server: server)
                        case .quickConnect(let server): QuickConnectScreen(server: server)
                        }
                    }
                    .toolbar { cancelButton }
                }
                .toolbar { cancelButton }
        }
        .onAppear {
            if let server = model.preselectedServer {
                path = [.users(OnboardingServer(url: server.url, id: server.id, name: server.name, version: server.version))]
            }
        }
        #if DEBUG
        .task { await openDebugStep() }
        #endif
    }

    #if DEBUG
    /// Simulator testing only: JELLY_ONBOARDING=<address>[,users|login|password|quickconnect] opens that step.
    private func openDebugStep() async {
        guard let value = ProcessInfo.processInfo.environment["JELLY_ONBOARDING"] else { return }
        let parts = value.split(separator: ",").map(String.init)
        guard let address = parts.first, let (url, info) = try? await ServerLocator.resolve(address) else { return }
        let server = OnboardingServer(url: url, info: info)
        switch parts.dropFirst().first {
        case "login": path = [.users(server), .manualLogin(server)]
        case "quickconnect": path = [.users(server), .quickConnect(server)]
        case "password":
            let user = try? await model.anonymousClient(url).publicUsers().first
            path = [.users(server)] + (user.map { [.password(server, $0)] } ?? [])
        default: path = [.users(server)]
        }
    }
    #endif

    /// Adding a server or profile can be abandoned from every step; the current profile stays.
    @ToolbarContentBuilder private var cancelButton: some ToolbarContent {
        if model.addingAccount && model.session != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Abbrechen") { model.cancelAddingProfile() }
            }
        }
    }
}

/// The layout of every onboarding step: centred column, Jelly's glow behind, scrolls when the keyboard needs room.
struct OnboardingPage<Top: View, Content: View>: View {
    let title: String
    var subtitle: String?
    /// Above the title: Jelly's mark on the first page, the profile picture before the password.
    @ViewBuilder let top: Top
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        top
                        Text(title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    content
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(AccountBackground())
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension OnboardingPage where Top == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, top: { EmptyView() }, content: content)
    }
}

// MARK: - Server

private struct WelcomeScreen: View {
    @Binding var path: [OnboardingStep]
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var discovery = ServerDiscovery()
    @State private var connecting: String?
    @State private var error: String?
    @State private var address = ""
    @State private var resolving = false
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    private var found: [DiscoveredServer] {
        discovery.servers.filter { server in !model.knownServers.contains { $0.id == server.id } }
    }

    var body: some View {
        OnboardingPage(title: model.addingAccount ? String(localized: "Server hinzufügen") : String(localized: "Willkommen bei Jelly"),
                       subtitle: model.addingAccount
                           ? String(localized: "Verbinde einen weiteren Jellyfin-Server. Deine bisherigen Anmeldungen bleiben erhalten; gewechselt wird in den Einstellungen.")
                           : String(localized: "Wähle deinen Jellyfin-Server. Server in deinem Netzwerk werden automatisch gefunden.")) {
            MobileAppMark(size: sizeClass == .regular ? 128 : 96).padding(.bottom, 10)
        } content: {
            VStack(spacing: 10) {
                ForEach(model.knownServers) { server in
                    serverRow(id: server.id, name: server.name, url: server.url,
                              detail: model.accounts.contains { $0.serverKey == server.id }
                                  ? String(localized: "Verbunden", comment: "Server status: signed in")
                                  : String(localized: "Zuletzt verwendet", comment: "Server status: used before"))
                        .contextMenu {
                            Button("Server entfernen", systemImage: "trash", role: .destructive) { withAnimation { model.forget(server) } }
                        }
                }
                ForEach(found) { server in
                    serverRow(id: server.id, name: server.name, url: server.url, detail: server.version.map { "Jellyfin \($0)" })
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                if discovery.isSearching {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Suche im Netzwerk …").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .transition(.opacity)
                } else if found.isEmpty && model.knownServers.isEmpty {
                    Text("Kein Server automatisch gefunden. Gib die Adresse einfach ein.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.vertical, 6)
                }
                if let error { AccountErrorText(message: error) }
            }
            .animation(.easeOut(duration: 0.25), value: discovery.servers)
            .animation(.easeOut(duration: 0.25), value: discovery.isSearching)

            addressEntry

            if !discovery.isSearching {
                Button { Task { await discovery.search() } } label: {
                    Label("Erneut suchen", systemImage: "arrow.clockwise")
                }
                .font(.callout)
                .disabled(connecting != nil)
            }
        }
        .task {
            #if DEBUG
            // Simulator testing only: JELLY_ONBOARDING_ADDRESS types an address and connects.
            if let typed = ProcessInfo.processInfo.environment["JELLY_ONBOARDING_ADDRESS"], address.isEmpty {
                address = typed
                resolve()
            }
            #endif
            await discovery.search()
        }
        .onChange(of: discovery.servers) { _, servers in servers.forEach(model.noteDiscovered) }
        .sensoryFeedback(.error, trigger: addressError) { _, new in new != nil }
    }

    private func serverRow(id: String, name: String, url: URL, detail: String?) -> some View {
        Button {
            Task { await connect(id: id, url: url) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text([AccountFormat.host(url), detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if connecting == id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(AccountPressStyle())
        .disabled(connecting != nil)
        .accessibilityHint(Text(AccountFormat.host(url)))
    }

    /// Typing the address right here: no extra step when nothing was found automatically.
    private var addressEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server-Adresse")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                TextField("z. B. 192.168.1.20 oder jellyfin.example.com", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(resolve)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(addressFocused ? Theme.accent.opacity(0.8) : .white.opacity(0.06), lineWidth: addressFocused ? 1.5 : 1))
            Text("Eine IP-Adresse oder Domain reicht – Protokoll und Port probiert Jelly automatisch aus.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            Button(action: resolve) {
                HStack(spacing: 8) {
                    if resolving { ProgressView().tint(.white) }
                    Text(resolving ? "Verbinde …" : "Verbinden")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(resolving || connecting != nil || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, 4)
            if let addressError { AccountErrorText(message: addressError) }
        }
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: addressError)
    }

    private func connect(id: String, url: URL) async {
        connecting = id
        error = nil
        defer { connecting = nil }
        do {
            let info = try await model.anonymousClient(url).publicInfo()
            path.append(.users(OnboardingServer(url: url, info: info)))
        } catch {
            let host = url.host() ?? String(localized: "Server", comment: "The Jellyfin server")
            withAnimation { self.error = String(localized: "\(host) ist gerade nicht erreichbar.", comment: "<server address> is currently unreachable") }
        }
    }

    private func resolve() {
        guard !resolving, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        resolving = true
        addressError = nil
        addressFocused = false
        Task {
            defer { resolving = false }
            do {
                let (url, info) = try await ServerLocator.resolve(address)
                path.append(.users(OnboardingServer(url: url, info: info)))
            } catch {
                addressError = (error as? LocalizedError)?.errorDescription ?? JellyError.serverNotFound.errorDescription
            }
        }
    }
}

// MARK: - Profiles

/// The server's profiles with their pictures; without public profiles, the sign-in form right away.
private struct ProfileChoiceScreen: View {
    let server: OnboardingServer
    @Binding var path: [OnboardingStep]
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var users: [UserDto] = []
    @State private var quickConnect = false
    @State private var loaded = false
    @State private var busyUser: String?
    @State private var error: String?

    private var avatarSize: CGFloat { sizeClass == .regular ? 96 : 88 }

    var body: some View {
        OnboardingPage(title: !loaded || !users.isEmpty ? String(localized: "Wer schaut gerade?") : String(localized: "Anmelden"),
                       subtitle: server.name) {
            if !loaded {
                ProgressView().controlSize(.large).frame(height: 180)
            } else if users.isEmpty {
                // Servers on the internet usually hide their profiles: name and password straight away.
                SignInForm(server: server)
            } else {
                AccountTileGrid(count: users.count, tileWidth: avatarSize + 16, maxColumns: sizeClass == .regular ? 4 : 3) {
                    ForEach(users) { user in
                        Button { select(user) } label: {
                            AccountProfileTile(user: user, server: server.url, size: avatarSize, busy: busyUser == user.id)
                        }
                        .buttonStyle(AccountPressStyle())
                        .disabled(busyUser != nil)
                    }
                }
                .transition(.opacity)
            }
            if loaded {
                VStack(spacing: 12) {
                    if quickConnect {
                        Button { path.append(.quickConnect(server)) } label: {
                            Label("Mit Code anmelden", systemImage: "rectangle.and.pencil.and.ellipsis").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    if !users.isEmpty {
                        Button { path.append(.manualLogin(server)) } label: {
                            Label("Anderer Benutzer", systemImage: "person.badge.key").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    if let error { AccountErrorText(message: error) }
                }
                .transition(.opacity)
            }
        }
        .task {
            guard !loaded else { return }
            let client = model.anonymousClient(server.url)
            async let users = try? client.publicUsers()
            async let quick = client.quickConnectEnabled()
            let (list, enabled) = await (users ?? [], quick)
            withAnimation(.easeOut(duration: 0.25)) {
                self.users = list
                quickConnect = enabled
                loaded = true
            }
        }
        .sensoryFeedback(.selection, trigger: busyUser) { _, new in new != nil }
    }

    private func select(_ user: UserDto) {
        guard user.needsPassword else {
            busyUser = user.id
            error = nil
            Task {
                defer { busyUser = nil }
                do {
                    let result = try await model.anonymousClient(server.url).authenticate(username: user.name, password: "")
                    model.signIn(server: server.url, info: server.info, result: result, password: "")
                } catch JellyError.loginRejected {
                    error = JellyError.loginRejected.errorDescription
                } catch {
                    path.append(.password(server, user))
                }
            }
            return
        }
        path.append(.password(server, user))
    }
}

// MARK: - Sign in

private struct PasswordScreen: View {
    let server: OnboardingServer
    let user: UserDto
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        OnboardingPage(title: String(localized: "Hallo \(user.name)"), subtitle: server.name) {
            AccountAvatar(user: user, server: server.url, size: 112)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .padding(.bottom, 6)
        } content: {
            VStack(spacing: 16) {
                AccountField {
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onSubmit(signIn)
                }
                SignInButton(busy: busy, action: signIn)
                if let error { AccountErrorText(message: error) }
            }
            .animation(.easeOut(duration: 0.2), value: error)
        }
        .onAppear { fieldFocused = true }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
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
                fieldFocused = true
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct ManualLoginScreen: View {
    let server: OnboardingServer

    var body: some View {
        OnboardingPage(title: String(localized: "Anmelden"), subtitle: server.name) {
            SignInForm(server: server, focusesName: true)
        }
    }
}

/// User name and password, with the system's password AutoFill.
private struct SignInForm: View {
    let server: OnboardingServer
    var focusesName = false
    @EnvironmentObject private var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, password }

    var body: some View {
        VStack(spacing: 12) {
            AccountField {
                TextField("Benutzername", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .password }
            }
            AccountField {
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(signIn)
            }
            SignInButton(busy: busy, action: signIn)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 4)
            if let error { AccountErrorText(message: error) }
        }
        .animation(.easeOut(duration: 0.2), value: error)
        .onAppear { if focusesName { focus = .name } }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
    }

    private func signIn() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !busy, !name.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.anonymousClient(server.url).authenticate(username: name, password: password)
                model.signIn(server: server.url, info: server.info, result: result, password: password)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct AccountField<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

private struct SignInButton: View {
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(busy ? "Anmelden …" : "Anmelden")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(busy)
    }
}

// MARK: - Quick Connect

private struct QuickConnectScreen: View {
    let server: OnboardingServer
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var code: String?
    @State private var error: String?

    var body: some View {
        OnboardingPage(title: String(localized: "Mit Code anmelden"),
                       subtitle: String(localized: "Öffne Jellyfin auf deinem Handy oder Computer, tippe auf dein Profil › Quick Connect und gib diesen Code ein.")) {
            VStack(spacing: 28) {
                if let code {
                    HStack(spacing: sizeClass == .regular ? 12 : 8) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                            Text(String(digit))
                                .font(.system(size: sizeClass == .regular ? 56 : 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: sizeClass == .regular ? 64 : 44, height: sizeClass == .regular ? 88 : 62)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                    .contextMenu {
                        Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Warte auf Bestätigung …").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                } else if let error {
                    AccountErrorText(message: error)
                    Button("Erneut versuchen") { self.error = nil }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    ProgressView().controlSize(.large).frame(height: 90)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: code)
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
