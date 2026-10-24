import SwiftUI

enum DiscoverRoute: Hashable {
    case connect
    case search
    case title(SeerrClient.Title)
}

/// "Erkunden": films and series that aren't on the server yet, via Jellyseerr – what's trending, popular and coming,
/// a search, and a wish with one click. Without a connected Jellyseerr only the invitation to connect one.
struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [DiscoverRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let account = model.seerr {
                    DiscoverHome(account: account, path: $path)
                } else {
                    ConnectSeerrPrompt(path: $path)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationDestination(for: DiscoverRoute.self) { route in
                switch route {
                case .connect: SeerrConnectView()
                case .search: SeerrSearchView(path: $path)
                case .title(let title): SeerrDetailView(title: title)
                }
            }
        }
    }
}

// MARK: - Not connected

private struct ConnectSeerrPrompt: View {
    @Binding var path: [DiscoverRoute]
    @EnvironmentObject private var model: AppModel
    @State private var found: URL?

    var body: some View {
        VStack(spacing: 34) {
            Image(systemName: "sparkles")
                .font(.system(size: 110, weight: .medium))
                .foregroundStyle(Theme.brand)
            Text("Verbinde deinen Jellyseerr-Server").font(.system(size: 54, weight: .bold))
            Text("Mit Jellyseerr wünschst du dir Filme und Serien, die noch nicht auf deinem Server sind. Hier siehst du, was gerade angesagt ist und bald erscheint – ein Klick auf „Wünschen“ genügt, und sobald der Titel geladen ist, steht er in deiner Bibliothek.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 1150)
            Button { path.append(.connect) } label: {
                Label("Jellyseerr verbinden", systemImage: "link").padding(.horizontal, 20)
            }
            .padding(.top, 10)
            Text(found.map { String(localized: "Gefunden: \($0.host(percentEncoded: false) ?? $0.absoluteString)") } ?? " ")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            #if DEBUG
            // Simulator testing only: JELLY_SEERR_SERVER (with JELLY_SEERR_PASSWORD) connects a local mock right away.
            if ProcessInfo.processInfo.environment["JELLY_SEERR_SERVER"] != nil { path.append(.connect); return }
            #endif
            found = model.lastSeerrServer
            if found == nil { found = await SeerrClient.find(near: [model.homeAddress, model.session?.server].compactMap { $0 })?.0 }
        }
    }
}

/// Address (found automatically where possible) and sign-in, by default with the Jellyfin account.
struct SeerrConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var version: String?
    @State private var settings: SeerrClient.PublicSettings?
    @State private var searching = true
    @State private var local = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        OnboardingLayout(title: String(localized: "Jellyseerr verbinden"),
                         subtitle: String(localized: "Jelly meldet sich einmal an und merkt sich die Sitzung für dieses Profil. Dein Passwort wird nicht gespeichert.")) {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Adresse, z. B. jellyseerr.example.com", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($focus, equals: .address)
                    .onSubmit { Task { await check() } }
                Group {
                    if searching {
                        Label { Text("Suche Jellyseerr …") } icon: { ProgressView() }
                    } else if let version {
                        Label("Jellyseerr \(version) erreichbar", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if !address.isEmpty {
                        Label("Unter dieser Adresse antwortet kein Jellyseerr", systemImage: "questionmark.circle").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .padding(.leading, 8)

                Text(local ? "Mit deinem Jellyseerr-Konto" : "Mit deinem Jellyfin-Konto")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.leading, 8)
                TextField(local ? "E-Mail" : "Jellyfin-Benutzername", text: $username)
                    .textContentType(local ? .emailAddress : .username)
                    .focused($focus, equals: .username)
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(connect)
                Button(action: connect) {
                    HStack {
                        Text(busy ? "Verbinden …" : "Verbinden")
                        Spacer()
                        if busy { ProgressView() } else { Image(systemName: "arrow.right") }
                    }
                }
                .disabled(busy || address.isEmpty || username.isEmpty)
                if settings?.localLogin != false, settings?.mediaServerLogin != false {
                    Button {
                        local.toggle()
                        username = local ? "" : model.session?.name ?? ""
                    } label: {
                        Text(local ? "Stattdessen mit dem Jellyfin-Konto anmelden" : "Stattdessen mit einem Jellyseerr-Konto (E-Mail) anmelden")
                            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .frame(maxWidth: 820)
        }
        .task {
            username = model.session?.name ?? ""
            #if DEBUG
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
            focus = address.isEmpty ? .address : .password
            #if DEBUG
            if let password = ProcessInfo.processInfo.environment["JELLY_SEERR_PASSWORD"] {
                self.password = password
                connect()
            }
            #endif
        }
    }

    /// The first form of the address that answers like Jellyseerr, plus which sign-in methods it allows.
    private func resolve() async -> URL? {
        for url in SeerrClient.address(from: address) {
            if let status = try? await SeerrClient(server: url).status(timeout: 4) {
                version = status.version
                settings = try? await SeerrClient(server: url).publicSettings()
                return url
            }
        }
        version = nil
        return nil
    }

    private func check() async {
        searching = true
        defer { searching = false }
        if let url = await resolve() {
            address = url.absoluteString
            // Servers without Jellyfin sign-in only take Jellyseerr's own accounts.
            if settings?.mediaServerLogin == false, !local { local = true; username = "" }
        }
    }

    private func connect() {
        guard !busy, !address.isEmpty, !username.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                guard let server = await resolve() else { throw SeerrError.unreachable }
                let (user, cookie) = try await SeerrClient(server: server).signIn(username: username, password: password, local: local)
                Diagnostics.log("jellyseerr connected \(server.host() ?? "") as \(user.name)")
                model.connectSeerr(SeerrAccount(server: server, cookie: cookie, userID: user.id, name: user.name))
                dismiss()
            } catch {
                password = ""
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case SeerrError.jellyfinRefused = error, let limit = model.user?.policy?.maxActiveSessions, limit > 0 {
                    text += " " + (limit == 1
                        ? String(localized: "Dein Konto erlaubt 1 gleichzeitige Anmeldung; Jelly auf diesem Apple TV ist eine davon.")
                        : String(localized: "Dein Konto erlaubt \(limit) gleichzeitige Anmeldungen; Jelly auf diesem Apple TV ist eine davon."))
                }
                self.error = text
            }
        }
    }
}

// MARK: - Connected

private struct DiscoverHome: View {
    let account: SeerrAccount
    @Binding var path: [DiscoverRoute]
    @EnvironmentObject private var model: AppModel
    @State private var shelves: [SeerrClient.Shelf: [SeerrClient.Title]] = [:]
    @State private var loading: [SeerrClient.Title] = []
    @State private var wishes: [SeerrClient.Title] = []
    @State private var loaded = false
    @State private var error: String?

    /// Jellyseerr asks Radarr and Sonarr for their queues once a minute; looking twice as often keeps the bars current.
    private static let followInterval: Duration = .seconds(30)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 56) {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(alignment: .firstTextBaseline, spacing: 30) {
                        Text("Erkunden").font(.title2.weight(.bold))
                        Text("Über Jellyseerr · \(account.name)").font(.callout).foregroundStyle(.secondary)
                    }
                    // The way in for anything not in the rows: first on the page, so the focus starts here.
                    Button { path.append(.search) } label: {
                        HStack(spacing: 22) {
                            Image(systemName: "magnifyingglass").font(.title3.weight(.semibold))
                            Text("Filme und Serien suchen und wünschen")
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .frame(width: 1000, height: 60, alignment: .leading)
                    }
                }
                .padding(.horizontal, Theme.edge)
                .focusSection()

                if !loaded {
                    if let error {
                        ErrorView(message: error) { Task { await load() } }
                    } else {
                        LoadingView(text: String(localized: "Jellyseerr wird geladen …")).frame(height: 500)
                    }
                }
                if !loading.isEmpty {
                    Shelf(title: String(localized: "Wird geladen", comment: "Jellyseerr: requested title is being downloaded"), items: loading) { title in
                        SeerrCard(title: title) { path.append(.title(title)) }
                    }
                }
                if !wishes.isEmpty {
                    Shelf(title: String(localized: "Deine Wünsche"), items: wishes) { title in
                        SeerrCard(title: title) { path.append(.title(title)) }
                    }
                }
                ForEach(SeerrClient.Shelf.allCases) { shelf in
                    if let items = shelves[shelf], !items.isEmpty {
                        Shelf(title: shelf.title, items: items) { title in
                            SeerrCard(title: title) { path.append(.title(title)) }
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task(id: model.refreshID) {
            await load()
            await follow()
        }
    }

    private func load() async {
        let client = account.client
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
                error = nil
            }
        } catch SeerrError.signedOut {
            Diagnostics.log("jellyseerr session expired")
            await model.disconnectSeerr(expired: true)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        while !Task.isCancelled, (loading + wishes).contains(where: { $0.mediaInfo?.isLoading == true }) {
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

/// Poster with the title's state in Jellyseerr: in the library, wished for, being downloaded – with how far.
struct SeerrCard: View {
    let title: SeerrClient.Title
    var width: CGFloat = 230
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let download = title.download
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    Theme.placeholder
                    RemoteImage(url: title.poster)
                    if title.status != .none { SeerrStatusBadge(status: title.status).padding(14) }
                }
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) {
                    if let download {
                        DownloadBar(progress: download).frame(height: 8).padding(.horizontal, 16).padding(.bottom, 14)
                    }
                }
            }
            .buttonStyle(.card)
            .focused($focused)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
                Group {
                    if let download {
                        Text(download.cardText).foregroundStyle(download.phase == .stalled ? .orange : .secondary)
                    } else if title.status == .processing {
                        Text("Wartet auf Download").foregroundStyle(.secondary)
                    } else {
                        let kind = title.isSeries ? String(localized: "Serie", comment: "TV series") : String(localized: "Film", comment: "Movie")
                        Text([title.year, kind].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.top, focused ? 26 : 14)
            .opacity(focused ? 1 : 0.85)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
        .frame(width: width, alignment: .leading)
    }
}

struct SeerrStatusBadge: View {
    let status: SeerrStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(color, in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }

    private var color: Color {
        switch status {
        case .available: Color(red: 0.2, green: 0.7, blue: 0.4)
        case .partial: Color(red: 0.1, green: 0.6, blue: 0.65)
        case .processing: Color(red: 0.25, green: 0.45, blue: 0.95)
        case .pending: Color(red: 0.95, green: 0.6, blue: 0.15)
        case .none: Theme.accent
        }
    }
}

/// How much of a download is there, in the colour of its state.
struct DownloadBar: View {
    let fraction: Double
    let phase: DownloadProgress.Phase

    init(progress: DownloadProgress) { self.init(fraction: progress.fraction, phase: progress.phase) }
    init(fraction: Double, phase: DownloadProgress.Phase) { self.fraction = fraction; self.phase = phase }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.5))
                if fraction > 0 { Capsule().fill(color).frame(width: max(proxy.size.height, proxy.size.width * fraction)) }
            }
        }
        .animation(.easeOut(duration: 0.6), value: fraction)
    }

    private var color: Color {
        switch phase {
        case .downloading: Color(red: 0.35, green: 0.55, blue: 1)
        case .importing: Color(red: 0.2, green: 0.7, blue: 0.4)
        case .queued: .white.opacity(0.55)
        case .paused, .stalled: Color(red: 0.95, green: 0.6, blue: 0.15)
        }
    }
}

