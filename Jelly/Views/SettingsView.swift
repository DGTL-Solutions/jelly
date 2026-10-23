import SwiftUI
import AVKit

struct SettingsView: View {
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
    @AppStorage("debugOverlay") private var debugOverlay = false
    @AppStorage("showIMDb") private var showIMDb = true
    @AppStorage("showRottenTomatoes") private var showRottenTomatoes = true
    @AppStorage("screensaverMinutes") private var screensaverMinutes = 5
    @State private var display = DisplayCapabilities.current()

    // One page-wide scroll view: tvOS hides the tab bar while it scrolls, and every row exists up front,
    // so the focus never loses its way. Choices open Jelly's own pages instead of the system picker lists.
    var body: some View {
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 90) {
                    profile.frame(width: 440).padding(.top, 60)
                    VStack(alignment: .leading, spacing: 64) {
                        servers
                        profiles
                        jellyseerr
                        SettingsSection("Verbindung", footer: "Misst den Weg zu deinem Server und zeigt, was in Originalqualität läuft, was angepasst wird, woran es hakt und zu welcher Tageszeit die Leitung am schnellsten ist.") {
                            NavigationLink { ConnectionAnalysisView() } label: {
                                SettingsRowLabel("Verbindungsanalyse", icon: "waveform.path.ecg", chevron: true)
                            }
                        }
                        SettingsSection("Wiedergabe", footer: "Jelly spielt immer das Original – Video wird nie neu kodiert. Was das Apple TV selbst decodiert, läuft über Apples Player mit echtem Dolby Vision (Profil 7 als 8.1), HDR10+ und Dolby Atmos; die Datei wird dafür auf dem Apple TV umverpackt, nicht auf dem Server. Alles andere – AV1, VC-1, MPEG-2 und mehr – decodiert Jelly selbst. Intros erkennt Jelly selbst, indem es den Ton benachbarter Folgen vergleicht – auch ohne Server-Plugin.") {
                            SettingsToggle("Nächste Folge automatisch abspielen", isOn: $autoplayNext)
                            SettingsToggle("Intros automatisch überspringen", isOn: $skipIntros)
                            SettingsChoice("Untertitelgröße", selection: $subtitleSize, options: SubtitleSize.allCases) { $0.title }
                            SettingsChoice("Untertitel-Hintergrund", selection: $subtitleBackground, options: SubtitleBackground.allCases) { $0.title }
                            SettingsChoice("Untertitelfarbe", selection: $subtitleColor, options: SubtitleColor.allCases) { $0.title }
                            SettingsChoice("Decoder", selection: $engine, options: EnginePreference.allCases) { $0.title }
                        }
                        SettingsSection("Bewertungen bei Filmen und Serien", footer: IMDbRatings.isAvailable
                                        ? "IMDb-Werte kommen aus IMDbs öffentlichem Bewertungs-Datensatz und werden wöchentlich aktualisiert. Rotten Tomatoes stammt aus den Metadaten deines Jellyfin-Servers und fehlt bei Titeln, für die der Server keinen Kritikerwert hat."
                                        : "Beide Werte stammen aus den Metadaten deines Jellyfin-Servers und fehlen bei Titeln, für die der Server keine Bewertung hat.") {
                            SettingsToggle(IMDbRatings.isAvailable ? "IMDb-Bewertung" : "Bewertung", isOn: $showIMDb)
                            SettingsToggle(IMDbRatings.isAvailable ? "Rotten Tomatoes" : "Kritikerwertung", isOn: $showRottenTomatoes)
                        }
                        SettingsSection("Bildschirmschoner", footer: "Wenn du im Menü nichts tust, füllen deine Film- und Serien-Cover den Bildschirm und drehen sich nacheinander um – wie früher bei iTunes. Jeder Tastendruck beendet ihn; nach einer Stunde übernimmt der Ruhezustand des Apple TV.") {
                            SettingsChoice("Cover-Wand starten", selection: $screensaverMinutes, options: [0, 2, 5, 10, 15]) {
                                $0 == 0 ? "Nie" : "Nach \($0) Minuten"
                            }
                            Button { IdleMonitor.shared.activate() } label: { SettingsRowLabel("Jetzt anzeigen") }
                        }
                        SettingsSection("Langsame Verbindung", footer: "Vor großen Dateien misst Jelly kurz, was die Leitung zum Server schafft. Reicht sie nicht, lässt Jelly zuerst ungenutzte Tonspuren weg (verlustfrei) und lässt erst danach den Server herunterrechnen. Im Player unter ↓ › Qualität jederzeit änderbar.") {
                            SettingsChoice("Bei zu langsamer Verbindung", selection: $slowConnection, options: SlowConnectionPolicy.allCases) { $0.title }
                        }
                        SettingsSection("Bild & Ton", footer: display.matchingEnabled
                                        ? "Das Apple TV schaltet für jeden Film automatisch auf Dolby Vision, HDR10 oder SDR und die passende Bildfrequenz um."
                                        : "Für automatisches Umschalten auf HDR, Dolby Vision und 24 Hz: Apple-TV-Einstellungen › Video und Audio › Inhalt anpassen › Dynamikbereich und Bildfrequenz aktivieren.") {
                            SettingsInfo("Inhalt anpassen", value: display.matchingEnabled ? "Aktiv" : "Aus")
                            SettingsInfo("HDR-Formate des Fernsehers", value: display.hdrFormats.isEmpty ? "Keine erkannt" : display.hdrFormats.joined(separator: ", "))
                        }
                        SettingsSection("Diagnose", footer: "Das Overlay zeigt während der Wiedergabe, was die Leitung liefert, was der Film braucht, Puffer, Hänger und verlorene Bilder – und in Klartext, woran ein Stocken liegt.") {
                            SettingsToggle("Diagnose-Overlay im Player", isOn: $debugOverlay)
                            NavigationLink { DiagnosticsLogView() } label: { SettingsRowLabel("Protokoll anzeigen", chevron: true) }
                        }
                        if purchases.isActive { purchase }
                        SettingsSection("Info", footer: "Jelly ist eine unabhängige App und kein offizielles Produkt des Jellyfin-Projekts. \(AppInfo.copyright)") {
                            SettingsInfo("Jelly", value: "Version \(AppInfo.version)")
                            NavigationLink { LicensesView() } label: {
                                SettingsRowLabel("Open-Source-Lizenzen", icon: "doc.text", detail: "Jelly, AetherEngine, FFmpeg und \(OpenSourceComponent.all.count - 3) weitere", chevron: true)
                            }
                            NavigationLink { PrivacyNoticeView() } label: {
                                SettingsRowLabel("Datenschutz", icon: "hand.raised", chevron: true)
                            }
                        }
                    }
                    .frame(maxWidth: 1100)
                }
                .padding(.horizontal, Theme.edge)
                .padding(.top, 30)
                .padding(.bottom, 80)
            }
            .buttonStyle(SettingsRowStyle())
            .background(Theme.background.ignoresSafeArea())
            .onAppear { display = DisplayCapabilities.current() }
        }
    }

    private var profile: some View {
        VStack(spacing: 30) {
            if let session = model.session {
                Avatar(user: model.user ?? UserDto(id: session.userID, name: session.name, primaryImageTag: session.imageTag),
                       server: session.server, size: 260)
                VStack(spacing: 8) {
                    Text(session.name).font(.title2.weight(.bold))
                    Text(model.serverInfo?.serverName ?? session.serverName ?? session.server.host() ?? "")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var servers: some View {
        SettingsSection("Server", footer: model.servers.count > 1
                        ? "Wähle einen Server, um zu wechseln – Bibliothek, Weiterschauen und Top Shelf folgen dem aktiven Server. Die Anmeldungen bleiben gespeichert."
                        : "Jelly kann mit mehreren Jellyfin-Servern verbunden bleiben, zum Beispiel deinem eigenen und dem von Freunden. Gewechselt wird hier, ohne neue Anmeldung.") {
            ForEach(model.servers) { server in
                Button { model.switchTo(server: server) } label: {
                    SettingsRowLabel(server.name, icon: "server.rack", detail: serverDetail(server), checked: server.id == model.session?.serverKey)
                }
            }
            Button { model.addServer() } label: { SettingsRowLabel("Server hinzufügen", icon: "plus") }
        }
    }

    private func serverDetail(_ server: AppModel.ServerGroup) -> String {
        let host = server.url.host(percentEncoded: false).map { host in server.url.port.map { "\(host):\($0)" } ?? host }
        let version = server.id == model.session?.serverKey ? model.serverInfo?.version : model.knownServers.first { $0.id == server.id }?.version
        let profiles = server.accounts.count > 1 ? "\(server.accounts.count) Profile" : nil
        return [host, version.map { "Jellyfin \($0)" }, profiles].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private var profiles: some View {
        let current = model.servers.first { $0.id == model.session?.serverKey }
        return SettingsSection("Profile auf \(current?.name ?? "diesem Server")") {
            ForEach(current?.accounts ?? [], id: \.key) { account in
                Button { model.switchTo(account) } label: {
                    SettingsRowLabel(account.name, icon: "person.crop.circle", checked: account.key == model.session?.key)
                }
            }
            Button { model.addProfile() } label: { SettingsRowLabel("Profil hinzufügen", icon: "person.badge.plus") }
            if model.accounts.count > 1 {
                SettingsToggle("Beim Start nach Profil fragen", isOn: $askProfileOnLaunch)
            }
            Button(role: .destructive) { Task { await model.signOut() } } label: {
                SettingsRowLabel("\(model.session?.name ?? "Profil") abmelden", icon: "rectangle.portrait.and.arrow.right", destructive: true)
            }
        }
    }
}

extension SettingsView {
    /// The App Store version's subscription.
    var purchase: some View {
        SettingsSection("Jahresabo", footer: purchases.message ?? "\(purchases.price) pro Jahr, verlängert sich automatisch – gilt für alle Apple TVs mit deiner Apple-ID. Kündigen: Apple-TV-Einstellungen › Benutzer und Accounts › Abonnements.") {
            SettingsInfo("Jelly", value: purchaseStatus)
            Button { model.showsPaywall = true } label: {
                SettingsRowLabel(purchases.access.isActive ? "Abo, Nutzungsbedingungen & Datenschutz" : purchases.trialAvailable ? "Kostenlos testen" : "Jahresabo abschließen",
                                 icon: purchases.access.isActive ? "doc.text" : "star", chevron: true)
            }
            if !purchases.access.isActive {
                Button { Task { await purchases.restore() } } label: {
                    SettingsRowLabel("Käufe wiederherstellen", icon: "arrow.clockwise", value: purchases.busy ? "…" : nil)
                }
            }
        }
    }

    private var purchaseStatus: String {
        switch purchases.access {
        case .checking: return "Wird geprüft …"
        case .notSubscribed: return "Kein Abo"
        case .trial(let days): return days == 1 ? "Probezeit: noch 1 Tag" : "Probezeit: noch \(days) Tage"
        case .subscribed: return "Abo aktiv"
        case .expired: return "Abo abgelaufen"
        case .unlocked: return "Freigeschaltet"
        }
    }

    var jellyseerr: some View {
        SettingsSection("Jellyseerr", footer: "Zum Wünschen neuer Filme und Serien im Tab „Erkunden“. Die Anmeldung gilt für dieses Profil.") {
            if let seerr = model.seerr {
                SettingsInfo(seerr.server.host(percentEncoded: false) ?? seerr.server.absoluteString, value: "Angemeldet als \(seerr.name)")
                Button(role: .destructive) { Task { await model.disconnectSeerr() } } label: {
                    SettingsRowLabel("Jellyseerr trennen", icon: "xmark.circle", destructive: true)
                }
            } else {
                NavigationLink { SeerrConnectView() } label: {
                    SettingsRowLabel("Jellyseerr verbinden", icon: "sparkles", chevron: true)
                }
            }
        }
    }
}

// MARK: - Settings rows

/// A titled group of rows with an optional explanation below, like the Apple TV's own settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 28).padding(.bottom, 4)
            content
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28).padding(.top, 6)
            }
        }
    }
}

