import SwiftUI

/// What the quality sheet is about: one film or episode, or several episodes of a season at once.
struct DownloadPick: Identifiable {
    let id = UUID()
    var title: String
    var items: [BaseItem]
}

extension DownloadCenter {
    /// The sheet presented over the tabs; set from detail pages and context menus.
    static let pick = DownloadPickState()
}

@MainActor
final class DownloadPickState: ObservableObject {
    @Published var current: DownloadPick?

    func open(_ items: [BaseItem], title: String) {
        guard !items.isEmpty else { return }
        current = DownloadPick(title: title, items: items)
    }
}

private var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "dein iPad") : String(localized: "dein iPhone")
}

// MARK: - Quality sheet

/// Original, Besser, Gut with the size of each, the free space, and the choice that suits this device.
struct DownloadQualitySheet: View {
    let pick: DownloadPick
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options: [DownloadOption] = []
    @State private var hdr = false
    @State private var loading = true
    @State private var error: String?
    @State private var starting: DownloadQuality?

    private var free: Int64? { downloads.freeSpace }
    private var recommended: DownloadQuality? { DownloadPlanner.recommended(options, free: free) }
    private var allowed: Bool { model.user?.policy?.enableContentDownloading ?? true }

    var body: some View {
        NavigationStack {
            List {
                if !allowed {
                    Section { Label(DownloadCenter.StartError.notAllowed.errorDescription ?? "", systemImage: "lock") }
                } else if loading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    Section {
                        ForEach(options) { option in optionRow(option) }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let free {
                                Text(UIDevice.current.userInterfaceIdiom == .pad ? "Frei auf deinem iPad: \(DownloadPlanner.size(free))"
                                     : "Frei auf deinem iPhone: \(DownloadPlanner.size(free))")
                            }
                            if options.contains(where: { $0.quality != .original }) {
                                Text("„Besser“ und „Gut“ rechnet dein Server beim Laden um. Die Größe ist eine Obergrenze, meist wird die Datei kleiner.")
                            }
                            if hdr {
                                Text("Umgerechnete Kopien sind SDR. HDR und Dolby Vision bleiben nur im Original erhalten.")
                            }
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle(pick.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func optionRow(_ option: DownloadOption) -> some View {
        let fits = DownloadPlanner.fits(option, free: free)
        return Button { Task { await start(option.quality) } } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(option.quality.title).font(.headline).fixedSize()
                        if option.quality == recommended {
                            Text("Empfohlen für \(deviceName)")
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.25), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(description(option)).font(.footnote).foregroundStyle(.secondary)
                    if !fits {
                        Text("Nicht genug Platz frei").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if starting == option.quality {
                    ProgressView()
                } else {
                    Text((option.isEstimate ? "≈ " : "") + DownloadPlanner.size(option.bytes))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(fits ? .primary : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!fits || starting != nil)
        .opacity(fits ? 1 : 0.55)
        .accessibilityHint(option.quality == recommended ? Text("Empfohlen") : Text(""))
    }

    private func description(_ option: DownloadOption) -> String {
        let resolution = option.resolution.map { $0 + " · " } ?? ""
        switch option.quality {
        case .original: return resolution + String(localized: "Datei unverändert, Bild und Ton wie auf dem Server")
        case .better: return resolution + String(localized: "Ton in 5.1 – auf iPhone und iPad kaum vom Original zu unterscheiden")
        case .good: return resolution + String(localized: "Stereo – wenn der Platz knapp ist")
        }
    }

    /// Sizes from the server's stream info; for several episodes the sum, each episode falling back to its next
    /// larger option where a step down isn't worth it.
    private func load() async {
        guard allowed, let client = model.client, let session = model.session else { loading = false; return }
        var perItem: [[DownloadOption]] = []
        for item in pick.items {
            guard let info = try? await client.playbackInfo(user: session.userID, itemID: item.id),
                  let source = info.mediaSources.first(where: { $0.requiresOpening != true }) ?? info.mediaSources.first else { continue }
            let audioIndex = TrackPreference.audioIndex(for: source, userLanguage: model.user?.configuration?.audioLanguagePreference)
            let audio = source.audioStreams.first { $0.index == audioIndex }
            let canConvert = model.user?.policy?.enableVideoPlaybackTranscoding ?? true
            perItem.append(DownloadPlanner.options(source: source, runtime: item.runtimeSeconds, audio: audio, canConvert: canConvert))
            if TechInfo.dynamicRange(source.video) != nil { hdr = true }
        }
        options = DownloadPlanner.combined(perItem)
        if options.isEmpty { error = String(localized: "Die Datei konnte nicht abgefragt werden.") }
        loading = false
    }

    private func start(_ quality: DownloadQuality) async {
        guard let client = model.client, let session = model.session else { return }
        starting = quality
        defer { starting = nil }
        do {
            for item in pick.items {
                try await downloads.start(item, quality: quality, client: client, session: session,
                                          audioLanguage: model.user?.configuration?.audioLanguagePreference)
            }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Button on detail pages

/// Download, progress ring while it loads, a filled arrow once it is saved.
struct DownloadStatusButton<Style: ButtonStyle>: View {
    let item: BaseItem
    let style: Style
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadCenter.shared
    @State private var confirmsRemoval = false

    private var record: DownloadRecord? { downloads.record(itemID: item.id, profileKey: model.session?.key) }

    var body: some View {
        Group {
            if let record {
                Button { confirmsRemoval = true } label: { icon(record) }
                    .confirmationDialog(record.state == .finished ? "Download löschen?" : "Download abbrechen?",
                                        isPresented: $confirmsRemoval, titleVisibility: .visible) {
                        if record.state == .failed {
                            Button("Erneut versuchen") { DownloadCenter.pick.open([item], title: item.name) }
                        }
                        Button(record.state == .finished ? "Löschen" : "Abbrechen", role: .destructive) { downloads.remove(record) }
                    } message: {
                        if let error = record.error, record.state == .failed { Text(error) }
                        else if record.state == .finished {
                            Text("\(record.quality.title) · \(DownloadPlanner.size(record.receivedBytes))")
                        }
                    }
            } else {
                Button { DownloadCenter.pick.open([item], title: item.name) } label: { Image(systemName: "arrow.down.circle") }
            }
        }
        .buttonStyle(style)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func icon(_ record: DownloadRecord) -> some View {
        switch record.state {
        case .finished:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
        case .preparing, .downloading:
            DownloadRing(progress: record.progress)
        }
    }

    private var label: Text {
        switch record?.state {
        case .finished?: return Text("Heruntergeladen")
        case .failed?: return Text("Download fehlgeschlagen")
        case .preparing?, .downloading?: return Text("Wird geladen")
        case nil: return Text("Herunterladen")
        }
    }
}

struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.03, progress))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
            Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Downloads tab

/// Everything saved on this device for the current profile: films, then series with their episodes. Works without
/// a connection; positions watched offline go to the server later.
struct DownloadsScreen: View {
    /// Inside Settings' own navigation stack instead of a tab.
    var embedded = false
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadCenter.shared

    private var mine: [DownloadRecord] {
        downloads.records(profileKey: model.session?.key).sorted { $0.added > $1.added }
    }

    private var movies: [DownloadRecord] { mine.filter { $0.seriesID == nil } }

    private var series: [(id: String, name: String, episodes: [DownloadRecord])] {
        Dictionary(grouping: mine.filter { $0.seriesID != nil }, by: { $0.seriesID! })
            .map { (id: $0.key, name: $0.value.first?.seriesName ?? "", episodes: $0.value.sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            Group {
                if mine.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Tippe bei einem Film oder einer Folge auf \(Image(systemName: "arrow.down.circle")), um sie für unterwegs zu speichern – ohne Verbindung zum Server abspielbar.")
                    }
                } else {
                    List {
                        if !movies.isEmpty {
                            Section("Filme") { ForEach(movies) { DownloadRow(record: $0) } }
                        }
                        ForEach(series, id: \.id) { show in
                            Section(show.name) { ForEach(show.episodes) { DownloadRow(record: $0) } }
                        }
                        Section {
                        } footer: {
                            Text("Belegt: \(DownloadPlanner.size(downloads.usedSpace)) · Frei: \(DownloadPlanner.size(downloads.freeSpace ?? 0))")
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
    }
}

private struct DownloadRow: View {
    let record: DownloadRecord
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadCenter.shared

    var body: some View {
        Button { play() } label: {
            HStack(spacing: 12) {
                RemoteImage(url: downloads.imageURL(record))
                    .frame(width: record.seriesID == nil ? 54 : 104, height: record.seriesID == nil ? 80 : 58)
                    .background(Theme.placeholder)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if record.state == .finished, record.position > 0, record.runtime > 0, !record.played {
                            WatchProgressBar(progress: record.position / record.runtime).padding(4)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    status
                }
                Spacer(minLength: 0)
                if record.played {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) { downloads.remove(record) } label: { Label("Löschen", systemImage: "trash") }
        }
        .contextMenu {
            if record.state == .finished {
                Button { play() } label: { Label("Abspielen", systemImage: "play.fill") }
            }
            Button(role: .destructive) { downloads.remove(record) } label: {
                Label(record.state == .finished ? "Löschen" : "Abbrechen", systemImage: "trash")
            }
        }
    }

    private var title: String {
        guard record.seriesID != nil else { return record.name }
        let label = [record.season.map { "S\($0)" }, record.episode.map { "F\($0)" }].compactMap { $0 }.joined(separator: " · ")
        return [label.nonEmpty, record.name].compactMap { $0 }.joined(separator: " – ")
    }

    @ViewBuilder private var status: some View {
        switch record.state {
        case .finished:
            Text("\(record.quality.title) · \(DownloadPlanner.size(record.receivedBytes))\(record.needsSync ? " · " + String(localized: "wird synchronisiert") : "")")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(record.error ?? String(localized: "Fehlgeschlagen")).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .preparing:
            Text("Wird vorbereitet …").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: record.progress).tint(Theme.accent)
                Text("\(DownloadPlanner.size(record.receivedBytes)) von \(record.quality == .original ? "" : "≈ ")\(DownloadPlanner.size(record.expectedBytes))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func play() {
        guard record.state == .finished, let item = downloads.item(record) else { return }
        model.play(item)
    }
}
