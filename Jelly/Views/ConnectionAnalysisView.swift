import SwiftUI

/// Einstellungen › Verbindungsanalyse: what the connection to the server can carry, and what that means for streaming.
struct ConnectionAnalysisView: View {
    var autoStart = false
    @EnvironmentObject private var model: AppModel
    @StateObject private var analyzer = ConnectionAnalyzer()
    @FocusState private var startFocused: Bool

    private let columns = [GridItem(.flexible(), spacing: 40, alignment: .top), GridItem(.flexible(), spacing: 40, alignment: .top)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    header
                    if analyzer.running || analyzer.report != nil { steps }
                    if let report = analyzer.report, !analyzer.running { results(report) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, 50)
            }
            #if DEBUG
            .onChange(of: analyzer.report != nil) { _, done in
                if done, ProcessInfo.processInfo.environment["JELLY_ANALYSIS"] == "end" {
                    Task { try? await Task.sleep(for: .seconds(1)); withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
            #endif
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .onAppear { startFocused = true }
        .task { if autoStart { await analyzer.run(model: model) } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Verbindungsanalyse").font(.system(size: 56, weight: .bold))
                Text("Prüft den Weg zu \(model.session?.serverName ?? String(localized: "deinem Server", comment: "Fallback server name in 'Prüft den Weg zu …'")): Erreichbarkeit, Geschwindigkeit, was davon in deiner Bibliothek im Original läuft und wann die Leitung am schnellsten ist.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 1100, alignment: .leading)
            }
            Spacer()
            Button {
                Task { await analyzer.run(model: model) }
            } label: {
                Label(analyzer.report == nil ? "Analyse starten" : "Erneut analysieren", systemImage: "waveform.path.ecg")
            }
            .focused($startFocused)
            .disabled(analyzer.running)
        }
    }

    private var steps: some View {
        HStack(spacing: 18) {
            ForEach(ConnectionAnalyzer.Step.allCases) { step in
                HStack(spacing: 12) {
                    switch analyzer.states[step] ?? .waiting {
                    case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                    case .running: ProgressView().scaleEffect(0.7)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                    }
                    Text(step.title).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.white.opacity(0.07), in: Capsule())
            }
        }
    }

    // MARK: Results

    @ViewBuilder private func results(_ report: ConnectionAnalyzer.Report) -> some View {
        AnalysisCard(icon: report.level == .good ? "checkmark.seal.fill" : report.level == .fair ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
                     tint: report.level == .good ? .green : report.level == .fair ? .yellow : Color(red: 1, green: 0.4, blue: 0.35),
                     title: report.verdict, value: nil, lines: [report.verdictDetail], prominent: true)
            .focusable()

        LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
            AnalysisCard(icon: "server.rack", tint: Theme.accent,
                         title: String(localized: "Server", comment: "The Jellyfin server"), value: report.serverName, lines: [
                "Jellyfin \(report.version)",
                report.latencyAverage.map { average -> String in
                    let latency = (average * 1000).formatted(.number.precision(.fractionLength(0)))
                    guard let jitter = report.jitter else { return String(localized: "Antwortzeit \(latency) ms") }
                    let spread = (jitter * 500).formatted(.number.precision(.fractionLength(0)))
                    return String(localized: "Antwortzeit \(latency) ms (±\(spread) ms)")
                },
                report.https ? String(localized: "Verschlüsselt (HTTPS)") : String(localized: "Unverschlüsselt (HTTP)"),
                report.proxy.map { String(localized: "Über \($0)", comment: "Connection runs through a proxy, e.g. 'Über Cloudflare'") }
            ].compactMap { $0 })
            .focusable()

            AnalysisCard(icon: report.publicAddress && report.homeAddress == nil ? "globe" : "house", tint: Theme.accent,
                         title: String(localized: "Weg", comment: "Connection analysis: network route to the server"),
                         value: report.homeAddress != nil || !report.publicAddress ? String(localized: "Heimnetz") : String(localized: "Internet"),
                         lines: [
                String(localized: "Apple TV per \(report.interface)", comment: "e.g. 'Apple TV per WLAN' / 'Apple TV per LAN-Kabel'"),
                report.homeAddress.map { String(localized: "Direkt: \($0.host() ?? "")", comment: "Direct address of the server in the home network") },
                report.publicAddress && report.homeAddress == nil ? String(localized: "Der Server steht nicht in diesem Netzwerk") : nil
            ].compactMap { $0 })
            .focusable()

            AnalysisCard(icon: "speedometer", tint: Theme.accent, title: String(localized: "Geschwindigkeit"),
                         value: report.speed.map { String(format: "%.0f Mbit/s", $0.megabits) } ?? "–", lines: speedLines(report))
                .focusable()

            AnalysisCard(icon: "film.stack", tint: Theme.accent, title: String(localized: "Deine Bibliothek"),
                         value: report.library.count > 0 ? originalShare(report.library) : "–",
                         lines: libraryLines(report.library))
                .focusable()

            AnalysisCard(icon: "cpu", tint: Theme.accent, title: String(localized: "Server-Umrechnung"),
                         value: report.conversion.map { String(localized: "\($0.factor.formatted(.number.precision(.fractionLength(1))))× Echtzeit") }
                            ?? String(localized: "nicht nötig", comment: "Server transcoding is not needed"),
                         lines: report.conversion.map { [
                             String(localized: "Getestet mit \($0.title)", comment: "Tested with <movie title>"),
                             String(localized: "Ziel \($0.limit / 1_000_000) Mbit/s · Ergebnis \($0.range)",
                                    comment: "Target bitrate · resulting video range (HDR10/HLG/SDR)"),
                             $0.factor >= 1.3
                                ? String(localized: "Schnell genug für flüssige Wiedergabe")
                                : String(localized: "Zu langsam – angepasste Qualität kann stocken")
                         ] } ?? [String(localized: "Die Leitung trägt alle Titel im Original.")])
                .focusable()

            AnalysisCard(icon: "appletv", tint: Theme.accent, title: String(localized: "Dieses Apple TV"),
                         value: report.dolbyVision ? String(localized: "Dolby Vision bereit") : String(localized: "Ohne Dolby Vision"), lines: [
                report.hdrFormats.isEmpty
                    ? String(localized: "Fernseher: kein HDR erkannt")
                    : String(localized: "Fernseher: \(report.hdrFormats.joined(separator: ", "))", comment: "TV: supported HDR formats"),
                String(localized: "Ton: bis \(report.audioChannels) Kanäle über HDMI"),
                report.matchingEnabled
                    ? String(localized: "Inhalt anpassen: an", comment: "tvOS setting 'Match Content' (Inhalt anpassen) is on")
                    : String(localized: "Inhalt anpassen: aus", comment: "tvOS setting 'Match Content' (Inhalt anpassen) is off")
            ])
            .focusable()
        }

        if let server = model.session?.server {
            let times = ConnectionAnalyzer.timeOfDay(for: server)
            AnalysisCard(icon: "clock", tint: Theme.accent, title: String(localized: "Wann ist die Leitung am schnellsten?"),
                         value: times.count > 1 ? times.max { $0.megabits < $1.megabits }.map { "\($0.label)" } : nil,
                         lines: times.isEmpty || times.count < 2
                            ? [String(localized: "Jede Messung wird gespeichert – auch die automatischen vor großen Filmen. Nach Messungen zu verschiedenen Tageszeiten steht hier, wann die Leitung am schnellsten ist.")]
                            : times.map { time -> String in
                                let megabits = time.megabits.formatted(.number.precision(.fractionLength(0)))
                                return String(localized: "\(time.label): Ø \(megabits) Mbit/s (\(time.count) Messungen)",
                                              comment: "Time of day: average speed (number of measurements)")
                            })
                .focusable()
        }

        if !report.tips.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tipps").font(.title3.weight(.bold))
                ForEach(report.tips) { tip in
                    Label { Text(tip.text).font(.callout) } icon: { Image(systemName: tip.icon).foregroundStyle(Theme.accent) }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .focusable()
                }
            }
        }
    }

    private func speedLines(_ report: ConnectionAnalyzer.Report) -> [String] {
        guard let speed = report.speed else { return [String(localized: "Messung fehlgeschlagen")] }
        var lines = [String]()
        if let minimum = speed.minimum, let maximum = speed.samples.max() {
            let low = (minimum / 1_000_000).formatted(.number.precision(.fractionLength(0)))
            let high = (maximum / 1_000_000).formatted(.number.precision(.fractionLength(0)))
            lines.append(String(localized: "Schwankung \(low)–\(high) Mbit/s", comment: "Speed range: lowest–highest measured"))
        }
        let mbit = speed.megabits
        lines.append(mbit >= 100 ? String(localized: "Reicht für alles, auch 4K-Remuxe")
                     : mbit >= 30 ? String(localized: "Reicht für 4K-Streams (15–25 Mbit/s)")
                     : mbit >= 10 ? String(localized: "Reicht für HD (5–15 Mbit/s)")
                     : String(localized: "Knapp – nur für kleinere Dateien"))
        return lines
    }

    private func originalShare(_ stats: ConnectionAnalyzer.LibraryStats) -> String {
        let share = Double(stats.original + stats.compact) / Double(stats.count)
        return String(localized: "\(share.formatted(.percent.precision(.fractionLength(0)))) im Original",
                      comment: "Share of titles that play in original quality")
    }

    private func libraryLines(_ stats: ConnectionAnalyzer.LibraryStats) -> [String] {
        guard stats.count > 0 else { return [String(localized: "Keine Titel mit Bitrate gefunden")] }
        var lines = [String(localized: "\(stats.original) von \(stats.count) Titeln unverändert")]
        if stats.compact > 0 { lines.append(String(localized: "\(stats.compact) ohne ungenutzte Tonspuren (verlustfrei)")) }
        if stats.adapted > 0 { lines.append(String(localized: "\(stats.adapted) werden vom Server angepasst")) }
        if let biggest = stats.largest.first {
            let megabits = (biggest.bitrate / 1_000_000).formatted(.number.precision(.fractionLength(0)))
            lines.append(String(localized: "Größter Brocken: \(biggest.name) (\(megabits) Mbit/s)", comment: "The title with the highest bitrate"))
        }
        return lines
    }
}

/// One result block; lifts slightly when focused so the remote can scroll through the report.
private struct AnalysisCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String?
    let lines: [String]
    var prominent = false
    @Environment(\.isFocused) private var focused

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(prominent ? .title2.weight(.bold) : .callout.weight(.semibold))
                .foregroundStyle(prominent ? tint : .secondary)
            if let value { Text(value).font(.system(size: prominent ? 44 : 38, weight: .bold)) }
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(focused ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(prominent ? tint.opacity(0.6) : .clear, lineWidth: 3))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}
