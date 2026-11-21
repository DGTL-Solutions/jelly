import Foundation

/// New episodes of one series the profile is watching.
struct NewEpisodes: Identifiable, Equatable {
    let id: String
    let series: String
    let episodes: [BaseItem]
}

/// "Neue Folge ist da": remembers the newest episodes on the server and notices when more arrive for a series the
/// profile is in the middle of. Nothing is reported the first time it looks.
enum EpisodeWatcher {
    private static func key(_ profileKey: String) -> String { "episodes:\(profileKey)" }

    /// The episodes at the head of the server's newest-first list that weren't there last time. Everything from the
    /// first known one on is old – also episodes that only moved up because newer ones were deleted.
    static func fresh(_ latest: [BaseItem], known: Set<String>) -> [BaseItem] {
        Array(latest.prefix { !known.contains($0.id) })
    }

    /// The fresh episodes worth telling about: unwatched ones of series in progress, grouped by series, in the
    /// order they'd be watched.
    static func news(_ fresh: [BaseItem], watching: Set<String>) -> [NewEpisodes] {
        var order: [String] = [], groups: [String: [BaseItem]] = [:]
        for episode in fresh where !episode.isWatched {
            guard let series = episode.seriesId, watching.contains(series) else { continue }
            if groups[series] == nil { order.append(series) }
            groups[series, default: []].append(episode)
        }
        return order.map { series in
            let episodes = groups[series]!.sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) }
            return NewEpisodes(id: series, series: episodes.first?.seriesName ?? "", episodes: episodes)
        }
    }

    static func check(client: JellyfinClient, session: Session) async -> [NewEpisodes] {
        let query = JellyfinClient.ItemQuery(types: ["Episode"], sortBy: "DateCreated", sortOrder: "Descending", limit: 60)
        guard let latest = try? await client.items(user: session.userID, query).items, !latest.isEmpty else { return [] }
        let defaults = UserDefaults.standard
        let known = defaults.stringArray(forKey: key(session.key))
        defaults.set(latest.map(\.id), forKey: key(session.key))
        guard let known else { return [] }
        let fresh = fresh(latest, known: Set(known))
        guard !fresh.isEmpty else { return [] }
        async let nextUp = try? client.nextUp(user: session.userID, limit: 60)
        async let resume = try? client.resume(user: session.userID, limit: 30)
        let watching = Set(((await nextUp ?? []) + (await resume ?? [])).compactMap(\.seriesId))
        return news(fresh, watching: watching)
    }
}
