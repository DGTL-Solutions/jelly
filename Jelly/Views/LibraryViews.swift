import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, added, released, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .added: return "Zuletzt hinzugefügt"
        case .released: return "Erscheinungsdatum"
        case .rating: return "Bewertung"
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

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unwatched, favorites
    var id: String { rawValue }
    var title: String { ["all": "Alle", "unwatched": "Ungesehen", "favorites": "Favoriten"][rawValue]! }
    var filters: [String] { ["all": [], "unwatched": ["IsUnplayed"], "favorites": ["IsFavorite"]][rawValue]! }
}

struct LibraryGridView: View {
    let title: String
    let types: [String]
    var parentID: String?
    var personID: String?
    var header: AnyView?

    @EnvironmentObject private var model: AppModel
    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var sort = LibrarySort.name
    @State private var filter = LibraryFilter.all

    private let columns = Array(repeating: GridItem(.fixed(250), spacing: 50, alignment: .top), count: 6)

    init(title: String, types: [String], parentID: String? = nil, personID: String? = nil, header: AnyView? = nil) {
        self.title = title
        self.types = types
        self.parentID = parentID
        self.personID = personID
        self.header = header
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
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let header { header }
                HStack(alignment: .firstTextBaseline, spacing: 30) {
                    Text(title).font(.title2.weight(.bold))
                    if total > 0 { Text("\(total) Titel").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    if personID == nil {
                        Menu {
                            Picker("Sortieren", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.title).tag($0) } }
                        } label: { Label(sort.title, systemImage: "arrow.up.arrow.down") }
                        Menu {
                            Picker("Filter", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) } }
                        } label: { Label(filter.title, systemImage: "line.3.horizontal.decrease") }
                    }
                }
                .focusSection()

                if let error, items.isEmpty {
                    ErrorView(message: error) { Task { await load(reset: true) } }
                } else if items.isEmpty && !loading {
                    ContentUnavailableView(filter == .all ? "Keine Titel" : "Keine Treffer", systemImage: "film.stack",
                                           description: Text(filter == .all ? "Diese Bibliothek ist leer." : "Für diesen Filter gibt es keine Titel."))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                        ForEach(items) { item in
                            MediaCard(item: item, style: .poster, width: 250)
                                .onAppear { if item.id == items.last?.id { Task { await load(reset: false) } } }
                        }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.background.ignoresSafeArea())
        .task(id: "\(sort.rawValue)-\(filter.rawValue)-\(model.refreshID)") { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard let client = model.client, let session = model.session else { return }
        if !reset && (loading || items.count >= total) { return }
        loading = true
        defer { loading = false }
        var query = JellyfinClient.ItemQuery(types: types, parentID: parentID, sortBy: sort.fields.0, sortOrder: sort.fields.1,
                                            filters: filter.filters, start: reset ? 0 : items.count, limit: 60)
        query.personID = personID
        do {
            let page = try await client.items(user: session.userID, query)
            if reset { items = page.items } else { items += page.items.filter { new in !items.contains { $0.id == new.id } } }
            total = page.totalRecordCount ?? items.count
            error = nil
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var searching = false

    private var movies: [BaseItem] { results.filter(\.isMovie) }
    private var series: [BaseItem] { results.filter(\.isSeries) }
    private var episodes: [BaseItem] { results.filter(\.isEpisode) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if query.isEmpty {
                    ContentUnavailableView("Suche", systemImage: "magnifyingglass",
                                           description: Text("Finde Filme, Serien und Folgen in deiner Mediathek."))
                        .padding(.top, 120)
                } else if results.isEmpty && !searching {
                    ContentUnavailableView.search(text: query).padding(.top, 120)
                }
                if !movies.isEmpty { Shelf(title: "Filme", items: movies) { MediaCard(item: $0, style: .poster, width: 230) } }
                if !series.isEmpty { Shelf(title: "Serien", items: series) { MediaCard(item: $0, style: .poster, width: 230) } }
                if !episodes.isEmpty {
                    Shelf(title: "Folgen", items: episodes) { episode in
                        MediaCard(item: episode, style: .landscape, width: 420) { model.play(episode) }
                    }
                }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .searchable(text: $query, prompt: "Filme, Serien, Folgen")
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2, let client = model.client, let session = model.session else { results = []; return }
            searching = true
            defer { searching = false }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let query = JellyfinClient.ItemQuery(types: ["Movie", "Series", "Episode"], search: term, sortBy: "SortName", limit: 60)
            if let page = try? await client.items(user: session.userID, query), !Task.isCancelled {
                withAnimation { results = page.items }
            }
        }
    }
}

struct PersonView: View {
    let person: Person
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LibraryGridView(title: "Bekannt aus", types: ["Movie", "Series"], personID: person.id, header: AnyView(header))
    }

    private var header: some View {
        HStack(spacing: 50) {
            ZStack {
                Circle().fill(Theme.placeholder)
                Image(systemName: "person.fill").font(.system(size: 80)).foregroundStyle(.white.opacity(0.3))
                if let tag = person.primaryImageTag {
                    RemoteImage(url: model.client?.imageURL(item: person.id, kind: .primary, tag: tag, width: 500)).clipShape(Circle())
                }
            }
            .frame(width: 240, height: 240)
            VStack(alignment: .leading, spacing: 12) {
                Text(person.name).font(.system(size: 60, weight: .bold))
                if let role = person.role, !role.isEmpty { Text(role).font(.title3).foregroundStyle(.secondary) }
            }
        }
        .padding(.top, 20)
    }
}
