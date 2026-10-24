import SwiftUI

// Home, libraries, search, detail pages and people for iPhone and iPad.
// Behaviour and wording follow the Apple TV app (Jelly/Views/HomeView, LibraryViews, ItemDetailView).
// Everything except the five screens is private to this file so it can't clash with other packages.

// MARK: - Layout

/// Sizes that follow the space a screen gets: compact on iPhone, more and larger cards on iPad and in landscape.
private struct LibraryLayout: Equatable {
    var size = CGSize(width: 390, height: 800)
    /// Pages with a large navigation title line their content up with it.
    var alignsWithTitle = false

    /// iPad, or an iPhone in landscape: side-by-side layouts, more columns.
    var isWide: Bool { size.width >= 700 }
    var isLarge: Bool { size.width >= 1000 }
    var edge: CGFloat { alignsWithTitle ? (isWide ? 20 : 16) : isLarge ? 32 : isWide ? 24 : 16 }
    var posterWidth: CGFloat { isLarge ? 168 : isWide ? 148 : 118 }
    var wideCardWidth: CGFloat { isLarge ? 340 : isWide ? 300 : min(280, (size.width - 2 * edge) * 0.76) }
    var cardSpacing: CGFloat { isWide ? 18 : 12 }
}

private extension View {
    /// Keeps a `LibraryLayout` in sync with the size this view is laid out at.
    func measuringLayout(_ layout: Binding<LibraryLayout>) -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            if size.width > 0 { layout.wrappedValue.size = size }
        }
    }
}

/// Clips at the bottom and sides but lets artwork stretch upwards when the page is pulled down.
private struct LibraryOpenTopClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 4000, width: rect.width, height: rect.height + 4000))
    }
}

/// Shows a view sized for the TV (the shared RatingBadges) smaller, taking only the space it is drawn in.
private struct LibraryScaledLayout: Layout {
    var scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let size = subviews.first?.sizeThatFits(.unspecified) else { return .zero }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(view.sizeThatFits(.unspecified)))
    }
}

/// IMDb / critics badges at the size of the metadata text next to them.
private struct LibraryRatings: View {
    let item: BaseItem

    var body: some View {
        LibraryScaledLayout(scale: 0.78) {
            RatingBadges(item: item).scaleEffect(0.78)
        }
    }
}

private extension View {
    /// Simulator testing only: JELLY_SCROLL=<section id> scrolls the page to that section once it has loaded.
    @ViewBuilder func libraryDebugScroll(_ proxy: ScrollViewProxy, ready: Bool) -> some View {
        #if DEBUG
        task(id: ready) {
            guard ready, let target = ProcessInfo.processInfo.environment["JELLY_SCROLL"] else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        }
        #else
        self
        #endif
    }
}

private func libraryErrorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

private func libraryIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

// MARK: - Shared pieces

