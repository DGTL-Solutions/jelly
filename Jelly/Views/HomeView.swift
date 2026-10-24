import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var idle = IdleMonitor.shared
    @State private var debugAnalysis = false
    @State private var tab = Int(ProcessInfo.processInfo.environment["JELLY_TAB"] ?? "") ?? 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house", value: 0) { BrowseStack { HomeView() } }
            Tab("Filme", systemImage: "film", value: 1) { BrowseStack { LibraryGridView(title: String(localized: "Filme"), types: ["Movie"]) } }
            Tab("Serien", systemImage: "tv", value: 2) { BrowseStack { LibraryGridView(title: String(localized: "Serien"), types: ["Series"]) } }
            Tab("Erkunden", systemImage: "sparkles", value: 5) { DiscoverView() }
            Tab("Suche", systemImage: "magnifyingglass", value: 3, role: .search) { BrowseStack { SearchView() } }
            Tab("Einstellungen", systemImage: "gearshape", value: 4) { SettingsView() }
        }
        .onChange(of: model.pendingOpen) { _, item in if item != nil { tab = 0 } }
        .fullScreenCover(isPresented: $idle.screensaverActive) { CoverWallView().environmentObject(model) }
        .fullScreenCover(isPresented: $debugAnalysis) { ConnectionAnalysisView(autoStart: true).environmentObject(model) }
        .task(id: model.session?.key) {
            await model.preferHomeNetwork()
            await model.refreshAccount()
            #if DEBUG
            await model.runDebugActions()
            if ProcessInfo.processInfo.environment["JELLY_ANALYSIS"] != nil { debugAnalysis = true }
            if ProcessInfo.processInfo.environment["JELLY_SCREENSAVER"] != nil {
                try? await Task.sleep(for: .seconds(3))
                idle.activate()
            }
            #endif
        }
    }
}

