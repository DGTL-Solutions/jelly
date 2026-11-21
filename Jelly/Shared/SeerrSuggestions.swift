import SwiftUI

/// One card in "Das könnte dir auch gefallen": a title from the library, or one Jellyseerr can fetch.
enum Suggestion: Identifiable, Hashable {
    case library(BaseItem)
    case wish(SeerrClient.Title)

    var id: String {
        switch self {
        case .library(let item): "library-\(item.id)"
        case .wish(let title): "wish-\(title.id)"
        }
    }

    /// The library's own suggestions first, then what could be added.
    static func row(_ library: [BaseItem], _ wishes: [SeerrClient.Title]) -> [Suggestion] {
        library.map(Suggestion.library) + wishes.map(Suggestion.wish)
    }
}

/// One card in "Fehlt noch aus …": a film of the series that can be wished for, or all of them at once.
enum MissingPart: Identifiable, Hashable {
    case title(SeerrClient.Title)
    case all(Int)

    var id: String {
        switch self {
        case .title(let title): title.id
        case .all: "all"
        }
    }

    /// The films, and – when more than one can still be wished for – a card that wishes for all of them.
    static func row(_ parts: [SeerrClient.Title]) -> [MissingPart] {
        let open = parts.filter { $0.status == .none }.count
        return parts.map(MissingPart.title) + (open > 1 ? [.all(open)] : [])
    }
}

/// Optional (Einstellungen › Jellyseerr, off by default): the pages of films, series and people also show what isn't
/// on the server yet – suggestions, the rest of a film series, a person's other work –, each one a wish away from
/// being downloaded.
@MainActor
enum SeerrSuggestions {
    static let settingKey = "seerrSuggestions"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Jellyseerr's suggestions for a film or series of the library; empty when the setting is off, no Jellyseerr is
    /// connected, in a kids profile (wishing is behind the PIN there) or the title has no TMDB number.
    static func load(for item: BaseItem, model: AppModel) async -> [SeerrClient.Title] {
        guard item.isMovie || item.isSeries, let tmdbID = item.tmdbID else { return [] }
        return await ask("suggestions for \(tmdbID)", model: model) { try await $0.suggestions(tmdbID: tmdbID, series: item.isSeries) } ?? []
    }

    /// The films still missing from the series a library film belongs to, with the series' name.
    static func missingParts(for item: BaseItem, model: AppModel) async -> (name: String, parts: [SeerrClient.Title])? {
        guard item.isMovie, let tmdbID = item.tmdbID else { return nil }
        return await ask("collection of \(tmdbID)", model: model) { try await $0.missingParts(ofMovie: tmdbID) } ?? nil
    }

    /// What a person of the library is known for and the library doesn't have.
    static func missingCredits(for person: BaseItem, model: AppModel) async -> [SeerrClient.Title] {
        guard let tmdbID = person.tmdbID else { return [] }
        return await ask("credits of \(tmdbID)", model: model) { try await $0.missingCredits(person: tmdbID) } ?? []
    }

    /// One question to Jellyseerr, if the setting is on, a Jellyseerr is connected and this isn't a kids profile.
    private static func ask<Answer>(_ what: String, model: AppModel, _ question: (SeerrClient) async throws -> Answer) async -> Answer? {
        guard isOn, !model.isKids, let account = model.seerr else { return nil }
        do {
            return try await question(account.client)
        } catch SeerrError.signedOut {
            Diagnostics.log("jellyseerr session expired")
            await model.disconnectSeerr(expired: true)
        } catch {
            Diagnostics.log("jellyseerr \(what): \(error)")
        }
        return nil
    }

    /// Wishes for every title of a row that isn't wished for yet, one after the other; returns the row in its new state.
    static func wishAll(_ titles: [SeerrClient.Title], model: AppModel) async -> [SeerrClient.Title] {
        var result = titles
        for (index, title) in titles.enumerated() where title.status == .none {
            if let wished = await wish(title, model: model) { result[index] = wished }
        }
        return result
    }

    /// Wishes for a title straight from its card. Returns the title in its new state, or `nil` when Jellyseerr refused –
    /// the title's own page then says why.
    static func wish(_ title: SeerrClient.Title, model: AppModel) async -> SeerrClient.Title? {
        guard let account = model.seerr, let result = try? await account.client.requestAll(title) else { return nil }
        Diagnostics.log("jellyseerr request \(title.id) status=\(result) from suggestions")
        var wished = title
        var info = wished.mediaInfo ?? SeerrClient.MediaInfo()
        info.status = result == 2 ? 3 : 2
        wished.mediaInfo = info
        return wished
    }
}
