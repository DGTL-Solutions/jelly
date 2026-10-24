import SwiftUI

// "Erkunden" on iPhone and iPad: films and series that aren't on the server yet, via Jellyseerr – a search, what's
// being downloaded, the viewer's own wishes and what's trending, popular and coming, each a tap away from a wish.
// Same behaviour and wording as the Apple TV version (Jelly/Views/DiscoverView.swift), with a touch layout.

/// One title on the Discover stack; `source` names the poster it was opened from, for the zoom transition.
private struct SeerrRoute: Hashable {
    let title: SeerrClient.Title
    let source: String
}

// MARK: - Discover tab

/// The Discover tab with its own navigation stack: the invitation to connect Jellyseerr, or its rows and search.
struct DiscoverScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [SeerrRoute] = []
    @State private var connecting = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let account = model.seerr {
                    SeerrHome(account: account, zoom: zoom) { path.append($0) }
                } else {
                    SeerrInvitation(connecting: $connecting)
                }
            }
            .navigationTitle("Erkunden")
            .navigationDestination(for: SeerrRoute.self) { route in
                SeerrDetailScreen(title: route.title)
                    .navigationTransition(.zoom(sourceID: route.source, in: zoom))
            }
        }
        .sheet(isPresented: $connecting) { SeerrConnectSheet() }
        // An expired or ended Jellyseerr session leaves no detail pages of it behind.
        .onChange(of: model.seerr == nil) { _, signedOut in if signedOut { path = [] } }
        #if DEBUG
        .task { if SeerrDebug.take("JELLY_SEERR_RESET") != nil { await model.disconnectSeerr() } }
        #endif
    }
}

#if DEBUG
/// Simulator testing only, read from the launch environment (JELLY_TAB=discover opens this tab, see MainTabs): JELLY_SEERR_RESET
/// signs out of Jellyseerr, JELLY_SEERR_OPEN=<TMDB id> opens a title from the rows, JELLY_SEERR_SEARCH=<text> searches,
/// JELLY_SEERR_SEASONS opens the season choice of the opened series. Each is used once per launch.
private enum SeerrDebug {
    private static var used: Set<String> = []

    static func take(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], used.insert(key).inserted else { return nil }
        return value
    }

}
#endif

// MARK: - Not connected

private struct SeerrInvitation: View {
    @Binding var connecting: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var found: URL?

    #if DEBUG
    /// Simulator testing only: the connect sheet opens by itself once per launch when JELLY_SEERR_SERVER is set.
    private static var presentedForDebug = false
    #endif

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        Circle().fill(Theme.brand).frame(width: 150, height: 150).blur(radius: 50).opacity(0.45)
                        Image(systemName: "sparkles")
                            .font(.system(size: sizeClass == .regular ? 84 : 68, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                    .accessibilityHidden(true)
                    Text("Verbinde deinen Jellyseerr-Server")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Mit Jellyseerr wünschst du dir Filme und Serien, die noch nicht auf deinem Server sind. Hier siehst du, was gerade angesagt ist und bald erscheint – ein Tippen auf „Wünschen“ genügt, und sobald der Titel geladen ist, steht er in deiner Bibliothek.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                    Button { connecting = true } label: {
                        Label("Jellyseerr verbinden", systemImage: "link").frame(maxWidth: 300)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                    if let found {
                        Text("Gefunden: \(found.host(percentEncoded: false) ?? found.absoluteString)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["JELLY_SEERR_SERVER"] != nil {
                if !Self.presentedForDebug { Self.presentedForDebug = true; connecting = true }
                return
            }
            #endif
            let last = model.lastSeerrServer
            let nearby = last == nil ? await SeerrClient.find(near: [model.homeAddress, model.session?.server].compactMap { $0 })?.0 : nil
            withAnimation { found = last ?? nearby }
        }
    }
}

// MARK: - Connecting

/// Address (found automatically where possible) and sign-in, by default with the Jellyfin account. Presented as a sheet
/// from the Discover tab and from the settings.
struct SeerrConnectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    /// The address the status line speaks about; `nil` while it hasn't been checked.
    @State private var checkedAddress: String?
    @State private var version: String?
    @State private var settings: SeerrClient.PublicSettings?
    @State private var searching = true
    /// Counts address checks; only the latest one may update the status line.
    @State private var checks = 0
    @State private var started = false
    @State private var local = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var failures = 0
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(Theme.brand)
                            .accessibilityHidden(true)
                        Text("Jelly meldet sich einmal an und merkt sich die Sitzung für dieses Profil. Dein Passwort wird nicht gespeichert.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Adresse, z. B. jellyseerr.example.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit {
                            focus = username.isEmpty ? .username : .password
                            Task { await check() }
                        }
                    statusLine
                }

