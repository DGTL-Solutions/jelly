import SwiftUI

/// Version, open-source licences and privacy, reached from Einstellungen › Info.
enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    static let publisher = "DGTL Solutions GmbH"
    static let copyright = "© 2026 \(publisher)"
    /// Jelly's own source code (MPL-2.0).
    static let sourceURL: String? = "https://github.com/DGTL-Solutions/jelly"
    /// The subscription's terms: Apple's standard licence agreement for App Store apps.
    static let termsURL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    /// The privacy policy as published for the App Store listing.
    static let privacyURL = "https://dgtl-solutions.github.io/jelly/datenschutz/"
}

/// A library inside Jelly and the licence it ships under. `file` names the text in Resources/Licenses.
struct OpenSourceComponent: Identifiable {
    let name: String
    var version: String?
    let license: String
    let file: String
    var copyright: String?
    let url: String
    var role: String?

    var id: String { name }

    /// Everything inside the app (versions as resolved: AetherEngine 7.46.0, FFmpegBuild 3.9.0, LibDovi 2.1.0, libass-build 0.17.5).
    static let all: [OpenSourceComponent] = [
        .init(name: "Jelly", version: AppInfo.version, license: "MPL-2.0", file: "MPL-2.0",
              copyright: "Copyright \(AppInfo.copyright)", url: AppInfo.sourceURL ?? "Quellcode folgt",
              role: "Diese App. Ihr Quellcode ist offen – damit lässt sie sich auch mit geänderten Bibliotheken neu bauen, wie die LGPL es verlangt."),
        .init(name: "AetherEngine", version: "7.46.0", license: "LGPL-3.0 mit App-Store-Ausnahme", file: "AetherEngine",
              copyright: "Copyright © 2026 Vincent Herbst", url: "https://github.com/superuser404notfound/AetherEngine/tree/7.46.0",
              role: "Wiedergabe-Engine von Jelly"),
        .init(name: "FFmpeg", version: "8.1.3", license: "LGPL-2.1-or-later", file: "LGPL-2.1",
              copyright: "Copyright © 2000–2026 the FFmpeg developers", url: "https://ffmpeg.org",
              role: "Öffnet und decodiert Video, Ton und Untertitel. Gebaut ohne GPL-Teile von FFmpegBuild 3.9.0, Quellcode, Änderungen und Build-Skript: https://github.com/superuser404notfound/FFmpegBuild"),
        .init(name: "dav1d", version: "1.5.4", license: "BSD-2-Clause", file: "dav1d", url: "https://code.videolan.org/videolan/dav1d",
              role: "Decodiert AV1"),
        .init(name: "zimg", version: "3.0.6", license: "WTFPL", file: "zimg", url: "https://github.com/sekrit-twc/zimg"),
        .init(name: "ZVBI", version: "0.2.45", license: "LGPL-2.1-or-later, ure.c MIT", file: "libzvbi",
              copyright: "Copyright © Michael H. Schimek, Iñaki García Etxebarria and others", url: "https://github.com/zapping-vbi/zvbi",
              role: "Videotext-Untertitel. Ohne die drei GPL-Dateien gebaut, siehe FFmpegBuild"),
        .init(name: "libdovi (dovi_tool)", version: "2.1.0", license: "MIT", file: "LibDovi",
              copyright: "Copyright © quietvoid and contributors", url: "https://github.com/quietvoid/dovi_tool",
              role: "Liest und wandelt Dolby-Vision-Metadaten"),
        .init(name: "libass", version: "0.17.5", license: "ISC", file: "libass", url: "https://github.com/libass/libass",
              role: "Stellt ASS/SSA-Untertitel dar"),
        .init(name: "FreeType", license: "FreeType License", file: "FreeType",
              copyright: "Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.",
              url: "https://freetype.org"),
        .init(name: "HarfBuzz", license: "MIT (Old MIT)", file: "HarfBuzz", url: "https://harfbuzz.github.io"),
        .init(name: "GNU FriBidi", license: "LGPL-2.1-or-later", file: "LGPL-2.1",
              copyright: "Copyright © Behdad Esfahbod, Dov Grobgeld and Roozbeh Pournader", url: "https://github.com/fribidi/fribidi"),
        .init(name: "libunibreak", license: "zlib", file: "libunibreak", url: "https://github.com/adah1972/libunibreak"),
    ]
}

/// Long text split into focusable blocks, so the Siri Remote can scroll through it.
struct ScrollableText: View {
    let blocks: [String]
    var font: Font = .system(size: 22)

