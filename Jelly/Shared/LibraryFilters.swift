import SwiftUI

/// Several library filters at once: "Komödien, ungesehen, ab 2010, mindestens 7 Sterne".
struct LibraryFilters: Equatable {
    var unwatched = false
    var favorites = false
    var genres: Set<String> = []
    /// First year of the decade, e.g. 1990.
    var decade: Int?
    var minRating: Int?

    var isEmpty: Bool { self == LibraryFilters() }
    var count: Int { (unwatched ? 1 : 0) + (favorites ? 1 : 0) + genres.count + (decade == nil ? 0 : 1) + (minRating == nil ? 0 : 1) }
    /// Changes whenever the filters do, for `task(id:)`.
    var key: String { "\(unwatched)-\(favorites)-\(genres.sorted().joined(separator: "|"))-\(decade ?? 0)-\(minRating ?? 0)" }

    func apply(to query: inout JellyfinClient.ItemQuery) {
        query.filters = (unwatched ? ["IsUnplayed"] : []) + (favorites ? ["IsFavorite"] : [])
        query.genres = genres.sorted()
        query.years = decade.map { Array($0..<$0 + 10) } ?? []
        query.minRating = minRating
    }

    static let decades = Array(stride(from: 2020, through: 1950, by: -10))
    static let ratings = [8, 7, 6, 5]
}

/// The filter menu of a library on Apple TV, iPhone and iPad: toggles and submenus, nothing to open and close.
struct LibraryFilterMenu: View {
    @Binding var filters: LibraryFilters
    let genres: [String]

    var body: some View {
        Menu {
            Toggle(isOn: $filters.unwatched) { Label("Ungesehen", systemImage: "eye.slash") }
            Toggle(isOn: $filters.favorites) { Label("Favoriten", systemImage: "heart") }
            if !genres.isEmpty {
                Menu {
                    ForEach(genres, id: \.self) { genre in
                        Toggle(genre, isOn: Binding(get: { filters.genres.contains(genre) },
                                                    set: { if $0 { filters.genres.insert(genre) } else { filters.genres.remove(genre) } }))
                    }
                } label: {
                    Label(filters.genres.isEmpty ? String(localized: "Genre") : filters.genres.sorted().joined(separator: ", "), systemImage: "theatermasks")
                }
                #if os(iOS)
                .menuActionDismissBehavior(.disabled)
                #endif
            }
            Menu {
                Picker("Jahrzehnt", selection: $filters.decade) {
                    Text("Alle", comment: "Library filter: all titles").tag(Int?.none)
                    ForEach(LibraryFilters.decades, id: \.self) { Text(verbatim: "\($0)–\($0 + 9)").tag(Int?.some($0)) }
                }
            } label: {
                Label(filters.decade.map { "\($0)–\($0 + 9)" } ?? String(localized: "Jahrzehnt"), systemImage: "calendar")
            }
            Menu {
                Picker("Bewertung", selection: $filters.minRating) {
                    Text("Alle", comment: "Library filter: all titles").tag(Int?.none)
                    ForEach(LibraryFilters.ratings, id: \.self) { Text("ab \($0)", comment: "Library filter: rating at least N").tag(Int?.some($0)) }
                }
            } label: {
                Label(filters.minRating.map { String(localized: "ab \($0)", comment: "Library filter: rating at least N") } ?? String(localized: "Bewertung", comment: "Library sort order: by rating"),
                      systemImage: "star")
            }
            if !filters.isEmpty {
                Button(role: .destructive) { filters = LibraryFilters() } label: { Label("Zurücksetzen", systemImage: "xmark.circle") }
            }
        } label: {
            Label(filters.isEmpty ? String(localized: "Filter") : String(localized: "Filter (\(filters.count))"),
                  systemImage: filters.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}
