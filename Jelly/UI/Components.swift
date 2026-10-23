import SwiftUI

enum Theme {
    static let edge: CGFloat = 80
    static let background = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let accent = Color(red: 0.55, green: 0.47, blue: 1.0)
    static let brand = LinearGradient(colors: [Color(red: 0.67, green: 0.36, blue: 0.86), Color(red: 0.0, green: 0.64, blue: 0.86)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let placeholder = LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
}

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

// MARK: - Images

actor ImagePipeline {
    static let shared = ImagePipeline()
    nonisolated(unsafe) private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 180 * 1024 * 1024
        return cache
    }()
    private var running: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    nonisolated func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL, authorization: String? = nil) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if let task = running[url] { return await task.value }
        let session = session
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let task = Task<UIImage?, Never> { [request] in
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

/// Fills the frame its parent gives it and fades the image in once loaded.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImagePipeline.shared.cached($0) })
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = ImagePipeline.shared.cached(url) { image = cached; return }
                let loaded = await ImagePipeline.shared.image(url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { image = loaded }
            }
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
    var text = "Wird geladen …"
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

// MARK: - Ratings

/// IMDb and Rotten Tomatoes scores, each switchable in the settings.
struct RatingBadges: View {
    let item: BaseItem
    @AppStorage("showIMDb") private var showIMDb = true
    @AppStorage("showRottenTomatoes") private var showRottenTomatoes = true
    @State private var imdb: IMDbRating?

    var body: some View {
        HStack(spacing: 22) {
            if !IMDbRatings.isAvailable, showIMDb, let rating = item.communityRating, rating > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(rating.formatted(.number.precision(.fractionLength(1)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Bewertung \(rating.formatted(.number.precision(.fractionLength(1))))")
            }
            if showIMDb, let imdb {
                HStack(spacing: 10) {
                    Text("IMDb")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(imdb.rating.formatted(.number.precision(.fractionLength(1)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("IMDb \(imdb.rating.formatted(.number.precision(.fractionLength(1))))")
            }
            if showRottenTomatoes, let score = item.criticRating {
                HStack(spacing: 10) {
                    if IMDbRatings.isAvailable {
                        TomatoIcon(fresh: score >= 60)
                    } else {
                        // Without the brand: a neutral critics' score from the server's metadata.
                        Image(systemName: score >= 60 ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .foregroundStyle(score >= 60 ? .green : .orange)
                    }
                    Text((score / 100).formatted(.percent.precision(.fractionLength(0)))).font(.callout.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(IMDbRatings.isAvailable ? "Rotten Tomatoes" : "Kritiker") \(Int(score)) Prozent")
            }
        }
        .task(id: "\(item.imdbID ?? "")-\(showIMDb)") {
            guard IMDbRatings.isAvailable, showIMDb, let id = item.imdbID else { imdb = nil; return }
            imdb = await IMDbRatings.shared.rating(for: id)
        }
    }
}

/// Fresh: a red tomato with green leaves. Rotten: a green splat.
struct TomatoIcon: View {
    let fresh: Bool

    var body: some View {
        ZStack {
            if fresh {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.3, blue: 0.18), Color(red: 0.82, green: 0.1, blue: 0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 26)
                    .offset(y: 3)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.2))
                    .rotationEffect(.degrees(-40))
                    .offset(y: -10)
            } else {
                Image(systemName: "burst.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(red: 0.04, green: 0.78, blue: 0.33))
            }
        }
        .frame(width: 32, height: 32)
    }
}