    init(_ text: String, font: Font = .system(size: 22), maxBlock: Int = 900) {
        self.font = font
        var blocks: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = blocks.last, last.count + paragraph.count < maxBlock {
                blocks[blocks.count - 1] = last + "\n\n" + paragraph
            } else {
                blocks.append(paragraph)
            }
        }
        self.blocks = blocks
    }

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            TextBlock(text: block, font: font)
        }
    }

    private struct TextBlock: View {
        let text: String
        let font: Font
        @FocusState private var focused: Bool

        var body: some View {
            Text(text)
                .font(font)
                .foregroundStyle(focused ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.white.opacity(focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focusable()
                .focused($focused)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// Einstellungen › Info › Open-Source-Lizenzen: every library with its licence text, as LGPL and the permissive licences ask.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Open-Source-Lizenzen").font(.title2.weight(.bold)).padding(.leading, 28)
                ScrollableText("Jelly spielt Filme mit AetherEngine und FFmpeg ab und nutzt dafür die folgende freie Software. Danke an alle, die daran mitarbeiten. Ein Klick zeigt Herkunft und vollständigen Lizenztext.",
                               font: .callout)
                    .padding(.bottom, 16)
                ForEach(OpenSourceComponent.all) { component in
                    NavigationLink { LicenseTextView(component: component) } label: {
                        SettingsRowLabel(component.name, detail: [component.version, component.license].compactMap { $0 }.joined(separator: "  ·  "),
                                         chevron: true)
                    }
                }
                Text("DATEN & MARKEN")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.top, 50)
                ScrollableText(Self.notices, font: .callout)
            }
            .frame(maxWidth: 1200)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SettingsRowStyle())
        .background(Theme.background.ignoresSafeArea())
    }

    static var notices: String { (IMDbRatings.isAvailable ? imdbNotice : serverRatingsNotice) + otherNotices }

    private static let imdbNotice = """
    IMDb-Bewertungen: Information courtesy of IMDb (https://www.imdb.com). Used with permission. Jelly lädt dafür IMDbs Datensatz für private, nicht-kommerzielle Nutzung direkt von IMDb auf dieses Apple TV.

    Rotten Tomatoes: Die Kritikerwerte stammen aus den Metadaten deines Jellyfin-Servers. Rotten Tomatoes ist eine Marke der Fandango Media, LLC.


    """

    private static let serverRatingsNotice = """
    Bewertungen: Publikums- und Kritikerwerte stammen aus den Metadaten deines Jellyfin-Servers.


    """

    private static let otherNotices = """
    Erkunden: Titel, Beschreibungen und Bilder stammen von The Movie Database (TMDB) und kommen über deinen Jellyseerr-Server. This product uses the TMDB API but is not endorsed or certified by TMDB.

    Jelly ist eine unabhängige App und kein offizielles Produkt der Projekte Jellyfin oder Jellyseerr. Die Namen gehören ihren jeweiligen Projekten.
    """
}

struct LicenseTextView: View {
    let component: OpenSourceComponent
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(component.name).font(.title2.weight(.bold))
                Text([component.version.map { "Version \($0)" }, component.license].compactMap { $0 }.joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                ScrollableText([component.role, component.copyright, "Quelle: \(component.url)"].compactMap { $0 }.joined(separator: "\n"),
                               font: .callout)
                    .padding(.vertical, 12)
                ScrollableText(text, font: .system(size: 21, design: .monospaced))
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            let url = Bundle.main.url(forResource: "License-\(component.file)", withExtension: "txt")
            text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Lizenztext nicht gefunden."
        }
    }
}

/// Einstellungen › Info › Datenschutz: what Jelly sends where. The App Store privacy policy says the same.
struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Datenschutz").font(.title2.weight(.bold)).padding(.leading, 20).padding(.bottom, 12)
                ScrollableText(Self.text, font: .callout)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    static var text: String { intro + (IMDbRatings.isAvailable ? imdb : "") + rest }

    private static let intro = """
    Jelly sammelt keine Daten über dich. Es gibt keine Werbung, keine Analyse und kein Tracking, und \(AppInfo.publisher) erhält nichts von dieser App.

    Jelly verbindet sich nur mit den Servern, die du selbst einrichtest: deinem Jellyfin-Server und, wenn du willst, deinem Jellyseerr. Dorthin gehen deine Anmeldung, was du abspielst, der Wiedergabefortschritt sowie Ton- und Untertitelwahl – damit „Weiterschauen“ auf all deinen Geräten stimmt.

    Gespeichert werden auf diesem Apple TV nur die Sitzungsschlüssel deiner Server (im Schlüsselbund) und deine Einstellungen. Passwörter speichert Jelly nicht. Ein Abo wickelt Apple über deine Apple-ID ab; Jelly prüft den Abo-Status nur auf diesem Gerät und gibt nichts davon weiter.


    """

    private static let imdb = """
    Für IMDb-Bewertungen lädt Jelly einmal pro Woche IMDbs öffentlichen Bewertungs-Datensatz direkt von IMDb und schickt dabei keine Angaben über dich mit. Abschaltbar unter Einstellungen › Bewertungen.


    """

    private static let rest = """
    Bilder im Tab „Erkunden“ lädt Jelly von The Movie Database (image.tmdb.org).

    Um deinen Server ohne Tippen zu finden, sucht Jelly im lokalen Netzwerk nach Jellyfin-Servern.

    Das Diagnose-Protokoll bleibt auf diesem Apple TV. Es enthält keine Passwörter oder Zugangsschlüssel und lässt sich unter Einstellungen › Diagnose löschen.
    """
}