/// White capsule for the main action, frosted capsule for secondary ones.
private struct LibraryCapsuleButtonStyle: ButtonStyle {
    var prominent = true
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background {
                if prominent {
                    Capsule().fill(.white)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(.white.opacity(0.1))
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Round icon button next to the play button (watched, favourite, version).
private struct LibraryCircleButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(LibraryCircleIcon(active: active))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct LibraryCircleIcon: ViewModifier {
    var active = false
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 48

    func body(content: Content) -> some View {
        content
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(active ? Theme.accent : .white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.ultraThinMaterial))
            .background(Circle().fill(.white.opacity(0.08)))
            .contentShape(Circle())
    }
}

/// A titled, horizontally scrolling row; the title opens the whole list when there is one.
private struct LibraryShelf<Items: RandomAccessCollection, Card: View>: View where Items.Element: Identifiable {
    let title: String
    let items: Items
    let layout: LibraryLayout
    var action: (() -> Void)?
    @ViewBuilder let card: (Items.Element) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let action {
                    Button(action: action) {
                        HStack(spacing: 5) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title3.weight(.bold))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, layout.edge)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: layout.cardSpacing) {
                    ForEach(items) { card($0) }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, layout.edge, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Logo artwork when the server has one, otherwise the title in large type.
private struct LibraryTitleArtwork: View {
    let item: BaseItem
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 100
    var centered = false
    var font: Font = .largeTitle.weight(.bold)
    @EnvironmentObject private var model: AppModel
    @State private var logo: UIImage?
    @State private var resolved = false

    private var title: String { item.isEpisode ? item.seriesName ?? item.name : item.name }
    private var logoURL: URL? { model.client?.logoURL(item, width: 800) }

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: centered ? .bottom : .bottomLeading)
                    .shadow(color: .black.opacity(0.45), radius: 14)
                    .accessibilityLabel(title)
                    .transition(.opacity)
            } else {
                Text(title)
                    .font(font)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .frame(maxWidth: maxWidth * 1.4, alignment: centered ? .center : .leading)
                    .opacity(resolved ? 1 : 0)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .task(id: logoURL) {
            guard let url = logoURL else { logo = nil; resolved = true; return }
            if let cached = ImagePipeline.shared.cached(url) { logo = cached; resolved = true; return }
            let image = await ImagePipeline.shared.image(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { logo = image; resolved = true }
        }
    }
}

/// "4K", "Dolby Vision", "5.1", "UT" as small outlined badges.
private struct LibraryTechBadges: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// Text that shows a few lines and opens fully with "Mehr".
private struct LibraryExpandableText: View {
    let text: String
    var lineLimit = 4
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var truncated: Bool { fullHeight > shownHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(expanded ? nil : lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .top) {
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if truncated || expanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Text(expanded ? String(localized: "Weniger", comment: "Collapses a long description")
                                  : String(localized: "Mehr", comment: "Expands a long description"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if truncated || expanded { withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() } } }
    }
}

/// Round photo of a cast or crew member, initials while there is none.
private struct LibraryPersonPhoto: View {
    let person: Person
    var size: CGFloat
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.placeholder
            Text(initials)
                .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            if let tag = person.primaryImageTag {
                RemoteImage(url: model.client?.imageURL(item: person.id, kind: .primary, tag: tag, width: Int(size * 3)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

private struct LibraryCastCard: View {
    let person: Person
    var size: CGFloat

    var body: some View {
        NavigationLink(value: MobileRoute.person(person)) {
            VStack(spacing: 8) {
                LibraryPersonPhoto(person: person, size: size)
                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let role = person.role?.nonEmpty ?? roleName {
                        Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(width: size + 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var roleName: String? {
        ["Director": String(localized: "Regie", comment: "Crew role: director"),
         "Writer": String(localized: "Drehbuch", comment: "Crew role: writer"),
         "Producer": String(localized: "Produktion", comment: "Crew role: producer")][person.type ?? ""]
    }
}

/// An episode with its still: the season list on detail pages and search results. Tapping plays it.
private struct LibraryEpisodeTile: View {
    enum Emphasis { case plain, nextUp, current }

    let episode: BaseItem
    var emphasis = Emphasis.plain
    /// Search results name the series; season lists the episode number.
    var showsSeries = false
    var stillWidth: CGFloat = 150
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.play(episode) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    still
                    VStack(alignment: .leading, spacing: 3) {
                        if emphasis == .nextUp {
                            Text(String(localized: "Nächste Folge", comment: "Badge on the episode the play button starts"))
                                .font(.caption2.weight(.heavy))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.accent)
                        }
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let detail = detailLine {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !showsSeries, let overview = episode.overview?.nonEmpty {
                    Text(overview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background {
                if emphasis != .plain {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { MobileItemActions(item: episode, includesDetails: true) }
    }

    private var still: some View {
        ArtworkImage(item: episode, style: .landscape, pixelWidth: Int(stillWidth * 3))
            .frame(width: stillWidth, height: stillWidth * 9 / 16)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .overlay(alignment: .bottom) {
                if episode.progress > 0.01, !episode.isWatched { WatchProgressBar(progress: episode.progress).padding(6) }
            }
            .overlay(alignment: .topTrailing) {
                if episode.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        if showsSeries { return episode.seriesName ?? episode.name }
        return [episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " ")
    }

    private var detailLine: String? {
        if showsSeries { return [episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " – ").nonEmpty }
        let date = episode.premiereDate.flatMap(Self.airDate)
        return [episode.remainingText ?? episode.runtimeText, date].compactMap { $0 }.joined(separator: " · ").nonEmpty
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func airDate(_ text: String) -> String? {
        guard let date = dayFormat.date(from: String(text.prefix(10))) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")))
    }
}

// MARK: - Home

private struct HomeLatestRow: Identifiable {
    let library: BaseItem
    let items: [BaseItem]
    var id: String { library.id }
}

struct HomeScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openMobileItem) private var openItem
    @State private var featured: [BaseItem] = []
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var libraries: [BaseItem] = []
    @State private var latest: [HomeLatestRow] = []
    @State private var favorites: [BaseItem] = []
    @State private var collections: [BaseItem] = []
    @State private var playlists: [BaseItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var layout = LibraryLayout()
    @State private var scrolledDown = false
    #if DEBUG
    @State private var debugPerson: Person?
    @State private var debugSearch = false
    #endif

    var body: some View {
        Group {
            if let error, !loaded {
                MobileErrorView(message: error) { Task { await load() } }
            } else if !loaded {
                MobileLoadingView(text: String(localized: "Deine Mediathek wird geladen …"))
            } else if featured.isEmpty && resume.isEmpty && latest.isEmpty {
                ContentUnavailableView("Noch keine Inhalte", systemImage: "film.stack",
                                       description: Text("Sobald dein Server Filme oder Serien enthält, erscheinen sie hier."))
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .measuringLayout($layout)
        .navigationTitle("Start")
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.refreshID) { await load() }
        #if DEBUG
        .task(id: model.session?.key) { await openDebugRoute() }
        .navigationDestination(item: $debugPerson) { PersonScreen(person: $0) }
        .navigationDestination(isPresented: $debugSearch) { SearchScreen() }
        #endif
    }

    #if DEBUG
    /// Simulator testing only: JELLY_ROUTE=item:<id> | person:<id> | search:<term> opens that screen on this stack.
    private func openDebugRoute() async {
        guard let route = ProcessInfo.processInfo.environment["JELLY_ROUTE"], let client = model.client, let session = model.session else { return }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        if route == "search" { debugSearch = true }
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "search": debugSearch = true
        case "person":
            guard let person = try? await client.item(user: session.userID, id: parts[1]) else { return }
            debugPerson = Person(id: person.id, name: person.name, primaryImageTag: person.imageTags?["Primary"])
        default:
            if let item = try? await client.item(user: session.userID, id: parts[1]) { openItem(item) }
        }
    }
    #endif

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: layout.isWide ? 36 : 28) {
                    if !featured.isEmpty {
                        HomeHeroCarousel(items: featured, layout: layout)
                    } else {
                        Color.clear.frame(height: 60)
                    }
                    rows
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .refreshable { await load() }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 140 } action: { _, value in
                withAnimation(.easeOut(duration: 0.2)) { scrolledDown = value }
            }
            .overlay(alignment: .top) {
                // Keeps the status bar legible over the rows once the hero has scrolled away.
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0.85), Theme.background.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .ignoresSafeArea(edges: .top)
                    .opacity(scrolledDown ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .libraryDebugScroll(proxy, ready: loaded)
        }
    }

    @ViewBuilder private var rows: some View {
        if !resume.isEmpty {
            LibraryShelf(title: String(localized: "Weiterschauen"), items: resume, layout: layout) { item in
                WideCard(item: item, width: layout.wideCardWidth) { model.play(item) }
            }
            .id("resume")
        }
        if !nextUp.isEmpty {
            LibraryShelf(title: String(localized: "Nächste Folgen"), items: nextUp, layout: layout) { item in
                WideCard(item: item, width: layout.wideCardWidth) { model.play(item) }
            }
            .id("nextup")
        }
        ForEach(latest) { row in
            LibraryShelf(title: String(localized: "Neu in \(row.library.name)", comment: "Shelf: recently added to <library name>"),
                        items: row.items, layout: layout, action: { openItem(row.library) }) { item in
                PosterCard(item: item, width: layout.posterWidth)
            }
            .id(row.id)
        }
        if !favorites.isEmpty {
            LibraryShelf(title: String(localized: "Favoriten"), items: favorites, layout: layout) { item in
                PosterCard(item: item, width: layout.posterWidth)
            }
        }
        if !collections.isEmpty {
            LibraryShelf(title: String(localized: "Sammlungen", comment: "Movie collections (box sets)"), items: collections, layout: layout) { item in
                PosterCard(item: item, width: layout.posterWidth)
            }
        }
        if !playlists.isEmpty {
            LibraryShelf(title: String(localized: "Playlists"), items: playlists, layout: layout) { item in
                WideCard(item: item, width: layout.wideCardWidth)
            }
        }
        if libraries.count > 1 {
            LibraryShelf(title: String(localized: "Bibliotheken"), items: libraries, layout: layout) { library in
                WideCard(item: library, width: layout.wideCardWidth)
            }
            .id("libraries")
        }
    }

    /// The last start screen appears at once from disk; the fresh one replaces it as soon as the server answers.
    private func load() async {
        guard let client = model.client, let session = model.session else { return }
        if !loaded {
            var cached = client
            cached.cache = .only
            try? await fetch(cached, user: session.userID)
        }
        var fresh = client
        fresh.cache = .store
        do {
            try await fetch(fresh, user: session.userID)
        } catch {
            if !loaded, !libraryIsCancellation(error) { self.error = libraryErrorText(error) }
        }
    }

    private func fetch(_ client: JellyfinClient, user: String) async throws {
        async let viewsRequest = client.views(user: user)
        async let resumeRequest = try? client.resume(user: user)
        async let nextUpRequest = try? client.nextUp(user: user)
        async let favoritesRequest = try? client.items(user: user, .init(types: ["Movie", "Series", "Episode"], sortBy: "SortName", filters: ["IsFavorite"], limit: 30))
        async let collectionsRequest = try? client.items(user: user, .init(types: ["BoxSet"], sortBy: "SortName", limit: 30))
        async let playlistsRequest = try? client.items(user: user, .init(types: ["Playlist"], sortBy: "SortName", limit: 30))
        let views = try await viewsRequest.filter { ["movies", "tvshows", "homevideos", "musicvideos", "boxsets", nil].contains($0.collectionType) }
        let rows = await withTaskGroup(of: (Int, HomeLatestRow?).self) { group in
            for (index, library) in views.enumerated() where library.collectionType != "boxsets" {
                group.addTask {
                    let items = (try? await client.latest(user: user, parentID: library.id)) ?? []
                    return (index, items.isEmpty ? nil : HomeLatestRow(library: library, items: items))
                }
            }
            var rows: [(Int, HomeLatestRow)] = []
            for await (index, row) in group { if let row { rows.append((index, row)) } }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let resume = await resumeRequest ?? []
        let nextUp = await nextUpRequest ?? []
        let favorites = await favoritesRequest?.items ?? []
        let collections = await collectionsRequest?.items ?? []
        let playlists = await playlistsRequest?.items ?? []
        try Task.checkCancellation()
        withAnimation(.easeOut(duration: 0.35)) {
            self.libraries = views
            self.latest = rows
            self.resume = resume
            self.favorites = favorites
            self.collections = collections
            self.playlists = playlists
            // Episodes already in "Weiterschauen" don't need to show up twice.
            self.nextUp = nextUp.filter { episode in !resume.contains { $0.id == episode.id } }
            if featured.isEmpty { featured = Self.pickFeatured(rows) }
            loaded = true
            error = nil
        }
    }

    private static func pickFeatured(_ rows: [HomeLatestRow]) -> [BaseItem] {
        let candidates = rows.flatMap(\.items).filter { ($0.backdropImageTags?.isEmpty == false) && ($0.isMovie || $0.isSeries) }
        let fresh = candidates.filter { !$0.isWatched }
        return Array((fresh.count >= 3 ? fresh : candidates).prefix(12).shuffled().prefix(6))
    }
}

/// Full-width featured titles at the top of the start screen: swipe between them, they also turn by themselves.
private struct HomeHeroCarousel: View {
    let items: [BaseItem]
    let layout: LibraryLayout
    @EnvironmentObject private var model: AppModel
    @Environment(\.openMobileItem) private var openItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: String?
    @State private var idle = true
    @State private var visible = false

    private var wide: Bool { layout.isWide }
    private var currentID: String? { page ?? items.first?.id }

    private var height: CGFloat {
        let size = layout.size
        if wide { return max(280, min(size.width * (size.width > size.height ? 0.5 : 0.66), size.height * 0.78)) }
        return min(size.width * 1.3, size.height * 0.74)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    slide(item)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: height)
        .clipShape(LibraryOpenTopClip())
        .overlay(alignment: wide ? .bottomTrailing : .bottom) {
            if items.count > 1 {
                pageDots
                    .padding(.bottom, 14)
                    .padding(.trailing, wide ? layout.edge + 8 : 0)
            }
        }
        .onScrollPhaseChange { _, phase in idle = phase == .idle }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: idle && visible) {
            // Turns to the next title every few seconds while nobody is swiping.
            guard idle, visible, items.count > 1, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                let index = items.firstIndex { $0.id == currentID } ?? 0
                withAnimation(.easeInOut(duration: 0.7)) { page = items[(index + 1) % items.count].id }
            }
        }
    }

    private func slide(_ item: BaseItem) -> some View {
        ZStack(alignment: wide ? .bottomLeading : .bottom) {
            ZStack {
                Theme.placeholder
                RemoteImage(url: model.client?.artworkURL(item, .backdrop, width: wide ? 1920 : 1280))
            }
            .visualEffect { content, proxy in
                // Pulling the page down enlarges the artwork instead of showing a gap.
                let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY)
                return content.scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .bottom)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .clear, location: 0.22)],
                           startPoint: .top, endPoint: .bottom)
            if wide {
                LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
            }
            // Last, so the artwork always ends in exactly the page colour.
            LinearGradient(stops: [.init(color: .clear, location: wide ? 0.35 : 0.4),
                                   .init(color: Theme.background.opacity(0.75), location: 0.78),
                                   .init(color: Theme.background, location: 0.98)],
                           startPoint: .top, endPoint: .bottom)
            slideText(item)
                .padding(.horizontal, wide ? layout.edge + 8 : 24)
                .padding(.bottom, items.count > 1 ? 40 : 24)
        }
        .contentShape(Rectangle())
        .onTapGesture { openItem(item) }
    }

    private func slideText(_ item: BaseItem) -> some View {
        VStack(alignment: wide ? .leading : .center, spacing: 12) {
            LibraryTitleArtwork(item: item, maxWidth: wide ? 400 : 260, maxHeight: wide ? 130 : 90, centered: !wide,
                         font: wide ? .largeTitle.weight(.bold) : .title.weight(.bold))
            HStack(spacing: 12) {
                if !item.metadataLine.isEmpty { Text(item.metadataLine) }
                LibraryRatings(item: item)
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if wide, let overview = item.overview?.nonEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(layout.size.height > 700 ? 3 : 2)
                    .frame(maxWidth: 540, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button {
                    if item.isSeries { Task { await model.playSeries(item) } } else { model.play(item) }
                } label: {
                    Label(item.isSeries ? "Ansehen" : item.progress > 0 ? "Fortsetzen" : "Abspielen", systemImage: "play.fill")
                }
                .buttonStyle(LibraryCapsuleButtonStyle(prominent: true))
                Button { openItem(item) } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .buttonStyle(LibraryCapsuleButtonStyle(prominent: false))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: wide ? 620 : .infinity, alignment: wide ? .leading : .center)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(items) { item in
                Capsule()
                    .fill(.white.opacity(item.id == currentID ? 0.95 : 0.35))
                    .frame(width: item.id == currentID ? 20 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.5)) { page = item.id } }
            }
        }
        .animation(.easeOut(duration: 0.25), value: currentID)
        .accessibilityHidden(true)
    }
}

// MARK: - Libraries

private enum LibrarySort: String, CaseIterable, Identifiable {
    case name, added, released, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return String(localized: "Name", comment: "Library sort order: by name")
        case .added: return String(localized: "Zuletzt hinzugefügt", comment: "Library sort order: recently added")
        case .released: return String(localized: "Erscheinungsdatum", comment: "Library sort order: release date")
        case .rating: return String(localized: "Bewertung", comment: "Library sort order: by rating")
        }
    }
    var symbol: String {
        switch self {
        case .name: return "textformat"
        case .added: return "clock"
        case .released: return "calendar"
        case .rating: return "star"
        }
    }
    var fields: (String, String) {
        switch self {
        case .name: return ("SortName", "Ascending")
        case .added: return ("DateCreated,SortName", "Descending")
        case .released: return ("PremiereDate,ProductionYear,SortName", "Descending")
        case .rating: return ("CommunityRating,SortName", "Descending")
        }
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unwatched, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return String(localized: "Alle", comment: "Library filter: all titles")
        case .unwatched: return String(localized: "Ungesehen", comment: "Library filter: unwatched titles")
        case .favorites: return String(localized: "Favoriten", comment: "Library filter: favourites")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .unwatched: return "eye.slash"
        case .favorites: return "heart"
        }
    }
    var filters: [String] {
        switch self {
        case .all: return []
        case .unwatched: return ["IsUnplayed"]
        case .favorites: return ["IsFavorite"]
        }
    }
}

struct LibraryScreen: View {
    let title: String
    let types: [String]
    var parentID: String?
    var personID: String?

    init(title: String, types: [String], parentID: String? = nil, personID: String? = nil) {
        self.title = title
        self.types = types
        self.parentID = parentID
        self.personID = personID
    }

    init(library: BaseItem) {
        let types: [String]
        switch library.collectionType {
        case "movies": types = ["Movie"]
        case "tvshows": types = ["Series"]
        case "boxsets": types = ["BoxSet"]
        case "homevideos", "musicvideos": types = ["Video", "MusicVideo", "Movie"]
        default:
            switch library.type {
            case "BoxSet": types = ["Movie", "Series"]
            case "Playlist": types = ["Movie", "Episode", "Video", "MusicVideo"]
            default: types = ["Movie", "Series", "Video"]
            }
        }
        self.init(title: library.name, types: types, parentID: library.id)
    }

    var body: some View {
        LibraryPosterGrid(title: title, types: types, parentID: parentID, personID: personID) { _ in EmptyView() }
    }
}

/// The paged poster grid behind libraries and people: sort, filter, empty and error states.
private struct LibraryPosterGrid<Header: View>: View {
    let title: String
    let types: [String]
    var parentID: String?
    var personID: String?
    /// People pages: a section heading above the grid instead of a large navigation title.
    var sectionTitle: String?
    var initialSort = LibrarySort.name
    @ViewBuilder let header: (LibraryLayout) -> Header

    @EnvironmentObject private var model: AppModel
    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var generation = 0
    @State private var error: String?
    @State private var sort: LibrarySort?
    @State private var filter = LibraryFilter.all
    @State private var layout = LibraryLayout(alignsWithTitle: true)
    @State private var showsInlineTitle = false

    private var activeSort: LibrarySort { sort ?? initialSort }
    private var showsControls: Bool { personID == nil }
    private var countText: String? { total > 0 ? String(localized: "\(total) Titel") : nil }

    /// As many columns as fit at the minimum card width: 3 on a phone, 6 and more in landscape and on iPad.
    private var cardWidth: CGFloat {
        let available = max(200, layout.size.width - 2 * layout.edge)
        let minimum: CGFloat = layout.isLarge ? 136 : layout.isWide ? 124 : 104
        let count = max(3, Int((available + gridSpacing) / (minimum + gridSpacing)))
        return floor((available - gridSpacing * CGFloat(count - 1)) / CGFloat(count))
    }

    private var gridSpacing: CGFloat { layout.isWide ? 18 : 12 }

    private var columns: [GridItem] {
        let count = max(1, Int((max(200, layout.size.width - 2 * layout.edge) + gridSpacing) / (cardWidth + gridSpacing)))
        return Array(repeating: GridItem(.fixed(cardWidth), spacing: gridSpacing, alignment: .top), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(layout)
                titleRow
                grid
            }
            .padding(.horizontal, layout.edge)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .measuringLayout($layout)
        .overlay {
            if !loadedOnce && error == nil { MobileLoadingView() }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(sectionTitle == nil ? .large : .inline)
        .modifier(LibraryCountSubtitle(text: sectionTitle == nil ? countText : nil))
        .toolbar {
            if sectionTitle != nil {
                ToolbarItem(placement: .principal) {
                    Text(title).font(.headline).lineLimit(1).opacity(showsInlineTitle ? 1 : 0)
                }
            }
            if showsControls {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    filterMenu
                }
            }
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 170 } action: { _, value in
            withAnimation(.easeOut(duration: 0.2)) { showsInlineTitle = value }
        }
        .refreshable { await load(reset: true) }
        .sensoryFeedback(.selection, trigger: filter)
        .sensoryFeedback(.selection, trigger: sort)
        .task(id: "\(activeSort.rawValue)-\(filter.rawValue)-\(model.refreshID)") { await load(reset: true) }
    }

    @ViewBuilder private var titleRow: some View {
        if let sectionTitle {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sectionTitle).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let countText { Text(countText).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.top, 6)
        } else if #available(iOS 26.0, *) {
            // The count sits under the large title.
        } else if let countText {
            Text(countText).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var grid: some View {
        if let error, items.isEmpty {
            MobileErrorView(message: error) { Task { await load(reset: true) } }
                .frame(maxWidth: .infinity, minHeight: layout.size.height * 0.6)
        } else if items.isEmpty && loadedOnce && !loading {
            ContentUnavailableView {
                Label(filter == .all ? "Keine Titel" : "Keine Treffer", systemImage: "film.stack")
            } description: {
                Text(filter == .all ? "Diese Bibliothek ist leer." : "Für diesen Filter gibt es keine Titel.")
            } actions: {
                if filter != .all {
                    Button("Zurücksetzen") { filter = .all }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: layout.size.height * 0.6)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: layout.isWide ? 26 : 20) {
                ForEach(items) { item in
                    PosterCard(item: item, width: cardWidth)
                        .onAppear { loadMoreIfNeeded(after: item) }
                }
            }
            if loading && !items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(24)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortieren", selection: Binding(get: { activeSort }, set: { sort = $0 })) {
                ForEach(LibrarySort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sortieren", systemImage: "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private func loadMoreIfNeeded(after item: BaseItem) {
        guard !loading, items.count < total else { return }
        guard let index = items.lastIndex(where: { $0.id == item.id }), index >= items.count - 12 else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        guard let client = model.client, let session = model.session else { return }
        if !reset && (loading || items.count >= total) { return }
        if reset { generation += 1 }
        let run = generation
        loading = true
        var query = JellyfinClient.ItemQuery(types: types, parentID: parentID, sortBy: activeSort.fields.0, sortOrder: activeSort.fields.1,
                                            filters: filter.filters, start: reset ? 0 : items.count, limit: 60)
        query.personID = personID
        do {
            let page = try await client.items(user: session.userID, query)
            guard run == generation else { return }
            if reset {
                items = page.items
            } else {
                let known = Set(items.map(\.id))
                items += page.items.filter { !known.contains($0.id) }
            }
            total = page.totalRecordCount ?? items.count
            error = nil
        } catch {
            guard run == generation else { return }
            if !libraryIsCancellation(error) { self.error = libraryErrorText(error) }
        }
        loading = false
        loadedOnce = true
    }
}

/// The artwork reaches under the navigation bar until the page scrolls past it (iOS 26 draws an edge effect there).
private struct LibraryTopEdgeEffect: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidden, for: .top)
        } else {
            content
        }
    }
}

/// "123 Titel" under the large title (iOS 26 and later; earlier versions show it above the grid).
private struct LibraryCountSubtitle: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(text ?? "")
        } else {
            content
        }
    }
}

// MARK: - Search

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var searchedTerm = ""
    @State private var searching = false
    @State private var failed = false
    @State private var layout = LibraryLayout(alignsWithTitle: true)
    @AppStorage("mobileRecentSearches") private var recentStorage = ""

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recent: [String] { recentStorage.split(separator: "\n").map(String.init) }
    private var movies: [BaseItem] { results.filter(\.isMovie) }
    private var series: [BaseItem] { results.filter(\.isSeries) }
    private var episodes: [BaseItem] { results.filter(\.isEpisode) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if term.count < 2 {
                    idleContent
                } else if results.isEmpty {
                    if failed {
                        ContentUnavailableView {
                            Label("Suche fehlgeschlagen", systemImage: "exclamationmark.magnifyingglass")
                        } actions: {
                            Button("Erneut versuchen") { Task { await search(term, debounce: false) } }.buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, minHeight: layout.size.height * 0.55)
                    } else if searching || searchedTerm != term {
                        ProgressView().frame(maxWidth: .infinity, minHeight: layout.size.height * 0.4)
                    } else {
                        ContentUnavailableView.search(text: term)
                            .frame(maxWidth: .infinity, minHeight: layout.size.height * 0.55)
                    }
                } else {
                    resultSections
                }
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background.ignoresSafeArea())
        .measuringLayout($layout)
        .navigationTitle("Suche")
        .searchable(text: $query, prompt: "Filme, Serien, Folgen")
        .onSubmit(of: .search) { remember(term) }
        .onDisappear {
            // Leaving with results on screen (usually to open one) keeps the term for next time.
            if term.count >= 2, !results.isEmpty { remember(term) }
        }
        .task(id: term) { await search(term, debounce: true) }
        #if DEBUG
        .onAppear {
            // Simulator testing only: JELLY_ROUTE=search:<term> types the term.
            if query.isEmpty, let route = ProcessInfo.processInfo.environment["JELLY_ROUTE"], route.hasPrefix("search:") {
                query = String(route.dropFirst("search:".count))
            }
        }
        #endif
    }

    @ViewBuilder private var idleContent: some View {
        if recent.isEmpty {
            ContentUnavailableView("Suche", systemImage: "magnifyingglass",
                                   description: Text("Finde Filme, Serien und Folgen in deiner Mediathek."))
                .frame(maxWidth: .infinity, minHeight: layout.size.height * 0.6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(localized: "Zuletzt gesucht", comment: "Heading above recent search terms"))
                        .font(.title3.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Löschen") { withAnimation { recentStorage = "" } }
                        .font(.subheadline)
                }
                .padding(.bottom, 6)
                ForEach(recent, id: \.self) { entry in
                    Button { query = entry } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text(entry).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, layout.edge)
        }
    }

    @ViewBuilder private var resultSections: some View {
        if !movies.isEmpty {
            LibraryShelf(title: String(localized: "Filme"), items: movies, layout: layout) { PosterCard(item: $0, width: layout.posterWidth) }
        }
        if !series.isEmpty {
            LibraryShelf(title: String(localized: "Serien"), items: series, layout: layout) { PosterCard(item: $0, width: layout.posterWidth) }
        }
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Folgen", comment: "TV episodes"))
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, layout.edge)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: layout.isWide ? 2 : 1),
                          alignment: .leading, spacing: 4) {
                    ForEach(episodes) { LibraryEpisodeTile(episode: $0, showsSeries: true, stillWidth: layout.isWide ? 170 : 132) }
                }
                .padding(.horizontal, layout.edge - 10)
            }
        }
    }

    private func search(_ term: String, debounce: Bool) async {
        guard term.count >= 2, let client = model.client, let session = model.session else {
            results = []
            failed = false
            searchedTerm = ""
            return
        }
        searching = true
        defer { if self.term == term { searching = false } }
        if debounce {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        let query = JellyfinClient.ItemQuery(types: ["Movie", "Series", "Episode"], search: term, sortBy: "SortName", limit: 60)
        do {
            let page = try await client.items(user: session.userID, query)
            guard !Task.isCancelled, self.term == term else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                results = page.items
                failed = false
                searchedTerm = term
            }
        } catch {
            guard !Task.isCancelled, !libraryIsCancellation(error), self.term == term else { return }
            results = []
            failed = true
            searchedTerm = term
        }
    }

    private func remember(_ term: String) {
        guard term.count >= 2 else { return }
        let entries = [term] + recent.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        recentStorage = entries.prefix(8).joined(separator: "\n")
    }
}