struct LatestRow: Identifiable {
    let library: BaseItem
    let items: [BaseItem]
    var id: String { library.id }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openItem) private var openItem
    @State private var featured: [BaseItem] = []
    @State private var resume: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var libraries: [BaseItem] = []
    @State private var latest: [LatestRow] = []
    @State private var favorites: [BaseItem] = []
    @State private var collections: [BaseItem] = []
    @State private var playlists: [BaseItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error, !loaded {
                ErrorView(message: error) { Task { await load() } }
            } else if !loaded {
                LoadingView(text: String(localized: "Deine Mediathek wird geladen …"))
            } else if featured.isEmpty && resume.isEmpty && latest.isEmpty {
                ContentUnavailableView("Noch keine Inhalte", systemImage: "film.stack",
                                       description: Text("Sobald dein Server Filme oder Serien enthält, erscheinen sie hier."))
            } else {
                content
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: model.refreshID) { await load() }
        .onChange(of: model.pendingOpen) { _, item in
            if let item { openItem(item); model.pendingOpen = nil }
        }
    }

    private var content: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 56) {
                if !featured.isEmpty { HeroCarousel(items: featured) }
                if !resume.isEmpty {
                    Shelf(title: String(localized: "Weiterschauen"), items: resume) { item in
                        MediaCard(item: item, style: .landscape, width: 460) { model.play(item) }
                    }
                }
                if !nextUp.isEmpty {
                    Shelf(title: String(localized: "Nächste Folgen"), items: nextUp) { item in
                        MediaCard(item: item, style: .landscape, width: 460) { model.play(item) }
                    }
                }
                ForEach(latest) { row in
                    let title = String(localized: "Neu in \(row.library.name)", comment: "Shelf: recently added to <library name>")
                    Shelf(title: title, items: row.items) { item in
                        MediaCard(item: item, style: .poster, width: 250)
                    }
                }
                if !favorites.isEmpty {
                    Shelf(title: String(localized: "Favoriten"), items: favorites) { item in
                        MediaCard(item: item, style: .poster, width: 250)
                    }
                }
                if !collections.isEmpty {
                    Shelf(title: String(localized: "Sammlungen", comment: "Movie collections (box sets)"), items: collections) { item in
                        MediaCard(item: item, style: .poster, width: 250)
                    }
                }
                if !playlists.isEmpty {
                    Shelf(title: String(localized: "Playlists"), items: playlists) { item in
                        MediaCard(item: item, style: .landscape, width: 460)
                    }
                }
                if libraries.count > 1 {
                    Shelf(title: String(localized: "Bibliotheken"), items: libraries) { library in
                        MediaCard(item: library, style: .landscape, width: 460)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .horizontal])
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
            if !loaded { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func fetch(_ client: JellyfinClient, user: String) async throws {
        do {
            async let viewsRequest = client.views(user: user)
            async let resumeRequest = try? client.resume(user: user)
            async let nextUpRequest = try? client.nextUp(user: user)
            async let favoritesRequest = try? client.items(user: user, .init(types: ["Movie", "Series", "Episode"], sortBy: "SortName", filters: ["IsFavorite"], limit: 30))
            async let collectionsRequest = try? client.items(user: user, .init(types: ["BoxSet"], sortBy: "SortName", limit: 30))
            async let playlistsRequest = try? client.items(user: user, .init(types: ["Playlist"], sortBy: "SortName", limit: 30))
            let views = try await viewsRequest.filter { ["movies", "tvshows", "homevideos", "musicvideos", "boxsets", nil].contains($0.collectionType) }
            let rows = await withTaskGroup(of: (Int, LatestRow?).self) { group in
                for (index, library) in views.enumerated() where library.collectionType != "boxsets" {
                    group.addTask {
                        let items = (try? await client.latest(user: user, parentID: library.id)) ?? []
                        return (index, items.isEmpty ? nil : LatestRow(library: library, items: items))
                    }
                }
                var rows: [(Int, LatestRow)] = []
                for await (index, row) in group { if let row { rows.append((index, row)) } }
                return rows.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let resume = await resumeRequest ?? []
            let nextUp = await nextUpRequest ?? []
            let favorites = await favoritesRequest?.items ?? []
            let collections = await collectionsRequest?.items ?? []
            let playlists = await playlistsRequest?.items ?? []
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
    }

    private static func pickFeatured(_ rows: [LatestRow]) -> [BaseItem] {
        let candidates = rows.flatMap(\.items).filter { ($0.backdropImageTags?.isEmpty == false) && ($0.isMovie || $0.isSeries) }
        let fresh = candidates.filter { !$0.isWatched }
        return Array((fresh.count >= 3 ? fresh : candidates).prefix(12).shuffled().prefix(6))
    }
}

/// Full-bleed featured titles. Moving focus right from the last button pages to the next title.
struct HeroCarousel: View {
    let items: [BaseItem]
    @EnvironmentObject private var model: AppModel
    @State private var page: String?
    @FocusState private var focused: HeroButton?

    struct HeroButton: Hashable { let item: String; let primary: Bool }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
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
        .frame(height: 900)
        .overlay(alignment: .bottomTrailing) { pageDots.padding(.trailing, Theme.edge).padding(.bottom, 70) }
        .focusSection()
        .onChange(of: focused) { _, value in
            guard let value, value.item != page else { return }
            withAnimation(.easeInOut(duration: 0.45)) { page = value.item }
        }
        .task(id: focused == nil) {
            // Rotate automatically while the viewer is looking at the rows below.
            guard focused == nil, items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled, focused == nil else { return }
                let index = items.firstIndex { $0.id == page } ?? 0
                withAnimation(.easeInOut(duration: 0.8)) { page = items[(index + 1) % items.count].id }
            }
        }
    }

    private func slide(_ item: BaseItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.client?.artworkURL(item, .backdrop, width: 1920))
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.2), location: 0.6), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: Theme.background, location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 22) {
                TitleLogo(item: item, maxWidth: 620, maxHeight: 210)
                HStack(spacing: 22) {
                    Text(item.metadataLine)
                    RatingBadges(item: item)
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                if let overview = item.overview {
                    Text(overview).font(.callout).lineLimit(3).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: 900, alignment: .leading)
                }
                HStack(spacing: 28) {
                    Button {
                        if item.isSeries { Task { await model.playSeries(item) } } else { model.play(item) }
                    } label: {
                        Label(item.isSeries ? "Ansehen" : item.progress > 0 ? "Fortsetzen" : "Abspielen", systemImage: "play.fill")
                    }
                    .focused($focused, equals: HeroButton(item: item.id, primary: true))
                    HeroDetailsButton(item: item)
                        .focused($focused, equals: HeroButton(item: item.id, primary: false))
                }
                .padding(.top, 10)
            }
            .padding(.leading, Theme.edge + 20)
            .padding(.bottom, 90)
        }
        .clipped()
    }

    private var pageDots: some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                Capsule()
                    .fill(.white.opacity(item.id == (page ?? items.first?.id) ? 0.95 : 0.3))
                    .frame(width: item.id == (page ?? items.first?.id) ? 34 : 12, height: 12)
            }
        }
        .animation(.easeOut, value: page)
    }
}

private struct HeroDetailsButton: View {
    let item: BaseItem
    @Environment(\.openItem) private var openItem
    var body: some View {
        Button { openItem(item) } label: { Label("Details", systemImage: "info.circle") }
    }
}

extension AppModel {
    /// Plays the next unwatched episode of a series, or its first episode.
    func playSeries(_ series: BaseItem) async {
        guard let client, let session else { return }
        if let next = try? await client.nextUp(user: session.userID, seriesID: series.id, limit: 1).first {
            play(next)
        } else if let first = try? await client.episodes(user: session.userID, seriesID: series.id).first {
            play(first)
        }
    }
}
