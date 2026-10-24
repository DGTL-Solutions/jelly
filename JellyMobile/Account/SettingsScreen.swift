import SwiftUI
import StoreKit

/// Einstellungen: servers and profiles, Jellyseerr, playback, the subscription, info and diagnostics.
/// The playback settings use the same keys as on Apple TV, so the player behaves the same.
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @AppStorage("autoplayNext") private var autoplayNext = true
    @AppStorage("skipIntros") private var skipIntros = false
    @AppStorage("askProfileOnLaunch") private var askProfileOnLaunch = true
    @AppStorage("subtitleSize") private var subtitleSize = SubtitleSize.standard
    @AppStorage("subtitleBackground") private var subtitleBackground = SubtitleBackground.shadow
    @AppStorage("subtitleColor") private var subtitleColor = SubtitleColor.white
    @AppStorage("enginePreference") private var engine = EnginePreference.automatic
    @AppStorage("slowConnection") private var slowConnection = SlowConnectionPolicy.adapt
    @AppStorage("showIMDb") private var showIMDb = true
    @AppStorage("showRottenTomatoes") private var showRottenTomatoes = true
    @State private var connectingSeerr = false
    @State private var managingSubscription = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                profileHeader
                servers
                profiles
                jellyseerr
                playback
                subtitles
                Section {
                    Picker("Bei zu langsamer Verbindung", selection: $slowConnection) {
                        ForEach(SlowConnectionPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Langsame Verbindung")
                } footer: {
                    Text("Vor großen Dateien misst Jelly kurz, was die Leitung zum Server schafft. Reicht sie nicht, lässt Jelly zuerst ungenutzte Tonspuren weg (verlustfrei) und lässt erst danach den Server herunterrechnen.")
                }
                ratings
                if purchases.isActive { subscription }
                Section("Diagnose") {
                    NavigationLink { DiagnosticsLogScreen() } label: {
                        Label("Protokoll anzeigen", systemImage: "list.bullet.rectangle")
                    }
                }
                info
            }
            .navigationTitle("Einstellungen")
            .sheet(isPresented: $connectingSeerr) { SeerrConnectSheet() }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .confirmationDialog(signOutTitle, isPresented: $confirmingSignOut, titleVisibility: .hidden) {
                Button(signOutTitle, role: .destructive) { Task { await model.signOut() } }
            }
        }
    }

    // MARK: Account

    private var profileHeader: some View {
        Section {
            if let session = model.session {
                HStack(spacing: 16) {
                    AccountAvatar(user: model.user ?? UserDto(id: session.userID, name: session.name, primaryImageTag: session.imageTag),
                                  server: session.server, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.name).font(.title3.weight(.semibold))
                        Text(model.serverInfo?.serverName ?? session.serverName ?? session.server.host() ?? "")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var servers: some View {
        Section {
            ForEach(model.servers) { server in
                Button { model.switchTo(server: server) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack").foregroundStyle(Theme.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).foregroundStyle(.primary)
                            Text(serverDetail(server)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if server.id == model.session?.serverKey {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .accessibilityAddTraits(server.id == model.session?.serverKey ? .isSelected : [])
            }
            Button { model.addServer() } label: { Label("Server hinzufügen", systemImage: "plus") }
        } header: {
            Text("Server", comment: "Settings section: Jellyfin servers")
        } footer: {
            Text(model.servers.count > 1
                 ? String(localized: "Wähle einen Server, um zu wechseln. Bibliothek und Weiterschauen folgen dem aktiven Server; die Anmeldungen bleiben gespeichert.")
                 : String(localized: "Jelly kann mit mehreren Jellyfin-Servern verbunden bleiben, zum Beispiel deinem eigenen und dem von Freunden. Gewechselt wird hier, ohne neue Anmeldung."))
        }
    }

    private func serverDetail(_ server: AppModel.ServerGroup) -> String {
        let version = server.id == model.session?.serverKey ? model.serverInfo?.version : model.knownServers.first { $0.id == server.id }?.version
        let profiles = server.accounts.count > 1 ? String(localized: "\(server.accounts.count) Profile") : nil
        return [AccountFormat.host(server.url), version.map { "Jellyfin \($0)" }, profiles].compactMap { $0 }.joined(separator: " · ")
    }

    private var profiles: some View {
        let current = model.servers.first { $0.id == model.session?.serverKey }
        return Section {
            ForEach(current?.accounts ?? [], id: \.key) { account in
                Button { model.switchTo(account) } label: {
                    HStack(spacing: 14) {
                        AccountAvatar(user: UserDto(id: account.userID, name: account.name, primaryImageTag: account.imageTag),
                                      server: account.server, size: 30)
                        Text(account.name).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if account.key == model.session?.key {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .accessibilityAddTraits(account.key == model.session?.key ? .isSelected : [])
            }
            Button { model.addProfile() } label: { Label("Profil hinzufügen", systemImage: "person.badge.plus") }
            if model.accounts.count > 1 {
                Toggle("Beim Start nach Profil fragen", isOn: $askProfileOnLaunch)
            }
            Button(role: .destructive) { confirmingSignOut = true } label: {
                Label(signOutTitle, systemImage: "rectangle.portrait.and.arrow.right").foregroundStyle(.red)
            }
        } header: {
            Text(current.map { String(localized: "Profile auf \($0.name)") } ?? String(localized: "Profile auf diesem Server"))
        }
    }

    private var signOutTitle: String {
        model.session.map { String(localized: "\($0.name) abmelden") } ?? String(localized: "Profil abmelden")
    }

    private var jellyseerr: some View {
        Section {
            if let seerr = model.seerr {
                LabeledContent(seerr.server.host(percentEncoded: false) ?? seerr.server.absoluteString,
                               value: String(localized: "Angemeldet als \(seerr.name)"))
                Button(role: .destructive) { Task { await model.disconnectSeerr() } } label: {
                    Label("Jellyseerr trennen", systemImage: "xmark.circle").foregroundStyle(.red)
                }
            } else {
                Button { connectingSeerr = true } label: { Label("Jellyseerr verbinden", systemImage: "sparkles") }
            }
        } header: {
            Text(verbatim: "Jellyseerr")
        } footer: {
            Text("Zum Wünschen neuer Filme und Serien im Tab „Erkunden“. Die Anmeldung gilt für dieses Profil.")
        }
    }

    // MARK: Playback

    private var playback: some View {
        Section {
            Toggle("Nächste Folge automatisch abspielen", isOn: $autoplayNext)
            Toggle("Intros automatisch überspringen", isOn: $skipIntros)
            Picker("Decoder", selection: $engine) {
                ForEach(EnginePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Wiedergabe")
        } footer: {
            Text("Jelly spielt immer das Original – Video wird nie neu kodiert. Was dein Gerät selbst decodieren kann, läuft über Apples Player; alles andere – AV1, VC-1, MPEG-2 und mehr – decodiert Jelly selbst. Intros erkennt Jelly selbst, indem es den Ton benachbarter Folgen vergleicht – auch ohne Server-Plugin.")
        }
    }

    private var subtitles: some View {
        Section("Untertitel") {
            SubtitlePreview(size: subtitleSize, background: subtitleBackground, color: subtitleColor)
                .listRowInsets(EdgeInsets())
            Picker("Untertitelgröße", selection: $subtitleSize) {
                ForEach(SubtitleSize.allCases) { Text($0.title).tag($0) }
            }
            Picker("Untertitel-Hintergrund", selection: $subtitleBackground) {
                ForEach(SubtitleBackground.allCases) { Text($0.title).tag($0) }
            }
            Picker("Untertitelfarbe", selection: $subtitleColor) {
                ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var ratings: some View {
        Section {
            Toggle(IMDbRatings.isAvailable ? String(localized: "IMDb-Bewertung") : String(localized: "Bewertung", comment: "Rating"), isOn: $showIMDb)
            Toggle(IMDbRatings.isAvailable ? "Rotten Tomatoes" : String(localized: "Kritikerwertung"), isOn: $showRottenTomatoes)
        } header: {
            Text("Bewertungen bei Filmen und Serien")
        } footer: {
            Text(IMDbRatings.isAvailable
                 ? String(localized: "IMDb-Werte kommen aus IMDbs öffentlichem Bewertungs-Datensatz und werden wöchentlich aktualisiert. Rotten Tomatoes stammt aus den Metadaten deines Jellyfin-Servers und fehlt bei Titeln, für die der Server keinen Kritikerwert hat.")
                 : String(localized: "Beide Werte stammen aus den Metadaten deines Jellyfin-Servers und fehlen bei Titeln, für die der Server keine Bewertung hat."))
        }
    }

    // MARK: Subscription

    /// The App Store version's subscription.
    private var subscription: some View {
        Section {
            LabeledContent("Jelly", value: purchaseStatus)
            Button { model.showsPaywall = true } label: {
                Label(purchases.access.isActive ? String(localized: "Abo, Nutzungsbedingungen & Datenschutz")
                      : purchases.trialAvailable ? String(localized: "Kostenlos testen") : String(localized: "Jahresabo abschließen"),
                      systemImage: purchases.access.isActive ? "doc.text" : "star")
            }
            if purchases.access.isActive || purchases.access == .expired {
                Button { managingSubscription = true } label: { Label("Abo verwalten", systemImage: "creditcard") }
            }
            if !purchases.access.isActive {
                Button { Task { await purchases.restore() } } label: {
                    HStack {
                        Label("Käufe wiederherstellen", systemImage: "arrow.clockwise")
                        Spacer()
                        if purchases.busy { ProgressView() }
                    }
                }
                .disabled(purchases.busy)
            }
        } header: {
            Text("Jahresabo")
        } footer: {
            Text(purchases.message ?? String(localized: "\(purchases.price) pro Jahr, verlängert sich automatisch – gilt auf iPhone, iPad und Apple TV mit deiner Apple-ID. Kündigen: „Abo verwalten“ oder Einstellungen › dein Name › Abonnements."))
        }
    }

    private var purchaseStatus: String {
        switch purchases.access {
        case .checking: return String(localized: "Wird geprüft …")
        case .notSubscribed: return String(localized: "Kein Abo")
        case .trial(let days): return days == 1 ? String(localized: "Probezeit: noch 1 Tag") : String(localized: "Probezeit: noch \(days) Tage")
        case .subscribed: return String(localized: "Abo aktiv")
        case .expired: return String(localized: "Abo abgelaufen")
        case .unlocked: return String(localized: "Freigeschaltet")
        }
    }

    // MARK: Info

    private var info: some View {
        Section {
            LabeledContent("Jelly", value: String(localized: "Version \(AppInfo.version)"))
            NavigationLink { LicensesScreen() } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open-Source-Lizenzen")
                        Text("Jelly, AetherEngine, FFmpeg und \(OpenSourceComponent.all.count - 3) weitere")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "doc.text") }
            }
            NavigationLink { PrivacyNoticeScreen() } label: { Label("Datenschutz", systemImage: "hand.raised") }
            if let source = AppInfo.sourceURL.flatMap(URL.init(string:)) {
                AccountLinkRow(title: String(localized: "Quellcode"), icon: "chevron.left.forwardslash.chevron.right", url: source)
            }
            if let support = URL(string: AppInfo.supportURL) {
                AccountLinkRow(title: String(localized: "Hilfe und Kontakt"), icon: "questionmark.circle", url: support)
            }
            if let imprint = URL(string: AppInfo.imprintURL) {
                AccountLinkRow(title: String(localized: "Impressum"), icon: "building.2", url: imprint)
            }
        } header: {
            Text("Info", comment: "Settings section: about the app")
        } footer: {
            Text("Jelly ist eine unabhängige App und kein offizielles Produkt des Jellyfin-Projekts. \(AppInfo.copyright)")
        }
    }
}

/// A row that opens a web page in Safari.
struct AccountLinkRow: View {
    let title: String
    let icon: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityHint(Text(url.host() ?? ""))
    }
}

/// How subtitles will look in the player, over a darkened frame.
private struct SubtitlePreview: View {
    let size: SubtitleSize
    let background: SubtitleBackground
    let color: SubtitleColor

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.32, green: 0.22, blue: 0.2), Color(red: 0.08, green: 0.08, blue: 0.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            styled
                .padding(.bottom, 18)
                .padding(.horizontal, 20)
        }
        .frame(height: 120)
        .animation(.easeOut(duration: 0.2), value: size)
        .animation(.easeOut(duration: 0.2), value: background)
        .animation(.easeOut(duration: 0.2), value: color)
        .accessibilityHidden(true)
    }

    // The player's sizes are tuned for a TV; here they keep their proportions.
    private var points: CGFloat { size.points * 17 / SubtitleSize.standard.points }

    @ViewBuilder private var styled: some View {
        let text = Text("So sehen deine Untertitel aus.")
            .font(.system(size: points, weight: .semibold))
            .foregroundStyle(color == .yellow ? Color(red: 1, green: 0.88, blue: 0.2) : .white)
            .multilineTextAlignment(.center)
        switch background {
        case .shadow:
            text.shadow(color: .black.opacity(0.95), radius: 1, x: 0, y: 1).shadow(color: .black.opacity(0.7), radius: 4)
        case .box:
            text.padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The diagnostics log on this device, newest entries first.
struct DiagnosticsLogScreen: View {
    @State private var lines: [String] = []
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView("Noch keine Einträge.", systemImage: "list.bullet.rectangle")
            } else {
                List(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Diagnose-Protokoll")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !lines.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Diagnostics.url)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Löschen", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Löschen", isPresented: $confirmingDelete, titleVisibility: .hidden) {
            Button("Löschen", role: .destructive) {
                try? FileManager.default.removeItem(at: Diagnostics.url)
                withAnimation { lines = [] }
            }
        }
        .task { load() }
        .refreshable { load() }
    }

    private func load() {
        let text = (try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? ""
        lines = text.split(separator: "\n").map(String.init).reversed()
    }
}