// MARK: - Detail

struct ItemDetailScreen: View {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.openMobileItem) private var openItem
    @State private var details: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [BaseItem] = []
    @State private var loadingEpisodes = false
    @State private var nextUp: BaseItem?
    @State private var similar: [BaseItem] = []
    @State private var sourceID: String?
    @State private var error: String?
    @State private var layout = LibraryLayout()
    @State private var showsTitle = false
    @State private var watchedTick = 0
    @State private var favoriteTick = 0
    @State private var seasonTick = 0

    /// A season opened from elsewhere shows its series with that season selected.
    private var seasonLink: Bool { item.type == "Season" && item.seriesId != nil }
    private var stub: BaseItem {
        guard seasonLink, let seriesID = item.seriesId else { return item }
        return BaseItem(id: seriesID, name: item.seriesName ?? item.name, type: "Series")
    }
    private var current: BaseItem { details ?? stub }
    private var source: MediaSource? {
        current.mediaSources?.first { $0.id == sourceID } ?? current.mediaSources?.first
    }
    private var wide: Bool { layout.isWide }
    /// iPad: the poster stands next to the text, reaching up into the backdrop.
    private var showsPoster: Bool { wide && headerHeight >= 380 }
    private var posterWidth: CGFloat { layout.isLarge ? 220 : 180 }
    private var textLeading: CGFloat { showsPoster ? layout.edge + posterWidth + 28 : layout.edge }

    private var headerHeight: CGFloat {
        let size = layout.size
        if wide { return min(max(size.width * 0.48, 340), size.height * 0.62) }
        return min(size.width * 1.12, size.height * 0.62)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 34) {
                        summary
                        if current.isSeries && !seasons.isEmpty { seriesEpisodes.id("episodes") }
                        if current.isEpisode && episodes.count > 1 { seasonEpisodes.id("episodes") }
                        cast.id("cast")
                        if !similar.isEmpty {
                            LibraryShelf(title: String(localized: "Das könnte dir auch gefallen"), items: similar, layout: layout) {
                                PosterCard(item: $0, width: layout.posterWidth)
                            }
                            .id("similar")
                        }
                        info.id("info")
                    }
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .modifier(LibraryTopEdgeEffect(hidden: !showsTitle))
            .libraryDebugScroll(proxy, ready: current.isSeries || current.isEpisode ? !episodes.isEmpty : details != nil)
        }
        .toolbarBackground(showsTitle ? .automatic : .hidden, for: .navigationBar)
        .background(Theme.background.ignoresSafeArea())
        .measuringLayout($layout)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > headerHeight - 110 } action: { _, value in
            withAnimation(.easeOut(duration: 0.2)) { showsTitle = value }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(current.isEpisode ? current.seriesName ?? current.name : current.name)
                    .font(.headline).lineLimit(1)
                    .opacity(showsTitle ? 1 : 0)
            }
        }
        .refreshable { await load() }
        .sensoryFeedback(.success, trigger: watchedTick)
        .sensoryFeedback(.impact(weight: .light), trigger: favoriteTick)
        .sensoryFeedback(.selection, trigger: seasonTick)
        .task(id: model.refreshID) { await load() }
        .task(id: selectedSeason) { await loadEpisodes() }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: wide ? .bottomLeading : .bottom) {
            GeometryReader { proxy in
                let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                ZStack {
                    Theme.placeholder
                    RemoteImage(url: model.client?.artworkURL(current, current.isEpisode ? .landscape : .backdrop, width: wide ? 1920 : 1280))
                }
                // Stretches when pulled down, drifts slower than the page when scrolled up.
                .frame(width: proxy.size.width, height: proxy.size.height + max(0, minY))
                .offset(y: minY > 0 ? -minY : -minY * 0.3)
            }
            .clipShape(LibraryOpenTopClip())
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.25)],
                           startPoint: .top, endPoint: .bottom)
            if wide {
                LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.65)],
                               startPoint: .leading, endPoint: .trailing)
            }
            // Last, so the artwork always ends in exactly the page colour.
            LinearGradient(stops: [.init(color: .clear, location: 0.4),
                                   .init(color: Theme.background.opacity(0.8), location: 0.8),
                                   .init(color: Theme.background, location: 0.98)],
                           startPoint: .top, endPoint: .bottom)
            headerText
                .padding(.leading, wide ? textLeading : 20)
                .padding(.trailing, wide ? layout.edge : 20)
                .padding(.bottom, wide ? 20 : 8)
        }
        .frame(height: headerHeight)
    }

    private var headerText: some View {
        VStack(alignment: wide ? .leading : .center, spacing: 10) {
            LibraryTitleArtwork(item: current, maxWidth: wide ? 420 : 270, maxHeight: wide ? 140 : 100, centered: !wide,
                         font: wide ? .largeTitle.weight(.bold) : .title.weight(.bold))
            if current.isEpisode {
                Text([current.episodeLabel, current.name].compactMap { $0 }.joined(separator: " – "))
                    .font(.headline)
                    .multilineTextAlignment(wide ? .leading : .center)
            }
            metadata
        }
        .frame(maxWidth: wide ? 720 : .infinity, alignment: wide ? .leading : .center)
    }

    private var metadata: some View {
        VStack(alignment: wide ? .leading : .center, spacing: 8) {
            HStack(spacing: 12) {
                if !current.metadataLine.isEmpty { Text(current.metadataLine) }
                LibraryRatings(item: current)
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            let badges = TechInfo.badges(source)
            if !badges.isEmpty { LibraryTechBadges(badges: badges) }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        if showsPoster {
            HStack(alignment: .top, spacing: 28) {
                ArtworkImage(item: current, style: .poster, pixelWidth: Int(posterWidth * 3))
                    .frame(width: posterWidth, height: posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .padding(.top, -(posterWidth * 1.5 - 120))
                    .accessibilityHidden(true)
                summaryText.padding(.top, 14)
            }
            .padding(.horizontal, layout.edge)
        } else {
            summaryText
                .padding(.horizontal, layout.edge)
                .padding(.top, wide ? 12 : 6)
        }
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 16) {
            actions
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if let tagline = current.taglines?.first?.nonEmpty {
                Text(tagline).font(.subheadline.italic()).foregroundStyle(.secondary)
            }
            if let overview = current.overview?.nonEmpty {
                LibraryExpandableText(text: overview, lineLimit: wide ? 5 : 4)
            }
            if let genres = current.genres, !genres.isEmpty {
                Text(genres.prefix(4).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
            }
            if details == nil && error == nil {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: wide ? 760 : .infinity, alignment: .leading)
    }

    @ViewBuilder private var actions: some View {
        let resumeItem: BaseItem? = current.isSeries ? nextUp : current
        if wide {
            HStack(spacing: 12) {
                playButtons
                iconButtons
            }
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 12) { playButtons }
                HStack(spacing: 12) {
                    if let resumeItem, let remaining = resumeItem.remainingText {
                        remainingLabel(resumeItem, remaining)
                        Spacer(minLength: 0)
                    }
                    iconButtons
                }
                .frame(maxWidth: .infinity)
            }
        }
        if wide, let resumeItem, let remaining = resumeItem.remainingText {
            remainingLabel(resumeItem, remaining)
        }
        if let sources = current.mediaSources, sources.count > 1, let name = source?.name {
            Text(String(localized: "Version \(name)")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func remainingLabel(_ item: BaseItem, _ remaining: String) -> some View {
        HStack(spacing: 8) {
            WatchProgressBar(progress: item.progress).frame(width: 64)
            Text(remaining).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var playButtons: some View {
        if current.isSeries {
            Button { playSeries() } label: { Label(seriesPlayTitle, systemImage: "play.fill") }
                .buttonStyle(LibraryCapsuleButtonStyle(prominent: true, fillsWidth: !wide))
            if let nextUp, nextUp.progress > 0 {
                Button { model.play(nextUp, fromBeginning: true) } label: { Label("Von vorn", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(LibraryCapsuleButtonStyle(prominent: false, fillsWidth: !wide))
            }
        } else if current.isPlayable {
            Button { model.play(current, mediaSourceID: sourceID) } label: {
                Label(current.progress > 0 ? "Fortsetzen" : "Abspielen", systemImage: "play.fill")
            }
            .buttonStyle(LibraryCapsuleButtonStyle(prominent: true, fillsWidth: !wide))
            if current.progress > 0 {
                Button { model.play(current, fromBeginning: true, mediaSourceID: sourceID) } label: {
                    Label("Von vorn", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(LibraryCapsuleButtonStyle(prominent: false, fillsWidth: !wide))
            }
        }
    }

    @ViewBuilder private var iconButtons: some View {
        Button { toggleWatched() } label: {
            Image(systemName: current.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(LibraryCircleButtonStyle(active: current.isWatched))
        .accessibilityLabel(current.isWatched ? "Als ungesehen markieren" : "Als gesehen markieren")
        Button { toggleFavorite() } label: {
            Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(LibraryCircleButtonStyle(active: current.isFavorite))
        .accessibilityLabel(current.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten")
        if let sources = current.mediaSources, sources.count > 1 {
            Menu {
                Picker("Version", selection: $sourceID) {
                    ForEach(sources) { Text($0.name ?? $0.id).tag(Optional($0.id)) }
                }
            } label: {
                Image(systemName: "square.stack").modifier(LibraryCircleIcon())
            }
            .accessibilityLabel("Version")
        }
        if current.isEpisode, let seriesID = current.seriesId {
            let seriesName = current.seriesName ?? String(localized: "Serie", comment: "Item type: TV series")
            Button { openItem(BaseItem(id: seriesID, name: seriesName, type: "Series")) } label: {
                Image(systemName: "tv")
            }
            .buttonStyle(LibraryCircleButtonStyle())
            .accessibilityLabel("Zur Serie")
        }
    }

    private var seriesPlayTitle: String {
        guard let nextUp else { return String(localized: "Abspielen") }
        guard let label = nextUp.episodeLabel else {
            return nextUp.progress > 0 ? String(localized: "Fortsetzen") : String(localized: "Ansehen")
        }
        return nextUp.progress > 0
            ? String(localized: "Fortsetzen \(label)", comment: "Resume <episode label, e.g. S1 · F3>")
            : String(localized: "Ansehen \(label)", comment: "Watch <episode label, e.g. S1 · F3>")
    }

    // MARK: Episodes

    private var seriesEpisodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                seasonPicker
            } else if let season = seasons.first {
                Text(season.name).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader).padding(.horizontal, layout.edge)
            }
            episodeList(emphasis: { $0.id == nextUp?.id ? .nextUp : .plain })
        }
    }

    private var seasonEpisodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.seasonName ?? String(localized: "Folgen", comment: "TV episodes"))
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, layout.edge)
            episodeList(emphasis: { $0.id == current.id ? .current : .plain })
        }
    }

    private var seasonPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        let selected = season.id == selectedSeason
                        Button {
                            seasonTick += 1
                            withAnimation(.easeOut(duration: 0.2)) { selectedSeason = season.id }
                        } label: {
                            Text(season.name)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.12)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(season.id)
                    }
                }
            }
            .contentMargins(.horizontal, layout.edge, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onAppear { if let selectedSeason { proxy.scrollTo(selectedSeason, anchor: .center) } }
            .onChange(of: selectedSeason) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder private func episodeList(emphasis: @escaping (BaseItem) -> LibraryEpisodeTile.Emphasis) -> some View {
        if episodes.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(30)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: wide ? 2 : 1),
                      alignment: .leading, spacing: 6) {
                ForEach(episodes) { episode in
                    LibraryEpisodeTile(episode: episode, emphasis: emphasis(episode), stillWidth: wide ? 180 : 150)
                }
            }
            .padding(.horizontal, layout.edge - 10)
            .opacity(loadingEpisodes ? 0.5 : 1)
            .animation(.easeOut(duration: 0.2), value: loadingEpisodes)
        }
    }

    // MARK: Cast and info

    @ViewBuilder private var cast: some View {
        let people = (current.people ?? []).filter { ["Actor", "Director", "GuestStar"].contains($0.type ?? "") }
        if !people.isEmpty {
            LibraryShelf(title: String(localized: "Besetzung & Crew"), items: Array(people.prefix(24)), layout: layout) { person in
                LibraryCastCard(person: person, size: wide ? 96 : 78)
            }
        }
    }

    @ViewBuilder private var info: some View {
        let rows = infoRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Info").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(rows, id: \.id) { row in
                        GridRow {
                            row.label.foregroundStyle(.secondary)
                            Text(row.value).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .font(.footnote)
            }
            .padding(.horizontal, layout.edge)
            .frame(maxWidth: 760 + 2 * layout.edge, alignment: .leading)
        }
    }

    /// Picture, sound, subtitles and file of the chosen version.
    private var infoRows: [(id: String, label: Text, value: String)] {
        guard current.isPlayable, let source else { return [] }
        var rows: [(id: String, label: Text, value: String)] = []
        if let video = TechInfo.videoDescription(source.video) { rows.append(("video", Text("Bild"), video)) }
        if let sound = TechInfo.audioDescription(TechInfo.defaultAudio(source))?.nonEmpty {
            let more = source.audioStreams.count > 1 ? "  +\(source.audioStreams.count - 1)" : ""
            rows.append(("audio", Text("Ton"), sound + more))
        }
        let subtitles = source.subtitleStreams.map { $0.languageName ?? $0.label }.uniqued()
        if !subtitles.isEmpty { rows.append(("subtitles", Text("Untertitel"), subtitles.prefix(8).joined(separator: ", "))) }
        let file = [JellyfinClient.fileExtension(container: source.container).uppercased(),
                    source.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    TechInfo.bitrate(source)].compactMap { $0 }.joined(separator: " · ")
        if !file.isEmpty { rows.append(("file", Text("Datei"), file)) }
        return rows
    }

    // MARK: Data

    private func load() async {
        guard let client = model.client, let session = model.session else { return }
        do {
            let full = try await client.item(user: session.userID, id: stub.id)
            details = full
            if sourceID == nil || full.mediaSources?.contains(where: { $0.id == sourceID }) != true {
                sourceID = full.mediaSources?.first?.id
            }
            error = nil
            if full.isSeries {
                async let seasonsRequest = client.seasons(user: session.userID, seriesID: full.id)
                async let nextRequest = try? client.nextUp(user: session.userID, seriesID: full.id, limit: 1)
                let seasonList = try await seasonsRequest
                let next = await nextRequest?.first
                seasons = seasonList
                nextUp = next
                if selectedSeason == nil {
                    selectedSeason = (seasonLink ? item.id : nil) ?? next?.seasonId
                        ?? seasonList.first { !$0.isWatched }?.id ?? seasonList.first?.id
                } else {
                    await loadEpisodes()
                }
            } else if full.isEpisode, let seasonID = full.seasonId {
                if selectedSeason == nil { selectedSeason = seasonID } else { await loadEpisodes() }
            }
            if similar.isEmpty, !full.isEpisode {
                similar = (try? await client.similar(user: session.userID, id: full.id)) ?? []
            }
            if let episode = full.isEpisode ? full : nextUp { await prepareIntro(episode) }
        } catch {
            if !libraryIsCancellation(error) { self.error = libraryErrorText(error) }
        }
    }

    private func loadEpisodes() async {
        guard let seasonID = selectedSeason, let client = model.client, let session = model.session else { return }
        guard let seriesID = current.isEpisode ? current.seriesId : current.id else { return }
        loadingEpisodes = true
        defer { if selectedSeason == seasonID { loadingEpisodes = false } }
        if let list = try? await client.episodes(user: session.userID, seriesID: seriesID, seasonID: seasonID), selectedSeason == seasonID {
            withAnimation(.easeOut(duration: 0.25)) { episodes = list }
        }
    }

    /// Works out the intro of the episode the play button starts while the page is open, so "Intro überspringen"
    /// is there from the first second. Only when the page stays open for a moment, not while scrolling past.
    private func prepareIntro(_ episode: BaseItem) async {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, let client = model.client, let session = model.session else { return }
        Task.detached(priority: .utility) { _ = await IntroFinder.shared.intro(for: episode, client: client, user: session.userID) }
    }

    private func playSeries() {
        if let nextUp { model.play(nextUp) } else { Task { await model.playSeries(current) } }
    }

    private func toggleWatched() {
        let watched = !current.isWatched
        if details == nil { details = stub }
        details?.userData = details?.userData ?? UserItemData()
        details?.userData?.played = watched
        watchedTick += 1
        let target = current
        Task { await model.setWatched(target, watched) }
    }

    private func toggleFavorite() {
        let favorite = !current.isFavorite
        if details == nil { details = stub }
        details?.userData = details?.userData ?? UserItemData()
        details?.userData?.isFavorite = favorite
        favoriteTick += 1
        let target = current
        Task { await model.setFavorite(target, favorite) }
    }
}

