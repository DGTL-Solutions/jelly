import SwiftUI
import WidgetKit

@main
struct JellyWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        DownloadLiveActivity()
        #endif
    }
}

// MARK: - Weiterschauen

struct WatchTile: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var progress: Double
    var image: Data?
}

struct ContinueEntry: TimelineEntry {
    let date: Date
    var tiles: [WatchTile]
    var signedIn = true
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: .now, tiles: [WatchTile(id: "-", title: "Jelly", subtitle: nil, progress: 0.4)])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        Task { completion(await load(count: 4)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        Task {
            let entry = await load(count: 4)
            // The app reloads the widget after every playback; this is the fallback for watching on other devices.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }

    private func load(count: Int) async -> ContinueEntry {
        guard let (client, _) = StoredProfile.client() else { return ContinueEntry(date: .now, tiles: [], signedIn: false) }
        let items = await StoredProfile.continueWatching(limit: count)
        var tiles: [WatchTile] = []
        for item in items {
            var data: Data?
            if let url = client.artworkURL(item, .landscape, width: 480) { data = try? await URLSession.shared.data(from: url).0 }
            tiles.append(WatchTile(id: item.id, title: item.isEpisode ? item.seriesName ?? item.name : item.name,
                                   subtitle: item.isEpisode ? [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ") : item.remainingText,
                                   progress: item.progress, image: data))
        }
        return ContinueEntry(date: .now, tiles: tiles)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueProvider()) { entry in
            ContinueView(entry: entry).containerBackground(Color(red: 0.04, green: 0.04, blue: 0.07), for: .widget)
        }
        .configurationDisplayName("Weiterschauen")
        .description("Setze mit einem Tipp fort, was du zuletzt geschaut hast.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct ContinueView: View {
    let entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.tiles.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "play.tv").font(.title2)
                Text(entry.signedIn ? "Nichts zum Weiterschauen" : "In Jelly anmelden").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.7)).padding()
        } else {
            switch family {
            case .systemSmall:
                TileView(tile: entry.tiles[0], large: true).widgetURL(link(entry.tiles[0]))
            case .systemMedium:
                HStack(spacing: 10) {
                    ForEach(entry.tiles.prefix(2)) { tile in Link(destination: link(tile)) { TileView(tile: tile, large: false) } }
                }
                .padding(10)
            default:
                VStack(spacing: 10) {
                    Link(destination: link(entry.tiles[0])) { TileView(tile: entry.tiles[0], large: true) }
                    if entry.tiles.count > 1 {
                        HStack(spacing: 10) {
                            ForEach(entry.tiles.dropFirst().prefix(2)) { tile in Link(destination: link(tile)) { TileView(tile: tile, large: false) } }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func link(_ tile: WatchTile) -> URL { URL(string: "jelly://play/\(tile.id)")! }
}

private struct TileView: View {
    let tile: WatchTile
    /// Fills the whole widget (small) instead of sitting in a row.
    let large: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.08)
            if let data = tile.image, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.title).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle = tile.subtitle { Text(subtitle).font(.caption2).lineLimit(1).opacity(0.75) }
                if tile.progress > 0 {
                    ProgressView(value: min(1, tile.progress)).tint(.white).scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: large ? 0 : 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "play.fill").font(.caption2).padding(6).background(.black.opacity(0.45), in: Circle()).foregroundStyle(.white).padding(8)
        }
    }
}

// MARK: - Downloads

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline(context)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(context.state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !context.state.finished, !context.isStale { ProgressView(value: context.state.progress) }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .widgetURL(URL(string: "jelly://downloads"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline(context)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(context.state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.finished, !context.isStale { ProgressView(value: context.state.progress) }
                }
            } compactLeading: {
                Image(systemName: context.state.finished ? "checkmark" : "arrow.down").foregroundStyle(.tint)
            } compactTrailing: {
                if context.state.finished || context.isStale {
                    Image(systemName: context.state.finished ? "checkmark.circle" : "ellipsis")
                } else {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption2)
                }
            } minimal: {
                Image(systemName: context.state.finished ? "checkmark" : "arrow.down").foregroundStyle(.tint)
            }
            .widgetURL(URL(string: "jelly://downloads"))
        }
    }

    private func headline(_ context: ActivityViewContext<DownloadActivityAttributes>) -> String {
        if context.state.finished { return String(localized: "Download fertig") }
        // In the background the system loads on without telling Jelly how far it is.
        if context.isStale { return String(localized: "Lädt im Hintergrund weiter") }
        return context.state.remaining > 1 ? String(localized: "\(context.state.remaining) Downloads laufen") : String(localized: "Download läuft")
    }
}
#endif