/// White with dark text when focused, translucent otherwise.
struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowBackground(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct SettingsRowBackground<Label: View>: View {
    let pressed: Bool
    @ViewBuilder let label: Label
    @Environment(\.isFocused) private var focused

    var body: some View {
        label
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(focused ? Color.white : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(pressed ? 0.98 : focused ? 1.02 : 1)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 10)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct SettingsRowLabel: View {
    let title: String
    var icon: String?
    var detail: String?
    var value: String?
    var chevron = false
    var checked = false
    var destructive = false
    @Environment(\.isFocused) private var focused

    init(_ title: String, icon: String? = nil, detail: String? = nil, value: String? = nil, chevron: Bool = false,
         checked: Bool = false, destructive: Bool = false) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.value = value
        self.chevron = chevron
        self.checked = checked
        self.destructive = destructive
    }

    var body: some View {
        HStack(spacing: 22) {
            if let icon {
                Image(systemName: icon).font(.title3).frame(width: 44)
                    .foregroundStyle(destructive ? .red : focused ? .black : Theme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(destructive ? Color.red : focused ? .black : .white)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(focused ? Color.black.opacity(0.6) : .secondary)
                }
            }
            .padding(.vertical, detail == nil ? 0 : 14)
            Spacer(minLength: 20)
            if let value { Text(value).foregroundStyle(focused ? Color.black.opacity(0.6) : .secondary).lineLimit(1) }
            if checked { Image(systemName: "checkmark").font(.headline).foregroundStyle(focused ? .black : Theme.accent) }
            if chevron { Image(systemName: "chevron.right").font(.headline).foregroundStyle(focused ? Color.black.opacity(0.5) : .secondary) }
        }
    }
}

/// On/off row: a click flips the value.
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: { SettingsRowLabel(title, value: isOn ? "Ein" : "Aus") }
    }
}