// MARK: - People

struct PersonScreen: View {
    let person: Person
    @EnvironmentObject private var model: AppModel
    @State private var details: BaseItem?

    var body: some View {
        LibraryPosterGrid(title: person.name, types: ["Movie", "Series"], personID: person.id,
                   sectionTitle: String(localized: "Bekannt aus", comment: "Titles a person is known for"),
                   initialSort: .released) { layout in
            header(layout)
        }
        .task {
            guard details == nil, let client = model.client, let session = model.session else { return }
            details = try? await client.item(user: session.userID, id: person.id)
        }
    }

    private func header(_ layout: LibraryLayout) -> some View {
        let wide = layout.isWide
        let stack = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 28)) : AnyLayout(VStackLayout(spacing: 14))
        return VStack(alignment: .leading, spacing: 16) {
            stack {
                LibraryPersonPhoto(person: person, size: wide ? 180 : 140)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                VStack(alignment: wide ? .leading : .center, spacing: 6) {
                    Text(person.name)
                        .font(wide ? .largeTitle.weight(.bold) : .title.weight(.bold))
                        .multilineTextAlignment(wide ? .leading : .center)
                        .accessibilityAddTraits(.isHeader)
                    if let role = person.role?.nonEmpty {
                        Text(role).font(.headline).foregroundStyle(.secondary).multilineTextAlignment(wide ? .leading : .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            if let biography = details?.overview?.nonEmpty {
                LibraryExpandableText(text: biography, lineLimit: wide ? 4 : 5)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .padding(.top, 12)
    }
}