                Section {
                    TextField(local ? "E-Mail" : "Jellyfin-Benutzername", text: $username)
                        .textContentType(local ? .emailAddress : .username)
                        .keyboardType(local ? .emailAddress : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(connect)
                } header: {
                    Text(local ? "Mit deinem Jellyseerr-Konto" : "Mit deinem Jellyfin-Konto")
                } footer: {
                    if settings?.localLogin != false, settings?.mediaServerLogin != false {
                        Button {
                            withAnimation {
                                local.toggle()
                                username = local ? "" : model.session?.name ?? ""
                            }
                            focus = .username
                        } label: {
                            Text(local ? "Stattdessen mit dem Jellyfin-Konto anmelden" : "Stattdessen mit einem Jellyseerr-Konto (E-Mail) anmelden")
                                .font(.footnote.weight(.medium))
                        }
                        .padding(.top, 4)
                    }
                }

                if let error {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.subheadline)
                    }
                    .transition(.opacity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Jellyseerr verbinden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Verbinden", action: connect)
                            .fontWeight(.semibold)
                            .disabled(address.isEmpty || username.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(busy)
            .sensoryFeedback(.error, trigger: failures)
        }
        .task { await start() }
        .task(id: address) {
            // Typing a new address: check it once the viewer pauses.
            guard started, address != checkedAddress else { return }
            checks += 1
            searching = false
            version = nil
            guard !address.isEmpty else { checkedAddress = nil; return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await check()
        }
    }

    /// Whether the address answers, as a quiet row under it while there is something to say.
    @ViewBuilder private var statusLine: some View {
        Group {
            if searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche Jellyseerr …").foregroundStyle(.secondary)
                }
            } else if let version, address == checkedAddress {
                Label("Jellyseerr \(version) erreichbar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if !address.isEmpty, address == checkedAddress {
                Label("Unter dieser Adresse antwortet kein Jellyseerr", systemImage: "questionmark.circle").foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .transition(.opacity)
    }

    private func start() async {
        guard !started else { return }
        username = model.session?.name ?? ""
        #if DEBUG
        // Simulator testing only: JELLY_SEERR_SERVER (with JELLY_SEERR_PASSWORD) connects a local mock right away.
        let debugServer = ProcessInfo.processInfo.environment["JELLY_SEERR_SERVER"]
        #else
        let debugServer: String? = nil
        #endif
        if let debugServer {
            address = debugServer
        } else if let last = model.lastSeerrServer {
            address = last.absoluteString
        } else if let (url, _) = await SeerrClient.find(near: [model.homeAddress, model.session?.server].compactMap { $0 }) {
            address = url.absoluteString
        }
        await check()
        started = true
        focus = address.isEmpty ? .address : .password
        #if DEBUG
        if let password = ProcessInfo.processInfo.environment["JELLY_SEERR_PASSWORD"] {
            self.password = password
            connect()
        }
        #endif
    }

    /// The first form of the address that answers like Jellyseerr, its version and which sign-in methods it allows.
    private func resolve(_ text: String) async -> (url: URL, version: String, settings: SeerrClient.PublicSettings?)? {
        for url in SeerrClient.address(from: text) {
            if let status = try? await SeerrClient(server: url).status(timeout: 4) {
                return (url, status.version, try? await SeerrClient(server: url).publicSettings())
            }
        }
        return nil
    }

    private func check() async {
        checks += 1
        let token = checks
        let text = address
        guard !text.isEmpty else { searching = false; version = nil; checkedAddress = nil; return }
        searching = true
        let found = await resolve(text)
        // The viewer typed on meanwhile: the newer address gets its own check.
        guard token == checks else { return }
        searching = false
        guard let found else { version = nil; checkedAddress = address; return }
        withAnimation {
            version = found.version
            settings = found.settings
            if address == text { address = found.url.absoluteString }
            checkedAddress = address
            // Servers without Jellyfin sign-in only take Jellyseerr's own accounts.
            if found.settings?.mediaServerLogin == false, !local { local = true; username = "" }
        }
    }

    private func connect() {
        guard !busy, !address.isEmpty, !username.isEmpty else { return }
        busy = true
        withAnimation { error = nil }
        Task {
            defer { busy = false }
            do {
                guard let found = await resolve(address) else { throw SeerrError.unreachable }
                version = found.version
                settings = found.settings
                let (user, cookie) = try await SeerrClient(server: found.url).signIn(username: username, password: password, local: local)
                Diagnostics.log("jellyseerr connected \(found.url.host() ?? "") as \(user.name)")
                model.connectSeerr(SeerrAccount(server: found.url, cookie: cookie, userID: user.id, name: user.name))
                dismiss()
            } catch {
                password = ""
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case SeerrError.jellyfinRefused = error, let limit = model.user?.policy?.maxActiveSessions, limit > 0 {
                    text += " " + (limit == 1
                        ? String(localized: "Dein Konto erlaubt 1 gleichzeitige Anmeldung; Jelly auf diesem Gerät ist eine davon.")
                        : String(localized: "Dein Konto erlaubt \(limit) gleichzeitige Anmeldungen; Jelly auf diesem Gerät ist eine davon."))
                }
                withAnimation { self.error = text }
                failures += 1
                focus = .password
            }
        }
    }
}

// MARK: - Connected

private struct SeerrHome: View {
    let account: SeerrAccount
    let zoom: Namespace.ID
    /// Opens a title on the Discover stack.
    let open: (SeerrRoute) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var shelves: [SeerrClient.Shelf: [SeerrClient.Title]] = [:]
    @State private var loading: [SeerrClient.Title] = []
    @State private var wishes: [SeerrClient.Title] = []
    @State private var loaded = false
    @State private var loadedFor: UUID?
    @State private var loadedAt = Date.distantPast
    @State private var error: String?
    @State private var query = ""

    /// Jellyseerr asks Radarr and Sonarr for their queues once a minute; looking twice as often keeps the bars current.
    private static let followInterval: Duration = .seconds(30)

    private var cardWidth: CGFloat { sizeClass == .regular ? 160 : 124 }
    /// Whether anything on the page is on its way – then the page follows the downloads.
    private var following: Bool { (loading + wishes).contains { $0.mediaInfo?.isLoading == true } }

    var body: some View {
        Group {
            if query.isEmpty {
                ScrollView { home }
                    .refreshable { await load() }
            } else {
                SeerrSearchResults(term: query.trimmingCharacters(in: .whitespaces), zoom: zoom)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background.ignoresSafeArea())
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Filme und Serien"))
        .task(id: model.refreshID) {
            // Coming back from a title reloads only when something changed or the rows have grown old.
            if loaded, loadedFor == model.refreshID, Date.now.timeIntervalSince(loadedAt) < 120 { return }
            await load()
            #if DEBUG
            if let text = SeerrDebug.take("JELLY_SEERR_SEARCH") { query = text }
            if let id = SeerrDebug.take("JELLY_SEERR_OPEN").flatMap(Int.init),
               let title = (loading + wishes + SeerrClient.Shelf.allCases.flatMap { shelves[$0] ?? [] }).first(where: { $0.tmdbID == id }) {
                open(SeerrRoute(title: title, source: "debug"))
            }
            #endif
        }
        .task(id: following) {
            if following { await follow() }
        }
    }

    private var home: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            Text("Über Jellyseerr · \(account.name)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if !loaded {
                if let error {
                    MobileErrorView(message: error) { Task { await load() } }.padding(.top, 40)
                } else {
                    MobileLoadingView(text: String(localized: "Jellyseerr wird geladen …")).frame(height: 360)
                }
            }
            if !loading.isEmpty {
                shelf(String(localized: "Wird geladen", comment: "Jellyseerr: requested title is being downloaded"), key: "loading", loading)
            }
            if !wishes.isEmpty {
                shelf(String(localized: "Deine Wünsche"), key: "wishes", wishes)
            }
            ForEach(SeerrClient.Shelf.allCases) { kind in
                if let items = shelves[kind], !items.isEmpty {
                    shelf(kind.title, key: kind.rawValue, items)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 28)
    }

    private func shelf(_ name: String, key: String, _ titles: [SeerrClient.Title]) -> some View {
        ShelfSection(title: name, items: titles, spacing: sizeClass == .regular ? 16 : 12) { title in
            SeerrPosterCard(title: title, width: cardWidth, source: "\(key)-\(title.id)", zoom: zoom)
        }
    }

    private func load() async {
        let client = account.client
        loadedFor = model.refreshID
        do {
            // One request first: an expired session shows up here instead of as many empty rows.
            let trending = try await client.discover(.trending)
            let rest = await withTaskGroup(of: (SeerrClient.Shelf, [SeerrClient.Title]).self) { group in
                for shelf in SeerrClient.Shelf.allCases where shelf != .trending {
                    group.addTask { (shelf, (try? await client.discover(shelf)) ?? []) }
                }
                var rows: [SeerrClient.Shelf: [SeerrClient.Title]] = [.trending: trending]
                for await (shelf, items) in group { rows[shelf] = items }
                return rows
            }
            async let approved = try? client.approvedRequests()
            async let mine = try? client.myRequests(userID: account.userID)
            let loadingTitles = await titles(for: Self.loading(await approved ?? []), client: client)
            let wishedTitles = await titles(for: Array((await mine ?? []).prefix(12)), client: client)
            withAnimation(.easeOut(duration: 0.35)) {
                shelves = rest
                loading = loadingTitles
                wishes = wishedTitles
                loaded = true
                loadedAt = .now
                error = nil
            }
        } catch SeerrError.signedOut {
            Diagnostics.log("jellyseerr session expired")
            await model.disconnectSeerr(expired: true)
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// Approved wishes still on their way, running downloads first.
    private static func loading(_ requests: [SeerrClient.Request]) -> [SeerrClient.Request] {
        let open = requests.filter { $0.media?.info.isLoading == true }
        return Array((open.filter { $0.media?.info.download != nil } + open.filter { $0.media?.info.download == nil }).prefix(12))
    }

    /// Posters and names for requests, in their order; titles already on screen are reused with the request's fresh state.
    private func titles(for requests: [SeerrClient.Request], client: SeerrClient) async -> [SeerrClient.Title] {
        var known: [String: SeerrClient.Title] = [:]
        for title in loading + wishes { known[title.id] = title }
        let titles = await withTaskGroup(of: (Int, SeerrClient.Title?).self) { group in
            for (index, request) in requests.enumerated() {
                if let media = request.media, let title = known[media.key] {
                    var current = title
                    current.mediaInfo = media.info
                    group.addTask { [current] in (index, current) }
                } else {
                    group.addTask { (index, try? await client.title(for: request)) }
                }
            }
            var titles: [(Int, SeerrClient.Title)] = []
            for await (index, title) in group { if let title { titles.append((index, title)) } }
            return titles.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return titles.uniqued()
    }

    /// While something is being downloaded, keeps the bars, the time left and the "Wird geladen" row current – and
    /// the badges of the same titles in the other rows. Ends when the page is left or nothing is on its way any more.
    private func follow() async {
        let client = account.client
        while !Task.isCancelled, following {
            try? await Task.sleep(for: Self.followInterval)
            guard !Task.isCancelled, let approved = try? await client.approvedRequests() else { continue }
            let mine = (try? await client.myRequests(userID: account.userID)) ?? []
            var fresh: [String: SeerrClient.MediaInfo] = [:]
            for request in mine + approved { if let media = request.media { fresh[media.key] = media.info } }
            func update(_ titles: [SeerrClient.Title]) -> [SeerrClient.Title] {
                titles.map { title in
                    var title = title
                    if let info = fresh[title.id] { title.mediaInfo = info }
                    return title
                }
            }
            let loadingTitles = await titles(for: Self.loading(approved), client: client)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                loading = loadingTitles
                wishes = update(wishes)
                shelves = shelves.mapValues(update)
            }
        }
    }
}

// MARK: - Search

private struct SeerrSearchResults: View {
    let term: String
    let zoom: Namespace.ID
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var results: [SeerrClient.Title] = []
    @State private var searched: String?
    @State private var searching = false
    @State private var error: String?

    private var columns: [GridItem] {
        let minimum: CGFloat = sizeClass == .regular ? 150 : 104
        return [GridItem(.adaptive(minimum: minimum), spacing: sizeClass == .regular ? 18 : 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(results) { title in
                    SeerrPosterCard(title: title, width: nil, source: "search-\(title.id)", zoom: zoom)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .overlay { state }
        .task(id: term) { await search() }
    }

    @ViewBuilder private var state: some View {
        if term.count < 2 {
            ContentUnavailableView("Neues finden", systemImage: "sparkles",
                                   description: Text("Suche nach Filmen und Serien, die du dir über Jellyseerr wünschen möchtest."))
        } else if let error {
            ContentUnavailableView("Suche fehlgeschlagen", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if results.isEmpty {
            if searching || searched != term {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: term)
            }
        }
    }

    private func search() async {
        guard term.count >= 2, let account = model.seerr else {
            results = []
            error = nil
            return
        }
        searching = true
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        error = nil
        do {
            let found = try await account.client.search(term)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                results = found
                searched = term
                error = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        searching = false
    }
}

// MARK: - Cards

/// Poster with the title's state in Jellyseerr: in the library, wished for, being downloaded – with how far.
private struct SeerrPosterCard: View {
    let title: SeerrClient.Title
    /// A fixed width in rows; `nil` fills a grid cell.
    let width: CGFloat?
    let source: String
    let zoom: Namespace.ID
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let download = title.download
        NavigationLink(value: SeerrRoute(title: title, source: source)) {
            VStack(alignment: .leading, spacing: 6) {
                Theme.placeholder
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: width)
                    .overlay {
                        Image(systemName: title.isSeries ? "tv" : "film")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .overlay { RemoteImage(url: title.poster) }
                    .overlay(alignment: .bottom) {
                        if let download {
                            ZStack(alignment: .bottom) {
                                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 44)
                                SeerrDownloadBar(progress: download)
                                    .frame(height: 5)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 8)
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if title.status != .none {
                            SeerrStatusBadge(status: title.status, size: sizeClass == .regular ? 30 : 26).padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .hoverEffect(.lift)
                    .matchedTransitionSource(id: source, in: zoom)

                Text(title.displayTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Group {
                    if let download {
                        Text(download.cardText)
                            .foregroundStyle(download.phase == .stalled ? .orange : .secondary)
                            .monospacedDigit()
                    } else if title.status == .processing {
                        Text("Wartet auf Download").foregroundStyle(.secondary)
                    } else {
                        Text(title.kindLine).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct SeerrStatusBadge: View {
    let status: SeerrStatus
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(status.seerrTint, in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .accessibilityLabel(status.label ?? "")
    }
}

/// How much of a download is there, in the colour of its state.
private struct SeerrDownloadBar: View {
    let fraction: Double
    let phase: DownloadProgress.Phase

    init(progress: DownloadProgress) { self.init(fraction: progress.fraction, phase: progress.phase) }
    init(fraction: Double, phase: DownloadProgress.Phase) { self.fraction = fraction; self.phase = phase }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                if fraction > 0 {
                    Capsule().fill(phase.seerrTint).frame(width: max(proxy.size.height, proxy.size.width * fraction))
                }
            }
        }
        .animation(.easeOut(duration: 0.6), value: fraction)
        .accessibilityHidden(true)
    }
}

private extension SeerrStatus {
    var seerrTint: Color {
        switch self {
        case .available: Color(red: 0.2, green: 0.7, blue: 0.4)
        case .partial: Color(red: 0.1, green: 0.6, blue: 0.65)
        case .processing: Color(red: 0.25, green: 0.45, blue: 0.95)
        case .pending: Color(red: 0.95, green: 0.6, blue: 0.15)
        case .none: Theme.accent
        }
    }
}

private extension DownloadProgress.Phase {
    var seerrSymbol: String {
        switch self {
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .importing: "tray.and.arrow.down"
        case .stalled: "exclamationmark.triangle"
        }
    }

    var seerrTint: Color {
        switch self {
        case .downloading: Color(red: 0.35, green: 0.55, blue: 1)
        case .importing: Color(red: 0.2, green: 0.7, blue: 0.4)
        case .queued: .white.opacity(0.55)
        case .paused, .stalled: Color(red: 0.95, green: 0.6, blue: 0.15)
        }
    }
}

private extension SeerrClient.Title {
    /// "2024 · Film"
    var kindLine: String {
        let kind = isSeries ? String(localized: "Serie", comment: "TV series") : String(localized: "Film", comment: "Movie")
        return [year, kind].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Detail

private struct SeerrDetailScreen: View {
    let title: SeerrClient.Title
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var details: SeerrClient.Details?
    @State private var status: SeerrStatus = .none
    @State private var busy = false
    @State private var opening = false
    @State private var notice: Notice?
    @State private var choosingSeasons = false
    @State private var showsBarTitle = false
    @State private var requested = 0

    struct Notice: Equatable {
        enum Kind { case success, info, problem }
        var text: String
        var kind: Kind
    }

    private var regular: Bool { sizeClass == .regular }
    private var backdropHeight: CGFloat { regular ? 460 : 300 }
    private var posterWidth: CGFloat { regular ? 180 : 112 }
    private var info: SeerrClient.MediaInfo? { details?.mediaInfo ?? title.mediaInfo }
    private var download: DownloadProgress? { info?.download }
    private var isLoading: Bool { status == .processing || download != nil }
    /// Whether a series still has seasons that are neither there nor wished for; assumed until the details are in.
    private var hasMissingSeasons: Bool {
        guard let details else { return true }
        return (details.seasons ?? []).contains { season in
            season.seasonNumber > 0
                && SeerrStatus(details.mediaInfo?.seasons?.first { $0.seasonNumber == season.seasonNumber }?.status) == .none
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    actions
                    if let notice { NoticeView(notice: notice).transition(.opacity.combined(with: .move(edge: .top))) }
                    if let download { SeerrDownloadPanel(progress: download, isSeries: title.isSeries) }
                    if let tagline = details?.tagline?.nonEmpty {
                        Text(tagline).font(.callout.italic()).foregroundStyle(.secondary)
                    }
                    if let overview = (details?.overview ?? title.overview)?.nonEmpty {
                        Text(overview).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: regular ? 760 : .infinity, alignment: .leading)
                .padding(.horizontal, regular ? 28 : 16)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background.ignoresSafeArea())
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > backdropHeight - 90
        } action: { _, past in
            withAnimation(.easeOut(duration: 0.2)) { showsBarTitle = past }
        }
        .navigationTitle(showsBarTitle ? title.displayTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(showsBarTitle ? .visible : .hidden, for: .navigationBar)
        .sensoryFeedback(.success, trigger: requested)
        .task {
            if details == nil { status = title.status }
            await reload()
            #if DEBUG
            if title.isSeries, details != nil, SeerrDebug.take("JELLY_SEERR_SEASONS") != nil { choosingSeasons = true }
            #endif
        }
        .task(id: isLoading) {
            // Follow the download while the page is open, as often as Jellyseerr learns something new.
            while isLoading, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .sheet(isPresented: $choosingSeasons) {
            if let details {
                SeerrSeasonSheet(details: details) { seasons in
                    choosingSeasons = false
                    Task { await request(seasons: seasons) }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            StretchyBackdrop(url: title.backdrop ?? title.poster, height: backdropHeight)
            HStack(alignment: .bottom, spacing: regular ? 26 : 16) {
                Theme.placeholder
                    .overlay {
                        Image(systemName: title.isSeries ? "tv" : "film")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .overlay { RemoteImage(url: title.poster) }
                    .frame(width: posterWidth, height: posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.displayTitle)
                        .font(regular ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    Text(metadata)
                        .font(regular ? .callout : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.bottom, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, regular ? 28 : 16)
            .padding(.top, -posterWidth * 0.8)
        }
    }

    private var metadata: String {
        var parts = [title.year, title.isSeries ? String(localized: "Serie", comment: "TV series") : String(localized: "Film", comment: "Movie")]
            .compactMap { $0 }
        if let runtime = details?.runtime, runtime > 0 { parts.append(Format.duration(Double(runtime) * 60)) }
        if let seasons = details?.numberOfSeasons {
            parts.append(seasons == 1 ? String(localized: "1 Staffel") : String(localized: "\(seasons) Staffeln"))
        }
        if let genres = details?.genres?.prefix(3).map(\.name), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if let vote = details?.voteAverage ?? title.voteAverage, vote > 0 {
            parts.append("TMDB " + vote.formatted(.number.precision(.fractionLength(1))))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        // Whatever part is already on the server can be watched, also while more is wished for.
        let canWatch = status == .available || status == .partial || info?.jellyfinMediaId != nil
        let canRequest = status == .none || (status == .partial && title.isSeries && hasMissingSeasons)
        let stateLabel = status != .available && (status != .partial || !title.isSeries) ? status.label : nil
        let count = [canWatch, canRequest, stateLabel != nil].filter { $0 }.count
        let layout = !regular && count > 1 ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        let fill: CGFloat? = regular ? nil : .infinity

        layout {
            if canWatch {
                Button { Task { await openInLibrary() } } label: {
                    HStack(spacing: 8) {
                        if opening { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                        Text("Ansehen")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: fill)
                    .padding(.horizontal, regular ? 12 : 0)
                }
                .buttonStyle(.borderedProminent)
                .disabled(opening)
            }
            if canRequest {
                let button = Button {
                    if title.isSeries { choosingSeasons = details != nil } else { Task { await request(seasons: nil) } }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView() } else { Image(systemName: "plus") }
                        Text(busy ? "Wird gewünscht …" : status == .partial ? "Fehlende Staffeln wünschen" : "Wünschen")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: fill)
                    .padding(.horizontal, regular ? 12 : 0)
                }
                .disabled(busy || (title.isSeries && details == nil))
                if canWatch { button.buttonStyle(.bordered) } else { button.buttonStyle(.borderedProminent) }
            }
            if let stateLabel {
                Label(stateLabel, systemImage: status.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status.seerrTint)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: fill, minHeight: 50)
                    .background(status.seerrTint.opacity(0.16), in: Capsule())
                    .transition(.opacity)
            }
        }
        .controlSize(.large)
        .animation(.easeOut(duration: 0.25), value: status)
    }

    private func reload() async {
        guard let account = model.seerr, let loaded = try? await account.client.details(title) else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            details = loaded
            status = SeerrStatus(loaded.mediaInfo?.status)
        }
    }

    private func request(seasons: [Int]?) async {
        guard let account = model.seerr, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await account.client.request(title, seasons: seasons)
            withAnimation(.easeOut(duration: 0.3)) {
                status = result == 2 ? .processing : .pending
                notice = result == 2
                    ? Notice(text: String(localized: "Freigegeben – sobald der Titel geladen ist, steht er in deiner Bibliothek."), kind: .success)
                    : Notice(text: String(localized: "Gewünscht – ein Admin muss den Wunsch noch freigeben. Danach erscheint er automatisch in deiner Bibliothek."), kind: .success)
            }
            requested += 1
            Diagnostics.log("jellyseerr request \(title.id) status=\(result)")
            model.contentChanged()
        } catch {
            withAnimation { notice = Notice(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .problem) }
        }
    }

    /// Jellyseerr knows the title's ID on its Jellyfin server; if that's the server Jelly is using, open it there.
    private func openInLibrary() async {
        opening = true
        defer { opening = false }
        guard let id = info?.jellyfinMediaId, let client = model.client, let session = model.session,
              let item = try? await client.item(user: session.userID, id: id) else {
            withAnimation {
                notice = Notice(text: String(localized: "Der Titel liegt auf dem Jellyfin-Server, mit dem Jellyseerr verbunden ist – in deiner aktuellen Bibliothek wurde er nicht gefunden."), kind: .info)
            }
            return
        }
        model.pendingOpen = item
    }
}

/// The backdrop at the top of a title's page; stretches when the page is pulled down.
private struct StretchyBackdrop: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let pull = max(0, proxy.frame(in: .scrollView).minY)
            ZStack {
                Theme.placeholder
                RemoteImage(url: url)
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.3)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0.35),
                                       .init(color: Theme.background.opacity(0.75), location: 0.75),
                                       .init(color: Theme.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: height + pull)
            .offset(y: -pull)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct NoticeView: View {
    let notice: SeerrDetailScreen.Notice

    var body: some View {
        Label {
            Text(notice.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            switch notice.kind {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The download of a wished title: how far, how long still, and for series the episodes on their way.
private struct SeerrDownloadPanel: View {
    let progress: DownloadProgress
    let isSeries: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let maxEpisodes = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    summary
                    Spacer(minLength: 12)
                    timesText
                }
                VStack(alignment: .leading, spacing: 4) {
                    summary
                    timesText
                }
            }
            SeerrDownloadBar(progress: progress).frame(height: 8)
            if isSeries, progress.parts.count > 1 {
                let shown = progress.parts.prefix(Self.maxEpisodes)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                        HStack(spacing: 10) {
                            Text(part.label ?? "–").monospacedDigit().frame(width: 62, alignment: .leading)
                            SeerrDownloadBar(fraction: part.fraction, phase: part.phase).frame(height: 5)
                            Text(part.phase == .queued
                                 ? String(localized: "wartet", comment: "Episode download is queued") : DownloadProgress.percent(part.fraction))
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                if progress.parts.count > Self.maxEpisodes {
                    Text("und \(progress.parts.count - Self.maxEpisodes) weitere Folgen").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summary: some View {
        Label(progress.summary, systemImage: progress.phase.seerrSymbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(progress.phase == .stalled ? .orange : .primary)
            .monospacedDigit()
    }

    private var timesText: some View {
        Text(times).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }

    /// "noch 12 Min. · fertig gegen 21:40", or just the time left when the end is not today or tomorrow.
    private var times: String {
        guard let left = progress.remainingText, let remaining = progress.remaining else { return progress.percent }
        let end = Date().addingTimeInterval(remaining)
        let calendar = Calendar.current
        let time = end.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(end) { return String(localized: "\(left) · fertig gegen \(time)", comment: "Time left · done at <time>") }
        if calendar.isDateInTomorrow(end) {
            return String(localized: "\(left) · fertig morgen gegen \(time)", comment: "Time left · done tomorrow at <time>")
        }
        return left
    }
}

/// Which seasons to wish for; seasons already there or wished for are shown with their state and can't be chosen.
private struct SeerrSeasonSheet: View {
    let details: SeerrClient.Details
    let onRequest: ([Int]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []

    private var seasons: [SeerrClient.Details.Season] { (details.seasons ?? []).filter { $0.seasonNumber > 0 } }

    private func status(_ season: Int) -> SeerrStatus {
        SeerrStatus(details.mediaInfo?.seasons?.first { $0.seasonNumber == season }?.status)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(seasons) { season in
                    let state = status(season.seasonNumber)
                    let isSelected = selected.contains(season.seasonNumber)
                    Button {
                        if isSelected { selected.remove(season.seasonNumber) } else { selected.insert(season.seasonNumber) }
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(season.name ?? String(localized: "Staffel \(season.seasonNumber)"))
                                    .foregroundStyle(state == .none ? .primary : .secondary)
                                if let count = season.episodeCount {
                                    Text(String(localized: "\(count) Folgen")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let label = state.label {
                                HStack(spacing: 5) {
                                    Image(systemName: state.symbol)
                                    Text(label)
                                }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(state.seerrTint)
                            } else {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state != .none)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Welche Staffeln?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { onRequest(selected.sorted()) } label: {
                    Text(selected.isEmpty ? String(localized: "Wünschen")
                         : selected.count == 1 ? String(localized: "1 Staffel wünschen") : String(localized: "\(selected.count) Staffeln wünschen"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .sensoryFeedback(.selection, trigger: selected)
        }
        .presentationDetents([.medium, .large])
        .onAppear { selected = Set(seasons.map(\.seasonNumber).filter { status($0) == .none }) }
    }
}
