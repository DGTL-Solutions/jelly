import SwiftUI
import TVServices

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var item: BaseItem
    var fromBeginning = false
    var mediaSourceID: String?
    /// The retry after a failure: every stream through the software decoder.
    var forceSoftware = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var accounts: [Session]
    @Published private(set) var user: UserDto?
    @Published private(set) var serverInfo: PublicSystemInfo?
    @Published private(set) var knownServers: [KnownServer]
    /// "Wer schaut gerade?" before the library, at launch with several profiles or after "Profil wechseln".
    @Published var choosingProfile: Bool
    /// Onboarding shown on top of an existing account to add another profile.
    @Published var addingAccount = false
    /// Server whose user picker should open directly, e.g. when adding a profile.
    @Published var preselectedServer: KnownServer?
    @Published var playback: PlaybackRequest?
    /// Detail page to open on the start tab (Top Shelf links, debug launch arguments).
    @Published var pendingOpen: BaseItem?
    /// Changes after playback or watched-state edits so screens reload resume positions.
    @Published private(set) var refreshID = UUID()
    /// The server's address in the home network while it is reachable; otherwise the saved (public) address is used.
    @Published private(set) var homeAddress: URL?
    /// The active profile's Jellyseerr sign-in, for "Erkunden".
    @Published private(set) var seerr: SeerrAccount?
    /// The App Store version's trial and purchase (always unlocked in builds from source).
    let purchases = Purchases()
    /// The offer: trial, full version, restore.
    @Published var showsPaywall = false

    let deviceID: String
    private var store: AccountStore

    init() {
        let defaults = UserDefaults.standard
        store = SecureStore.load(fallbackDeviceID: defaults.string(forKey: "deviceID") ?? UUID().uuidString)
        deviceID = store.deviceID
        defaults.set(deviceID, forKey: "deviceID")
        accounts = store.accounts
        session = store.active
        choosingProfile = store.accounts.count > 1 && (defaults.object(forKey: "askProfileOnLaunch") as? Bool ?? true)
        knownServers = (defaults.data(forKey: "knownServers")).flatMap { try? JSONDecoder().decode([KnownServer].self, from: $0) } ?? []
        loadSeerr()
        #if DEBUG
        if ProcessInfo.processInfo.environment["JELLY_SIGN_OUT"] != nil, session != nil {
            Task { await signOut() }
        }
        debugAutoLogin()
        // A copy of the signed-in account that poses as a second server, to try switching without another server.
        if ProcessInfo.processInfo.environment["JELLY_SECOND_SERVER"] != nil, let session, !store.accounts.contains(where: { $0.serverID == "debug-second" }) {
            var copy = session
            copy.serverID = "debug-second"
            copy.serverName = "Testserver"
            store.accounts.append(copy)
            persistAccounts()
        }
        #endif
    }

    var showsOnboarding: Bool { session == nil || addingAccount }

    var client: JellyfinClient? {
        session.map { JellyfinClient(server: homeAddress ?? $0.server, token: $0.token, deviceID: deviceID) }
    }

    // MARK: Home network

    /// LAN addresses seen per server ID, e.g. from discovery during setup.
    private var lanAddresses: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: "lanAddresses") as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "lanAddresses") }
    }

    func noteDiscovered(_ server: DiscoveredServer) {
        guard ServerLocator.isPrivate(server.url) else { return }
        var addresses = lanAddresses
        addresses[server.id] = ([server.url.absoluteString] + (addresses[server.id] ?? [])).uniqued()
        lanAddresses = addresses
    }

    /// At home, talk to the server directly instead of through the internet (and a proxy such as Cloudflare):
    /// faster, no upload limit, and Jellyfin recognises the Apple TV as local.
    func preferHomeNetwork() async {
        guard let session, let serverID = session.serverID else {
            Diagnostics.log("home network: no server id")
            homeAddress = nil
            return
        }
        if ServerLocator.isPrivate(session.server) { homeAddress = nil; return }
        var candidates = (lanAddresses[serverID] ?? []).compactMap(URL.init(string:))
        if candidates.isEmpty {
            // Learn the LAN address once by scanning the local network.
            await LocalNetwork.scan { [weak self] found in
                guard found.id == serverID else { return }
                await self?.noteDiscovered(found)
            }
            candidates = (lanAddresses[serverID] ?? []).compactMap(URL.init(string:))
            Diagnostics.log("home network scan for \(serverID): \(candidates.map(\.absoluteString))")
        }
        for url in candidates {
            if let info = try? await anonymousClient(url).publicInfo(timeout: 2), info.id == serverID {
                if homeAddress != url { Diagnostics.log("home network: \(url.absoluteString)") }
                homeAddress = url
                return
            }
        }
        homeAddress = nil
    }

    func anonymousClient(_ server: URL) -> JellyfinClient {
        JellyfinClient(server: server, deviceID: deviceID)
    }

    // MARK: Accounts

    /// `password` is only passed on to sign in to Jellyseerr with the same account; it is never stored.
    func signIn(server: URL, info: PublicSystemInfo?, result: AuthenticationResult, password: String? = nil) {
        let session = Session(server: server, token: result.accessToken, userID: result.user.id, name: result.user.name,
                              serverID: result.serverId ?? info?.id, serverName: info?.serverName, imageTag: result.user.primaryImageTag)
        store.accounts.removeAll { $0.key == session.key }
        store.accounts.append(session)
        store.activeKey = session.key
        lastProfiles[session.serverKey] = session.key
        persistAccounts()
        remember(KnownServer(id: session.serverID ?? server.absoluteString, name: info?.serverName ?? server.host() ?? "Jellyfin",
                             url: server, version: info?.version))
        preselectedServer = nil
        user = result.user
        serverInfo = info
        withAnimation(.easeInOut(duration: 0.4)) {
            addingAccount = false
            choosingProfile = false
            self.session = session
        }
        loadSeerr()
        contentChanged()
        if let password {
            Task { await connectSeerrAutomatically(username: result.user.name, password: password, user: result.user) }
        }
    }

    /// Saved profiles grouped by server, in the order the servers were added.
    struct ServerGroup: Identifiable {
        let id: String
        var name: String
        var url: URL
        var accounts: [Session]
    }

    var servers: [ServerGroup] {
        var groups: [ServerGroup] = []
        for account in accounts {
            if let index = groups.firstIndex(where: { $0.id == account.serverKey }) {
                groups[index].accounts.append(account)
            } else {
                let name = account.serverName ?? knownServers.first { $0.id == account.serverKey }?.name ?? account.server.host() ?? "Jellyfin"
                groups.append(ServerGroup(id: account.serverKey, name: name, url: account.server, accounts: [account]))
            }
        }
        return groups
    }

    /// Changes to another server with the profile last used there.
    func switchTo(server: ServerGroup) {
        guard server.id != session?.serverKey, let first = server.accounts.first else { return }
        let last = lastProfiles[server.id]
        switchTo(server.accounts.first { $0.key == last } ?? first)
    }

    /// Opens the onboarding at the server choice to connect one more server.
    func addServer() {
        preselectedServer = nil
        withAnimation { addingAccount = true; choosingProfile = false }
    }

    private var lastProfiles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "lastProfileByServer") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "lastProfileByServer") }
    }

    func switchTo(_ account: Session) {
        homeAddress = nil
        lastProfiles[account.serverKey] = account.key
        store.activeKey = account.key
        persistAccounts()
        user = nil
        serverInfo = nil
        withAnimation(.easeInOut(duration: 0.4)) {
            session = account
            choosingProfile = false
        }
        loadSeerr()
        contentChanged()
        Task { await refreshAccount() }
    }

    /// Opens the onboarding for another profile, starting at the current server's user picker.
    func addProfile() {
        preselectedServer = knownServers.first { $0.url == session?.server }
        withAnimation { addingAccount = true; choosingProfile = false }
    }

    func cancelAddingProfile() {
        withAnimation { addingAccount = false }
    }

    /// Validates the stored token and loads the user's preferences.
    func refreshAccount() async {
        guard let client else { return }
        do {
            user = try await client.currentUser()
            serverInfo = try? await client.publicInfo()
        } catch JellyError.unauthorized {
            await signOut()
        } catch {}
    }

    /// Signs the active profile out on the server and removes it from this Apple TV.
    func signOut() async {
        guard let session else { return }
        let client = client
        store.accounts.removeAll { $0.key == session.key }
        store.activeKey = store.accounts.first?.key
        persistAccounts()
        user = nil
        serverInfo = nil
        withAnimation(.easeInOut(duration: 0.4)) {
            self.session = store.active
            choosingProfile = store.accounts.count > 1
        }
        SecureStore.setData(nil, for: "seerr:\(session.key)")
        loadSeerr()
        contentChanged()
        await client?.logout()
    }

    private func persistAccounts() {
        accounts = store.accounts
        if (try? SecureStore.save(store)) == nil {
            // A keychain failure only costs the automatic sign-in on the next launch; the session itself is valid.
            Diagnostics.log("keychain save failed")
        }
    }

    // MARK: Jellyseerr

    private func loadSeerr() {
        seerr = session.flatMap { SecureStore.data(for: "seerr:\($0.key)") }.flatMap { try? JSONDecoder().decode(SeerrAccount.self, from: $0) }
    }

    /// The Jellyseerr address this profile used last, to offer it again after signing out or an expired session.
    var lastSeerrServer: URL? {
        session.flatMap { UserDefaults.standard.url(forKey: "seerrServer:\($0.key)") }
    }

    func connectSeerr(_ account: SeerrAccount) {
        guard let session else { return }
        SecureStore.setData(try? JSONEncoder().encode(account), for: "seerr:\(session.key)")
        UserDefaults.standard.set(account.server, forKey: "seerrServer:\(session.key)")
        withAnimation { seerr = account }
    }

    /// Right after a Jellyfin sign-in with a password: signs in to the Jellyseerr next to that server with the same
    /// account, so "Erkunden" works without a second sign-in. Only where the Jellyseerr provably belongs to this
    /// Jellyfin (`SeerrClient.belongs`), and never for accounts with a limit on simultaneous sign-ins – Jellyseerr's
    /// check opens a Jellyfin session of its own that stays until the server restarts and would use up one of them.
    private func connectSeerrAutomatically(username: String, password: String, user: UserDto) async {
        guard let session, seerr == nil else { return }
        #if DEBUG
        // Test runs use real accounts: signing in to their Jellyseerr has to be asked for.
        guard ProcessInfo.processInfo.environment["JELLY_SEERR_AUTO"] != nil else { return }
        #endif
        guard let policy = user.policy, (policy.maxActiveSessions ?? 0) <= 0 else {
            Diagnostics.log("jellyseerr auto: skipped, account allows \(user.policy?.maxActiveSessions.map(String.init) ?? "?") sessions")
            return
        }
        let lan = session.serverID.flatMap { lanAddresses[$0] }?.compactMap(URL.init(string:)) ?? []
        let jellyfin = [session.server] + lan
        guard let (server, _) = await SeerrClient.find(near: jellyfin) else {
            Diagnostics.log("jellyseerr auto: none found")
            return
        }
        guard let settings = try? await SeerrClient(server: server).publicSettings(),
              SeerrClient.belongs(server, settings: settings, to: jellyfin) else {
            Diagnostics.log("jellyseerr auto: \(server.host() ?? "?") not linked to this Jellyfin")
            return
        }
        do {
            let (seerrUser, cookie) = try await SeerrClient(server: server).signIn(username: username, password: password, local: false)
            // The viewer may have switched to another profile meanwhile.
            guard self.session?.key == session.key, seerr == nil else {
                await SeerrClient(server: server, cookie: cookie).signOut()
                return
            }
            connectSeerr(SeerrAccount(server: server, cookie: cookie, userID: seerrUser.id, name: seerrUser.name))
            Diagnostics.log("jellyseerr auto-connected \(server.host() ?? "") as \(seerrUser.name)")
        } catch {
            Diagnostics.log("jellyseerr auto: \(error)")
        }
    }

    /// Signs out of Jellyseerr; `expired` when Jellyseerr already ended the session itself.
    func disconnectSeerr(expired: Bool = false) async {
        guard let session, let account = seerr else { return }
        SecureStore.setData(nil, for: "seerr:\(session.key)")
        withAnimation { seerr = nil }
        if !expired { await account.client.signOut() }
    }

    func forget(_ server: KnownServer) {
        knownServers.removeAll { $0.id == server.id }
        persistServers()
    }

    private func remember(_ server: KnownServer) {
        knownServers.removeAll { $0.id == server.id || $0.url == server.url }
        knownServers.insert(server, at: 0)
        persistServers()
    }

    private func persistServers() {
        UserDefaults.standard.set(try? JSONEncoder().encode(knownServers), forKey: "knownServers")
    }

    // MARK: Playback & content

    func play(_ item: BaseItem, fromBeginning: Bool = false, mediaSourceID: String? = nil) {
        // Without a running trial or the full version, playing asks for one of them first.
        guard purchases.access.canPlay else {
            showsPaywall = true
            return
        }
        playback = PlaybackRequest(item: item, fromBeginning: fromBeginning, mediaSourceID: mediaSourceID)
    }

    /// Right after the first sign-in, the App Store version presents its subscription offer once; later playback asks again.
    func offerTrialIfNeeded() async {
        guard purchases.isActive, session != nil, !UserDefaults.standard.bool(forKey: "trialOffered") else { return }
        for _ in 0..<20 where purchases.access == .checking { try? await Task.sleep(for: .milliseconds(250)) }
        guard purchases.access == .notSubscribed else { return }
        UserDefaults.standard.set(true, forKey: "trialOffered")
        showsPaywall = true
    }

    func contentChanged() {
        refreshID = UUID()
        // Keeps "Weiterschauen" on the Apple TV home screen current.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    func setWatched(_ item: BaseItem, _ watched: Bool) async {
        guard let client, let session else { return }
        try? await client.setPlayed(user: session.userID, id: item.id, watched)
        contentChanged()
    }

    func setFavorite(_ item: BaseItem, _ favorite: Bool) async {
        guard let client, let session else { return }
        try? await client.setFavorite(user: session.userID, id: item.id, favorite)
        contentChanged()
    }

    /// Links from the Top Shelf: `jelly://play/<id>` starts playback, `jelly://item/<id>` opens the detail page.
    func open(_ url: URL) async {
        guard url.scheme == "jelly", let action = url.host(), let id = url.pathComponents.dropFirst().first,
              let client, let session, let item = try? await client.item(user: session.userID, id: id) else { return }
        choosingProfile = false
        if action == "play" {
            // A series from "Neu in deiner Mediathek" starts with its next episode.
            if item.isSeries { await playSeries(item) } else { play(item) }
        } else {
            pendingOpen = item
        }
    }

    #if DEBUG
    /// Simulator testing only: JELLY_OPEN / JELLY_PLAY take an item id from the launch environment.
    func runDebugActions() async {
        let env = ProcessInfo.processInfo.environment
        guard let client, let session else { return }
        if let id = env["JELLY_OPEN"] { pendingOpen = try? await client.item(user: session.userID, id: id) }
        if let id = env["JELLY_PLAY"], let item = try? await client.item(user: session.userID, id: id) { play(item) }
    }

    /// Simulator testing only: JELLY_SERVER / JELLY_USER / JELLY_PASSWORD from the launch environment.
    private func debugAutoLogin() {
        let env = ProcessInfo.processInfo.environment
        guard session == nil, let address = env["JELLY_SERVER"], let username = env["JELLY_USER"] else { return }
        Task {
            do {
                let (url, info) = try await ServerLocator.resolve(address)
                let password = env["JELLY_PASSWORD"] ?? ""
                let result = try await anonymousClient(url).authenticate(username: username, password: password)
                signIn(server: url, info: info, result: result, password: password)
            } catch {
                print("[Jelly] Debug login failed: \(error)")
            }
        }
    }
    #endif
}
