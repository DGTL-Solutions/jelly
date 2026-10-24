import SwiftUI

// MARK: - Navigation

enum MobileRoute: Hashable {
    case item(BaseItem)
    case library(BaseItem)
    case person(Person)
}

struct OpenMobileItemAction {
    let open: (BaseItem) -> Void
    func callAsFunction(_ item: BaseItem) { open(item) }
}

extension EnvironmentValues {
    /// Opens a film, series, episode, season or library on the current tab's stack.
    @Entry var openMobileItem = OpenMobileItemAction { _ in }
}

/// The navigation stack of each tab: detail pages, libraries and people, pushed the same way everywhere.
struct MobileBrowseStack<Root: View>: View {
    var opensPendingItem = false
    @ViewBuilder let root: Root
    @EnvironmentObject private var model: AppModel
    @State private var path: [MobileRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .item(let item): ItemDetailScreen(item: item)
                    case .library(let library): LibraryScreen(library: library)
                    case .person(let person): PersonScreen(person: person)
                    }
                }
        }
        .environment(\.openMobileItem, OpenMobileItemAction { item in path.append(Self.route(for: item)) })
        .onChange(of: model.pendingOpen, initial: true) { _, item in
            guard opensPendingItem, let item else { return }
            model.pendingOpen = nil
            path.append(Self.route(for: item))
        }
    }

    /// Seasons go to the detail screen too: it shows their series with that season selected.
    static func route(for item: BaseItem) -> MobileRoute {
        item.isFolder && item.type != "Season" ? .library(item) : .item(item)
    }
}

// MARK: - Artwork

/// An item's poster, still or backdrop with a quiet placeholder; loads at the pixel width it is shown at.
struct ArtworkImage: View {
    let item: BaseItem
    let style: ArtworkStyle
    var pixelWidth = 600
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.placeholder
            Image(systemName: item.isSeries || item.isEpisode ? "tv" : item.isFolder ? "rectangle.stack" : "film")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            RemoteImage(url: model.client?.artworkURL(item, style, width: pixelWidth))
        }
    }
}

/// Thin progress line at the bottom of artwork, for titles in progress.
struct WatchProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.5))
                Capsule().fill(.white).frame(width: max(4, proxy.size.width * progress))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Cards

/// A 2:3 poster with title and year below; opens the item when tapped.
struct PosterCard: View {
    let item: BaseItem
    var width: CGFloat = 120
    @Environment(\.openMobileItem) private var openItem

    var body: some View {
        Button { openItem(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(item: item, style: .poster, pixelWidth: Int(width * 3))
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottom) {
                        if item.progress > 0.01, !item.isWatched { WatchProgressBar(progress: item.progress).padding(6) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.isWatched {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent).padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(item.isEpisode ? item.seriesName ?? item.name : item.name)
                    .font(.footnote.weight(.semibold)).lineLimit(1)
                if let year = item.productionYear {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu { MobileItemActions(item: item) }
    }
}

/// A 16:9 still for episodes and "Continue Watching", with what's left to watch.
struct WideCard: View {
    let item: BaseItem
    var width: CGFloat = 260
    /// Overrides opening the detail page, e.g. to play right away.
    var action: (() -> Void)?
    @Environment(\.openMobileItem) private var openItem

    var body: some View {
        Button { if let action { action() } else { openItem(item) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(item: item, style: .landscape, pixelWidth: Int(width * 3))
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) {
                        if item.progress > 0.01, !item.isWatched { WatchProgressBar(progress: item.progress).padding(8) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(item.isEpisode ? item.seriesName ?? item.name : item.name)
                    .font(.footnote.weight(.semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu { MobileItemActions(item: item, includesDetails: action != nil) }
    }

    private var subtitle: String? {
        if item.isEpisode { return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ") }
        if item.progress > 0, let remaining = item.remainingText { return remaining }
        return item.productionYear.map(String.init)
    }
}

/// Long-press menu shared by cards: play, details (when tapping the card plays), mark watched, favourite.
struct MobileItemActions: View {
    let item: BaseItem
    var includesDetails = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.openMobileItem) private var openItem

    var body: some View {
        if item.isPlayable {
            Button { model.play(item) } label: { Label(item.progress > 0 ? "Fortsetzen" : "Abspielen", systemImage: "play.fill") }
            if item.progress > 0 {
                Button { model.play(item, fromBeginning: true) } label: { Label("Von Anfang an", systemImage: "arrow.counterclockwise") }
            }
        }
        if includesDetails {
            Button { openItem(item) } label: { Label("Details anzeigen", systemImage: "info.circle") }
        }
        if item.isPlayable || item.isSeries {
            Button { Task { await model.setWatched(item, !item.isWatched) } } label: {
                Label(item.isWatched ? "Als ungesehen markieren" : "Als gesehen markieren", systemImage: item.isWatched ? "eye.slash" : "checkmark.circle")
            }
            Button { Task { await model.setFavorite(item, !item.isFavorite) } } label: {
                Label(item.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
        }
    }
}

// MARK: - Rows and states

/// A titled, horizontally scrolling row.
struct ShelfSection<Items: RandomAccessCollection, Card: View>: View where Items.Element: Identifiable {
    let title: String
    let items: Items
    var spacing: CGFloat = 12
    @ViewBuilder let card: (Items.Element) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct MobileLoadingView: View {
    var text: String = String(localized: "Wird geladen …")

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MobileErrorView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Verbindung fehlgeschlagen", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button("Erneut versuchen", action: retry).buttonStyle(.borderedProminent) }
        }
    }
}
