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
                Text("Prüft den Weg zu \(model.session?.serverName ?? "deinem Server"): Erreichbarkeit, Geschwindigkeit, was davon in deiner Bibliothek im Original läuft und wann die Leitung am schnellsten ist.")
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
            AnalysisCard(icon: "server.rack", tint: Theme.accent, title: "Server", value: report.serverName, lines: [
                "Jellyfin \(report.version)",
                report.latencyAverage.map { String(format: "Antwortzeit %.0f ms", $0 * 1000) + (report.jitter.map { String(format: " (±%.0f ms)", $0 * 500) } ?? "") },
                report.https ? "Verschlüsselt (HTTPS)" : "Unverschlüsselt (HTTP)",
                report.proxy.map { "Über \($0)" }
            ].compactMap { $0 })
            .focusable()

            AnalysisCard(icon: report.publicAddress && report.homeAddress == nil ? "globe" : "house", tint: Theme.accent, title: "Weg",
                         value: report.homeAddress != nil || !report.publicAddress ? "Heimnetz" : "Internet", lines: [
                "Apple TV per \(report.interface)",
                report.homeAddress.map { "Direkt: \($0.host() ?? "")" },
                report.publicAddress && report.homeAddress == nil ? "Der Server steht nicht in diesem Netzwerk" : nil
            ].compactMap { $0 })
            .focusable()

            AnalysisCard(icon: "speedometer", tint: Theme.accent, title: "Geschwindigkeit",
                         value: report.speed.map { String(format: "%.0f Mbit/s", $0.megabits) } ?? "–", lines: speedLines(report))
                .focusable()

            AnalysisCard(icon: "film.stack", tint: Theme.accent, title: "Deine Bibliothek",
                         value: report.library.count > 0 ? "\(Int((Double(report.library.original + report.library.compact) / Double(report.library.count) * 100).rounded())) % im Original" : "–",
                         lines: libraryLines(report.library))
                .focusable()

            AnalysisCard(icon: "cpu", tint: Theme.accent, title: "Server-Umrechnung",
                         value: report.conversion.map { "\($0.factor.formatted(.number.precision(.fractionLength(1))))× Echtzeit" } ?? "nicht nötig",
                         lines: report.conversion.map { [
                             "Getestet mit \($0.title)",
                             "Ziel \($0.limit / 1_000_000) Mbit/s · Ergebnis \($0.range)",
                             $0.factor >= 1.3 ? "Schnell genug für flüssige Wiedergabe" : "Zu langsam – angepasste Qualität kann stocken"
                         ] } ?? ["Die Leitung trägt alle Titel im Original."])
                .focusable()

            AnalysisCard(icon: "appletv", tint: Theme.accent, title: "Dieses Apple TV",
                         value: report.dolbyVision ? "Dolby Vision bereit" : "Ohne Dolby Vision", lines: [
                "Fernseher: \(report.hdrFormats.isEmpty ? "kein HDR erkannt" : report.hdrFormats.joined(separator: ", "))",
                "Ton: bis \(report.audioChannels) Kanäle über HDMI",
                report.matchingEnabled ? "Inhalt anpassen: an" : "Inhalt anpassen: aus"
            ])
            .focusable()
        }

        if let server = model.session?.server {
            let times = ConnectionAnalyzer.timeOfDay(for: server)
            AnalysisCard(icon: "clock", tint: Theme.accent, title: "Wann ist die Leitung am schnellsten?",
                         value: times.count > 1 ? times.max { $0.megabits < $1.megabits }.map { "\($0.label)" } : nil,
                         lines: times.isEmpty || times.count < 2
                            ? ["Jede Messung wird gespeichert – auch die automatischen vor großen Filmen. Nach Messungen zu verschiedenen Tageszeiten steht hier, wann die Leitung am schnellsten ist."]
                            : times.map { String(format: "%@: Ø %.0f Mbit/s (%d Messungen)", $0.label, $0.megabits, $0.count) })
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
        guard let speed = report.speed else { return ["Messung fehlgeschlagen"] }
        var lines = [String]()
        if let minimum = speed.minimum, let maximum = speed.samples.max() {
            lines.append(String(format: "Schwankung %.0f–%.0f Mbit/s", minimum / 1_000_000, maximum / 1_000_000))
        }
        let mbit = speed.megabits
        lines.append(mbit >= 100 ? "Reicht für alles, auch 4K-Remuxe" : mbit >= 30 ? "Reicht für 4K-Streams (15–25 Mbit/s)" : mbit >= 10 ? "Reicht für HD (5–15 Mbit/s)" : "Knapp – nur für kleinere Dateien")
        return lines
    }

    private func libraryLines(_ stats: ConnectionAnalyzer.LibraryStats) -> [String] {
        guard stats.count > 0 else { return ["Keine Titel mit Bitrate gefunden"] }
        var lines = ["\(stats.original) von \(stats.count) Titeln unverändert"]
        if stats.compact > 0 { lines.append("\(stats.compact) ohne ungenutzte Tonspuren (verlustfrei)") }
        if stats.adapted > 0 { lines.append("\(stats.adapted) werden vom Server angepasst") }
        if let biggest = stats.largest.first {
            lines.append(String(format: "Größter Brocken: %@ (%.0f Mbit/s)", biggest.name, biggest.bitrate / 1_000_000))
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
