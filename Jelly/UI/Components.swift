import SwiftUI

// MARK: - Navigation

struct OpenItemAction {
    let handler: (BaseItem) -> Void
    func callAsFunction(_ item: BaseItem) { handler(item) }
}

extension EnvironmentValues {
    @Entry var openItem = OpenItemAction { _ in }
}

enum Route: Hashable {
    case item(BaseItem)
    case library(BaseItem)
    case person(Person)
}

/// Navigation stack used by every tab. Handles item, library and person routes uniformly.
struct BrowseStack<Root: View>: View {
    @ViewBuilder let root: Root
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .item(let item): ItemDetailView(item: item)
                    case .library(let library): LibraryGridView(library: library)
                    case .person(let person): PersonView(person: person)
                    }
                }
        }
        .environment(\.openItem, OpenItemAction { item in
            if item.isFolder && item.type != "Season" {
                path.append(.library(item))
            } else if item.type == "Season", let seriesID = item.seriesId {
                path.append(.item(BaseItem(id: seriesID, name: item.seriesName ?? item.name, type: "Series")))
            } else {
                path.append(.item(item))
            }
        })
    }
}

struct ItemArtwork: View {
    let item: BaseItem
    let style: ArtworkStyle
    var pixelWidth = 600
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.placeholder
            VStack(spacing: 12) {
                Image(systemName: item.isSeries || item.isEpisode ? "tv" : item.isFolder ? "rectangle.stack" : "film")
                    .font(.system(size: 54, weight: .light))
                if style != .poster || item.imageTags?["Primary"] == nil {
                    Text(item.name).font(.caption).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 16)
                }
            }
            .foregroundStyle(.white.opacity(0.35))
            RemoteImage(url: model.client?.artworkURL(item, style, width: pixelWidth))
        }
    }
}

// MARK: - Cards

struct MediaCard: View {
    let item: BaseItem
    var style: ArtworkStyle = .poster
    var width: CGFloat = 260
    /// Overrides the default action (opening the detail page).
    var action: (() -> Void)?
    @Environment(\.openItem) private var openItem
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var height: CGFloat { style == .poster ? width * 1.5 : width * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let action { action() } else { openItem(item) }
            } label: {
                ItemArtwork(item: item, style: style, pixelWidth: Int(width * 2))
                    .frame(width: width, height: height)
                    .cardDecorations(item)
            }
            .buttonStyle(.card)
            .focused($focused)
            .contextMenu { ItemActions(item: item, includesDetails: action != nil) }

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.top, focused ? 26 : 14)
            .opacity(focused ? 1 : 0.85)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
        .frame(width: width, alignment: .leading)
    }

    private var title: String { item.isEpisode ? item.seriesName ?? item.name : item.name }

    private var subtitle: String? {
        if item.isEpisode {
            return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – ")
        }
        if item.progress > 0, let remaining = item.remainingText { return remaining }
        if item.isFolder { return nil }
        return item.subtitleLine.nonEmpty
    }
}

/// Long-press menu shared by cards.
struct ItemActions: View {
    let item: BaseItem
    var includesDetails = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.openItem) private var openItem

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

struct Shelf<Items: RandomAccessCollection, Card: View>: View where Items.Element: Identifiable {
    let title: String
    let items: Items
    var spacing: CGFloat = 40
    @ViewBuilder let card: (Items.Element) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, Theme.edge)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        .focusSection()
    }
}

struct TechBadges: View {
    let badges: [String]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.55), lineWidth: 2))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// Logo artwork when available, otherwise the title in large type.
struct TitleLogo: View {
    let item: BaseItem
    var maxWidth: CGFloat = 640
    var maxHeight: CGFloat = 220
    var font: Font = .system(size: 72, weight: .bold)
    @EnvironmentObject private var model: AppModel
    @State private var logo: UIImage?

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo).resizable().scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.5), radius: 20)
            } else {
                Text(item.isEpisode ? item.seriesName ?? item.name : item.name)
                    .font(font).lineLimit(2).minimumScaleFactor(0.6)
                    .frame(maxWidth: maxWidth * 1.4, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            }
        }
        .task(id: item.id) {
            guard let url = model.client?.logoURL(item) else { logo = nil; return }
            let image = await ImagePipeline.shared.image(url)
            withAnimation(.easeOut(duration: 0.25)) { logo = image }
        }
    }
}

struct LoadingView: View {
    var text = String(localized: "Wird geladen …")
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        ContentUnavailableView {
            Label("Verbindung fehlgeschlagen", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button("Erneut versuchen", action: retry) }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Backdrop that fills the screen with gradients for legible text on the left and bottom.
struct BackdropView: View {
    let item: BaseItem
    /// Blurs and darkens the artwork once the viewer scrolls into the content below.
    var receded = false
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.background
            RemoteImage(url: model.client?.artworkURL(item, .backdrop, width: 1920))
                .blur(radius: receded ? 40 : 0)
                .scaleEffect(receded ? 1.08 : 1)
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.35), location: 0.55), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Theme.background.opacity(receded ? 0.55 : 0)
        }
        .animation(.easeInOut(duration: 0.45), value: receded)
        .ignoresSafeArea()
    }
}