extension DownloadProgress.Phase {
    var symbol: String {
        switch self {
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .importing: "tray.and.arrow.down"
        case .stalled: "exclamationmark.triangle"
        }
    }
}

// MARK: - Detail

struct SeerrDetailView: View {
    let title: SeerrClient.Title
    @EnvironmentObject private var model: AppModel
    @State private var details: SeerrClient.Details?
    @State private var status: SeerrStatus = .none
    @State private var busy = false
    @State private var message: String?
    @State private var choosingSeasons = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: title.backdrop ?? title.poster).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.95), .black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .leading, endPoint: .center).ignoresSafeArea()

            HStack(alignment: .bottom, spacing: 60) {
                RemoteImage(url: title.poster)
                    .frame(width: 300, height: 450)
                    .background(Theme.placeholder)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                VStack(alignment: .leading, spacing: 20) {
                    Text(title.displayTitle).font(.system(size: 64, weight: .bold)).lineLimit(2)
                    Text(metadata).font(.callout).foregroundStyle(.secondary)
                    if let tagline = details?.tagline?.nonEmpty { Text(tagline).font(.callout.italic()) }
                    if let overview = (details?.overview ?? title.overview)?.nonEmpty {
                        Text(overview).font(.callout).lineLimit(download == nil ? 5 : 3).frame(maxWidth: 1100, alignment: .leading)
                    }
                    actions.padding(.top, 14)
                    if let download { SeerrDownloadPanel(progress: download, isSeries: title.isSeries).padding(.top, 8) }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading) }
                }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.bottom, 70)
        }
        .task {
            status = title.status
            await reload()
        }
        .task(id: isLoading) {
            // Follow the download while the page is open, as often as Jellyseerr learns something new.
            while isLoading, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .fullScreenCover(isPresented: $choosingSeasons) {
            if let details {
                SeerrSeasonsView(details: details) { seasons in
                    choosingSeasons = false
                    if let seasons { Task { await request(seasons: seasons) } }
                }
            }
        }
    }

    private var download: DownloadProgress? { (details?.mediaInfo ?? title.mediaInfo)?.download }
    private var isLoading: Bool { status == .processing || download != nil }

    private func reload() async {
        guard let account = model.seerr, let loaded = try? await account.client.details(title) else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            details = loaded
            status = SeerrStatus(loaded.mediaInfo?.status)
        }
    }

    private var metadata: String {
        let kind = title.isSeries ? String(localized: "Serie", comment: "TV series") : String(localized: "Film", comment: "Movie")
        var parts = [title.year, kind].compactMap { $0 }
        if let runtime = details?.runtime, runtime > 0 { parts.append(Format.duration(Double(runtime) * 60)) }
        if let seasons = details?.numberOfSeasons {
            parts.append(seasons == 1 ? String(localized: "1 Staffel") : String(localized: "\(seasons) Staffeln"))
        }
        if let genres = details?.genres?.prefix(3).map(\.name), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if let vote = details?.voteAverage ?? title.voteAverage, vote > 0 {
            parts.append("TMDB " + vote.formatted(.number.precision(.fractionLength(1))))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 24) {
            // Whatever part is already on the server can be watched, also while more is wished for.
            if status == .available || status == .partial || (details?.mediaInfo ?? title.mediaInfo)?.jellyfinMediaId != nil {
                Button { Task { await openInLibrary() } } label: { Label("Ansehen", systemImage: "play.fill") }
            }
            if status == .none || (status == .partial && title.isSeries) {
                Button {
                    if title.isSeries { choosingSeasons = details != nil } else { Task { await request(seasons: nil) } }
                } label: {
                    Label(busy ? "Wird gewünscht …" : status == .partial ? "Fehlende Staffeln wünschen" : "Wünschen",
                          systemImage: "plus")
                }
                .disabled(busy || (title.isSeries && details == nil))
            }
            if let label = status.label, status != .available, status != .partial || !title.isSeries {
                // A button without action, so the focus stays on the page once the wish is sent.
                Button {} label: { Label(label, systemImage: status.symbol) }
            }
        }
    }

    private func request(seasons: [Int]?) async {
        guard let account = model.seerr, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await account.client.request(title, seasons: seasons)
            status = result == 2 ? .processing : .pending
            message = result == 2
                ? String(localized: "Freigegeben – sobald der Titel geladen ist, steht er in deiner Bibliothek.")
                : String(localized: "Gewünscht – ein Admin muss den Wunsch noch freigeben. Danach erscheint er automatisch in deiner Bibliothek.")
            Diagnostics.log("jellyseerr request \(title.id) status=\(result)")
            model.contentChanged()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Jellyseerr knows the title's ID on its Jellyfin server; if that's the server Jelly is using, open it there.
    private func openInLibrary() async {
        guard let id = (details?.mediaInfo ?? title.mediaInfo)?.jellyfinMediaId, let client = model.client, let session = model.session,
              let item = try? await client.item(user: session.userID, id: id) else {
            message = String(localized: "Der Titel liegt auf dem Jellyfin-Server, mit dem Jellyseerr verbunden ist – in deiner aktuellen Bibliothek wurde er nicht gefunden.")
            return
        }
        model.pendingOpen = item
    }
}

