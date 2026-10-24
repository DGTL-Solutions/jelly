import SwiftUI

struct ItemDetailView: View {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.openItem) private var openItem
    @State private var details: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [BaseItem] = []
    @State private var nextUp: BaseItem?
    @State private var similar: [BaseItem] = []
    @State private var sourceID: String?
    @State private var error: String?
    @State private var showsOverview = false
    @State private var scrolled = false
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case play }

    private var current: BaseItem { details ?? item }
    private var source: MediaSource? {
        current.mediaSources?.first { $0.id == sourceID } ?? current.mediaSources?.first
    }

    var body: some View {
        ZStack {
            BackdropView(item: current, receded: scrolled)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 64) {
                        header
                            .containerRelativeFrame(.vertical, alignment: .bottomLeading)
                        if current.isSeries && !seasons.isEmpty { episodesSection.id("episodes") }
                        if let people = current.people?.filter({ ["Actor", "Director", "GuestStar"].contains($0.type ?? "") }), !people.isEmpty {
                            Shelf(title: String(localized: "Besetzung & Crew"), items: Array(people.prefix(24)), spacing: 44) { PersonCard(person: $0) }
                        }
                        if !similar.isEmpty {
                            Shelf(title: String(localized: "Das könnte dir auch gefallen"), items: similar) { MediaCard(item: $0, style: .poster, width: 230) }
                        }
                    }
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
                .ignoresSafeArea(edges: .horizontal)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 240 } action: { _, value in scrolled = value }
                #if DEBUG
                .onChange(of: episodes.isEmpty) { _, empty in
                    if !empty, ProcessInfo.processInfo.environment["JELLY_SCROLL_EPISODES"] != nil { proxy.scrollTo("episodes", anchor: .top) }
                }
                #endif
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .defaultFocus($focus, .play)
        .sheet(isPresented: $showsOverview) { OverviewSheet(item: current) }
        .task(id: model.refreshID) { await load() }
        .task(id: selectedSeason) { await loadEpisodes() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            TitleLogo(item: current)
            if current.isEpisode {
                Text([current.episodeLabel, current.name].compactMap { $0 }.joined(separator: " – "))
                    .font(.title3.weight(.semibold))
            }
            HStack(spacing: 22) {
                if !current.metadataLine.isEmpty { Text(current.metadataLine) }
                RatingBadges(item: current)
                TechBadges(badges: TechInfo.badges(source))
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.8))
            if let genres = current.genres, !genres.isEmpty {
                Text(genres.prefix(4).joined(separator: " · ")).font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            if let overview = current.overview, !overview.isEmpty {
                Button { showsOverview = true } label: {
                    Text(overview).font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                        .foregroundStyle(.white.opacity(0.85)).frame(maxWidth: 1000, alignment: .leading)
                }
                .buttonStyle(OverviewButtonStyle())
            }
            actions.padding(.top, 12)
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        }
        .padding(.leading, Theme.edge)
        .padding(.trailing, 600)
        .padding(.bottom, 70)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 26) {
            if current.isSeries {
                Button { playSeries() } label: {
                    Label(seriesPlayTitle, systemImage: "play.fill")
                }
                .focused($focus, equals: .play)
            } else {
                Button { model.play(current, mediaSourceID: sourceID) } label: {
                    Label(current.progress > 0 ? "Fortsetzen" : "Abspielen", systemImage: "play.fill")
                }
                .focused($focus, equals: .play)
                if current.progress > 0 {
                    Button { model.play(current, fromBeginning: true, mediaSourceID: sourceID) } label: {
                        Label("Von vorn", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            Button { toggleWatched() } label: {
                Image(systemName: current.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(current.isWatched ? "Als ungesehen markieren" : "Als gesehen markieren")
            Button { toggleFavorite() } label: {
                Image(systemName: current.isFavorite ? "heart.fill" : "heart")
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel(current.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten")
            if let sources = current.mediaSources, sources.count > 1 {
                Menu {
                    Picker("Version", selection: $sourceID) {
                        ForEach(sources) { Text($0.name ?? $0.id).tag(Optional($0.id)) }
                    }
                } label: { Label("Version", systemImage: "square.stack") }
            }
            if current.isEpisode, let seriesID = current.seriesId {
                let seriesName = current.seriesName ?? String(localized: "Serie", comment: "Item type: TV series")
                Button { openItem(BaseItem(id: seriesID, name: seriesName, type: "Series")) } label: {
                    Label("Zur Serie", systemImage: "tv")
                }
            }
        }
        if !current.isSeries, let remaining = current.remainingText {
            Text(remaining).font(.caption).foregroundStyle(.secondary)
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

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(seasons) { season in
                        Button { selectedSeason = season.id } label: { Text(season.name) }
                            .buttonStyle(PillButtonStyle(selected: season.id == selectedSeason))
                    }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .focusSection()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(episodes) { EpisodeCard(episode: $0).id($0.id) }
                    }
                    .padding(.horizontal, Theme.edge)
                    .padding(.vertical, 26)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .focusSection()
                .onChange(of: episodes) {
                    if let target = episodes.first(where: { $0.id == nextUp?.id }) ?? episodes.first(where: { !$0.isWatched }) {
                        proxy.scrollTo(target.id, anchor: .leading)
                    }
                }
            }
            .frame(minHeight: 420)
        }
    }

    // MARK: Data

    private func load() async {
        guard let client = model.client, let session = model.session else { return }
        do {
            let full = try await client.item(user: session.userID, id: item.id)
            details = full
            if sourceID == nil { sourceID = full.mediaSources?.first?.id }
            error = nil
            if full.isSeries {
                async let seasonsRequest = client.seasons(user: session.userID, seriesID: full.id)
                async let nextRequest = try? client.nextUp(user: session.userID, seriesID: full.id, limit: 1)
                seasons = try await seasonsRequest
                nextUp = await nextRequest?.first
                if selectedSeason == nil {
                    selectedSeason = nextUp?.seasonId ?? seasons.first { !$0.isWatched }?.id ?? seasons.first?.id
                } else {
                    await loadEpisodes()
                }
            }
            if similar.isEmpty, !full.isEpisode {
                similar = (try? await client.similar(user: session.userID, id: full.id)) ?? []
            }
            if let episode = full.isEpisode ? full : nextUp { await prepareIntro(episode) }
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadEpisodes() async {
        guard let seasonID = selectedSeason, let client = model.client, let session = model.session else { return }
        let seriesID = details?.id ?? item.id
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
        details?.userData = details?.userData ?? UserItemData()
        details?.userData?.played = watched
        Task { await model.setWatched(current, watched) }
    }

    private func toggleFavorite() {
        let favorite = !current.isFavorite
        details?.userData = details?.userData ?? UserItemData()
        details?.userData?.isFavorite = favorite
        Task { await model.setFavorite(current, favorite) }
    }
}

struct EpisodeCard: View {
    let episode: BaseItem
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.play(episode) } label: {
                ItemArtwork(item: episode, style: .landscape, pixelWidth: 900)
                    .frame(width: 440, height: 248)
                    .cardDecorations(episode)
            }
            .buttonStyle(.card)
            .focused($focused)
            .contextMenu { ItemActions(item: episode) }
            VStack(alignment: .leading, spacing: 6) {
                Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                if let overview = episode.overview {
                    Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(episode.remainingText ?? episode.runtimeText ?? "").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, focused ? 26 : 14)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
        .frame(width: 440, alignment: .leading)
    }
}

struct PersonCard: View {
    let person: Person
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            NavigationLink(value: Route.person(person)) {
                ZStack {
                    Theme.placeholder
                    Text(initials).font(.system(size: 54, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                    if let tag = person.primaryImageTag {
                        RemoteImage(url: model.client?.imageURL(item: person.id, kind: .primary, tag: tag, width: 360))
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            .buttonBorderShape(.circle)
            .focused($focused)
            VStack(spacing: 4) {
                Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(person.role?.nonEmpty ?? roleName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 200)
            .offset(y: focused ? 10 : 0)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var roleName: String {
        ["Director": String(localized: "Regie", comment: "Crew role: director"),
         "Writer": String(localized: "Drehbuch", comment: "Crew role: writer"),
         "Producer": String(localized: "Produktion", comment: "Crew role: producer")][person.type ?? ""] ?? ""
    }
}

struct PillButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, selected: selected) }

    private struct PillBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 30).padding(.vertical, 14)
                .foregroundStyle(focused ? .black : selected ? .white : .white.opacity(0.65))
                .background(Capsule().fill(focused ? .white : selected ? .white.opacity(0.22) : .clear))
                .scaleEffect(focused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

struct OverviewButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Highlight(configuration: configuration) }
    private struct Highlight: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(focused ? 0.14 : 0)))
                .padding(-18)
                .scaleEffect(focused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

struct OverviewSheet: View {
    let item: BaseItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(item.name).font(.title2.weight(.bold))
                if let tagline = item.taglines?.first { Text(tagline).font(.title3).italic().foregroundStyle(.secondary) }
                Text(item.overview ?? "").font(.body)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(60)
        }
        .focusable()
    }
}

extension View {
    /// Progress bar and watched/unplayed badges on artwork.
    func cardDecorations(_ item: BaseItem) -> some View {
        overlay(alignment: .bottom) {
            if item.progress > 0.01, !item.isWatched {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.45))
                        Capsule().fill(.white).frame(width: proxy.size.width * item.progress)
                    }
                }
                .frame(height: 7)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .padding(10)
                    .background(Theme.accent, in: Circle())
                    .padding(12)
            } else if let unplayed = item.userData?.unplayedItemCount, unplayed > 0, item.isSeries {
                Text("\(unplayed)")
                    .font(.system(size: 20, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
                    .padding(12)
            }
        }
    }
}