/// Row showing the current choice; a click opens a page with all options.
struct SettingsChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String

    init(_ title: String, selection: Binding<Value>, options: [Value], name: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.name = name
    }

    var body: some View {
        NavigationLink {
            SettingsChoicePage(title: title, selection: $selection, options: options, name: name)
        } label: {
            SettingsRowLabel(title, value: name(selection), chevron: true)
        }
    }
}

private struct SettingsChoicePage<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.bold)).padding(.leading, 28).padding(.bottom, 24)
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        SettingsRowLabel(name(option), checked: option == selection)
                    }
                    .focused($focused, equals: option)
                }
            }
            .frame(maxWidth: 1000)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SettingsRowStyle())
        .background(Theme.background.ignoresSafeArea())
        .defaultFocus($focused, selection)
    }
}

/// Read-only row; a button without action so the remote can scroll to it and it lights up like the others.
struct SettingsInfo: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Button {} label: { SettingsRowLabel(title, value: value) }
    }
}

/// The diagnostics log on the TV itself, newest entries first.
struct DiagnosticsLogView: View {
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Diagnose-Protokoll").font(.title2.weight(.bold))
                    Spacer()
                    Button("Löschen", role: .destructive) {
                        try? FileManager.default.removeItem(at: Diagnostics.url)
                        lines = []
                    }
                }
                if lines.isEmpty { Text("Noch keine Einträge.").foregroundStyle(.secondary) }
                // Blocks of lines are focusable so the remote can scroll through them.
                ForEach(Array(stride(from: 0, to: lines.count, by: 6)), id: \.self) { start in
                    Text(lines[start..<min(start + 6, lines.count)].joined(separator: "\n"))
                        .font(.system(size: 20, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .focusable()
                }
            }
            .padding(60)
        }
        .onAppear {
            let text = (try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? ""
            lines = text.split(separator: "\n").map(String.init).reversed()
        }
    }
}

struct DisplayCapabilities {
    var matchingEnabled: Bool
    var hdrFormats: [String]

    @MainActor
    static func current() -> DisplayCapabilities {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let modes = AVPlayer.availableHDRModes
        var formats: [String] = []
        if modes.contains(.dolbyVision) { formats.append("Dolby Vision") }
        if modes.contains(.hdr10) { formats.append("HDR10") }
        if modes.contains(.hlg) { formats.append("HLG") }
        return DisplayCapabilities(matchingEnabled: window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false, hdrFormats: formats)
    }
}