/// The download of a wished title: how far, how long still, and for series the episodes on their way.
private struct SeerrDownloadPanel: View {
    let progress: DownloadProgress
    let isSeries: Bool

    private static let maxEpisodes = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(progress.summary, systemImage: progress.phase.symbol).font(.callout.weight(.semibold))
                Spacer()
                Text(times).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            DownloadBar(progress: progress).frame(height: 12)
            if isSeries, progress.parts.count > 1 {
                let shown = progress.parts.prefix(Self.maxEpisodes)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 30, alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                        HStack(spacing: 12) {
                            Text(part.label ?? "–").monospacedDigit().frame(width: 100, alignment: .leading)
                            DownloadBar(fraction: part.fraction, phase: part.phase).frame(width: 80, height: 8)
                            Text(part.phase == .queued
                                 ? String(localized: "wartet", comment: "Episode download is queued") : DownloadProgress.percent(part.fraction))
                                .monospacedDigit().lineLimit(1).fixedSize()
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if progress.parts.count > Self.maxEpisodes {
                    Text("und \(progress.parts.count - Self.maxEpisodes) weitere Folgen").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
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

/// Which seasons to wish for; seasons already there or wished for are marked and not selectable.
private struct SeerrSeasonsView: View {
    let details: SeerrClient.Details
    /// The chosen seasons, or `nil` when the viewer backs out.
    let onRequest: ([Int]?) -> Void
    @State private var selected: Set<Int> = []
    @FocusState private var requestFocused: Bool

    private var seasons: [SeerrClient.Details.Season] { (details.seasons ?? []).filter { $0.seasonNumber > 0 } }

    private func status(_ season: Int) -> SeerrStatus {
        SeerrStatus(details.mediaInfo?.seasons?.first { $0.seasonNumber == season }?.status)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welche Staffeln?").font(.title2.weight(.bold)).padding(.leading, 28).padding(.bottom, 20)
                ForEach(seasons) { season in
                    let state = status(season.seasonNumber)
                    Button {
                        guard state == .none else { return }
                        if selected.contains(season.seasonNumber) { selected.remove(season.seasonNumber) } else { selected.insert(season.seasonNumber) }
                    } label: {
                        SettingsRowLabel(season.name ?? String(localized: "Staffel \(season.seasonNumber)"),
                                         detail: season.episodeCount.map { String(localized: "\($0) Folgen") },
                                         value: state.label, checked: selected.contains(season.seasonNumber))
                    }
                }
                Button { onRequest(selected.sorted()) } label: {
                    SettingsRowLabel(selected.count == 1 ? String(localized: "1 Staffel wünschen")
                                                         : String(localized: "\(selected.count) Staffeln wünschen"), icon: "plus")
                }
                .disabled(selected.isEmpty)
                .focused($requestFocused)
                .padding(.top, 20)
            }
            .frame(maxWidth: 1000)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SettingsRowStyle())
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            selected = Set(seasons.map(\.seasonNumber).filter { status($0) == .none })
            requestFocused = true
        }
        .onExitCommand { onRequest(nil) }
    }
}

// MARK: - Search

private struct SeerrSearchView: View {
    @Binding var path: [DiscoverRoute]
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var results: [SeerrClient.Title] = []
    @State private var searching = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 230), spacing: 48, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if query.isEmpty {
                    ContentUnavailableView("Neues finden", systemImage: "sparkles",
                                           description: Text("Suche nach Filmen und Serien, die du dir über Jellyseerr wünschen möchtest."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else if let error {
                    ContentUnavailableView("Suche fehlgeschlagen", systemImage: "exclamationmark.triangle", description: Text(error))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else if results.isEmpty && !searching {
                    ContentUnavailableView.search(text: query).frame(maxWidth: .infinity).padding(.top, 120)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                    ForEach(results) { title in
                        SeerrCard(title: title) { path.append(.title(title)) }
                    }
                }
                .padding(.horizontal, Theme.edge)
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .searchable(text: $query, prompt: "Filme und Serien")
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2, let account = model.seerr else { results = []; return }
            searching = true
            defer { searching = false }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                results = try await account.client.search(term)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
