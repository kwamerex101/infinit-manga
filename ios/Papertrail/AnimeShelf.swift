import SwiftUI

private enum AnimeRoute: Hashable {
    case show(String)
    case episode(showID: String, episodeID: String)
}

struct AnimeShelf: View {
    @Environment(AnimeLibrary.self) private var library
    @Binding var mode: MediaMode

    @State private var tab = ShelfDestination.home
    @State private var tabBeforeSearch = ShelfDestination.home
    @State private var shelf = AnimeLibrary.Shelf.bookmarks
    @State private var path = NavigationPath()
    @State private var source: AnimeProvider?
    @State private var latest: [AniWatchTitle] = []
    @State private var latestFailure: SourceLoadFailure?
    @State private var latestRequest: UUID?
    @State private var refresh = 0
    @State private var websiteRefresh = 0
    @State private var activeWebsite: AnimeWebsite?

    private struct FeedRequest: Hashable {
        let enabled: Bool
        let refresh: Int
    }

    private var nativeShows: [AnimeShow] {
        AnimeCatalog.shows.filter { show in
            show.episodes.contains { episode in
                library.sources(for: episode).contains { source == nil || $0.provider == source }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ShelfNavigation(selection: $tab, destinations: [.home, .library, .settings, .search],
                            identifierPrefix: "anime-tab", showsDock: tab != .search) {
                Group {
                    switch tab {
                    case .search: AnimeSearchPage(cancel: { tab = tabBeforeSearch }, manageSources: { tab = .settings })
                    case .library: libraryPage
                    case .settings:
                        ShelfProviderSettings(title: "Anime Settings", sources: AnimeProvider.allCases,
                                              name: \.name, website: \.website,
                                              isEnabled: library.isEnabled(_:), setEnabled: library.setEnabled(_:source:))
                            .environment(\.openURL, OpenURLAction { url in
                                if url == FlixMovieCatalog.browseURL { activeWebsite = .flixMovie }
                                else if url == AniZoneCatalog.browseURL { activeWebsite = .aniZone }
                                else { return .systemAction }
                                return .handled
                            })
                    default: discover
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.papertrailBackground.ignoresSafeArea())
            .fullScreenCover(item: $activeWebsite) { website in
                InAppWebsiteBrowser(website: website, url: website.browseURL)
            }
            .onChange(of: tab) { previous, current in
                if current == .search { tabBeforeSearch = previous }
            }
            .onChange(of: library.enabledProviders) {
                if let source, !library.isEnabled(source) { self.source = nil }
            }
            .onChange(of: path.count) { ShelfHaptics.tap.play() }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: FeedRequest(enabled: library.isEnabled(.aniWatch), refresh: refresh)) {
                if library.isEnabled(.aniWatch) { await loadLatest() }
            }
            .navigationDestination(for: AnimeRoute.self) { route in
                switch route {
                case .show(let id):
                    if let show = AnimeCatalog.show(id) { AnimeShowView(show: show) }
                case .episode(let showID, let episodeID):
                    if let show = AnimeCatalog.show(showID),
                       let episode = show.episodes.first(where: { $0.id == episodeID }) {
                        AnimeEpisodeView(show: show, episode: episode)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if library.saveError {
                    Label("Anime library couldn’t be opened or saved.", systemImage: "exclamationmark.circle")
                        .font(.footnote).padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 70)
                }
            }
        }
    }

    private var discover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                MediaModeMenu(mode: $mode)
                    .zIndex(1)
                if !library.enabledProviders.isEmpty {
                    ShelfSourceFilters(sources: library.enabledProviders, selection: $source, name: \.name)
                }
                if let feature = nativeShows.first(where: { $0.id == AnimeCatalog.featured.id }) ?? nativeShows.first {
                    AnimeHero(show: feature, compact: false) {
                        AnimePrimaryAction(show: feature)
                        NavigationLink(value: AnimeRoute.show(feature.id)) {
                            Label("Details", systemImage: "info.circle")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                        }
                        .buttonStyle(ShelfPressStyle())
                        .accessibilityIdentifier("anime-featured-details")
                    }
                }
                let resumable = library.recent.filter { library.canResume($0) }
                if !resumable.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeading("Continue watching")
                        if resumable.count == 1, let recent = resumable.first {
                            AnimeRecentCard(recent: recent).shelfResumeTile()
                        } else {
                            AnimeRail {
                                ForEach(resumable.prefix(10)) { recent in
                                    AnimeRecentCard(recent: recent).frame(width: 230)
                                }
                            }
                        }
                    }
                }
                if library.isEnabled(.aniWatch), source == nil || source == .aniWatch { aniWatchRail }
                if library.isEnabled(.flixMovie), source == nil || source == .flixMovie {
                    AnimeWebsiteRail(website: .flixMovie, refresh: websiteRefresh)
                }
                if library.isEnabled(.aniZone), source == nil || source == .aniZone {
                    AnimeWebsiteRail(website: .aniZone, refresh: websiteRefresh)
                }
                if !nativeShows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeading("From the collection")
                        AnimeRail {
                            ForEach(nativeShows) { show in AnimeShowTile(show: show).frame(width: 144) }
                        }
                    }
                } else if library.enabledProviders.isEmpty {
                    ShelfStateView("No anime sources", message: "Enable a provider to browse and search.",
                                   action: .init("Manage sources") { tab = .settings })
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 28)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            websiteRefresh += 1
            if library.isEnabled(.aniWatch), source == nil || source == .aniWatch { await loadLatest() }
        }
        .shelfEntrance()
    }

    private var aniWatchRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfHeading("Latest on AniWatch")
                Spacer(minLength: 8)
                Link(destination: AniWatchCatalog.browseURL) {
                    Label("See all", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.papertrailAccent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(ShelfPressStyle())
                .accessibilityIdentifier("anime-aniwatch-browse")
            }
            if !latest.isEmpty {
                AnimeRail {
                    ForEach(latest) { show in AniWatchTile(show: show).frame(width: 126) }
                }
            } else if let latestFailure, latestRequest == nil {
                ShelfStateView(failure: latestFailure, title: "AniWatch is unavailable",
                               message: "Try again to load the latest titles.", style: .compact,
                               action: .init("Retry") { refresh += 1 })
            } else {
                AnimeRail {
                    LoadingSkeleton(label: "Loading AniWatch titles") {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                SkeletonBlock(radius: 11).frame(width: 126, height: 175)
                            }
                        }
                    }
                }
            }
        }
        .shelfAnimation(latest.map(\.id))
    }

    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfMasthead(title: "My List")
                Picker("Anime library", selection: $shelf.withSelectionFeedback()) {
                    ForEach(AnimeLibrary.Shelf.allCases) { value in
                        Text(value == .bookmarks ? "Saved" : value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                if shelf == .recent {
                    let recent = library.recent.filter { library.canResume($0) }
                    if recent.isEmpty {
                        ShelfStateView("No recent episodes", message: "Episodes you open will appear here.")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                            ForEach(recent) { AnimeRecentCard(recent: $0) }
                        }
                    }
                } else {
                    let shows = library.shows(in: shelf)
                    if shows.isEmpty {
                        ShelfStateView(shelf == .bookmarks ? "No saved shows" : "Nothing in Watch Later",
                                       message: "Open a show to save it.")
                    } else {
                        LazyVGrid(columns: animePosterColumns, spacing: 17) {
                            ForEach(shows) { item in
                                switch item {
                                case .collection(let show): AnimeShowTile(show: show)
                                case .aniWatch(let show):
                                    AniWatchTile(show: show, episode: library.lastEpisode(of: show))
                                        .disabled(!library.isEnabled(.aniWatch))
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 1040)
        }
        .shelfEntrance()
    }

    private func loadLatest() async {
        let request = UUID()
        latestRequest = request
        defer { if latestRequest == request { latestRequest = nil } }
        do {
            let result = try await AniWatchCatalog.latest()
            try Task.checkCancellation()
            guard latestRequest == request else { return }
            latest = result
            latestFailure = nil
        } catch {
            if !Task.isCancelled, latestRequest == request { latestFailure = SourceLoadFailure(error) }
        }
    }
}

private let animePosterColumns = [GridItem(.adaptive(minimum: 105, maximum: 166), spacing: 12, alignment: .top)]

private struct AnimeSearchPage: View {
    @Environment(AnimeLibrary.self) private var library
    @FocusState private var focused: Bool
    let cancel: () -> Void
    let manageSources: () -> Void

    @State private var query = ""
    @State private var submitted = ""
    @State private var source: AnimeProvider?
    @State private var aniWatch: [AniWatchTitle] = []
    @State private var flixMovie: FlixMovieCatalog.Matches?
    @State private var aniZone: [AnimeWebsiteTitle] = []
    @State private var failures: [AnimeProvider: SourceLoadFailure] = [:]
    @State private var pending = false
    @State private var retry = 0

    private struct Request: Hashable {
        let query: String
        let providers: [AnimeProvider]
        let retry: Int
    }

    private enum Result {
        case aniWatch([AniWatchTitle])
        case flixMovie(FlixMovieCatalog.Matches)
        case aniZone([AnimeWebsiteTitle])
        case failed(AnimeProvider, SourceLoadFailure)
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var scopes: [AnimeProvider] { library.enabledProviders }
    private var remoteProviders: [AnimeProvider] {
        scopes.filter { $0 != .archive && (source == nil || source == $0) }
    }
    private var request: Request { Request(query: submitted, providers: remoteProviders, retry: retry) }
    private var collection: [AnimeShow] {
        guard !submitted.isEmpty, source == nil || source == .archive else { return [] }
        return AnimeCatalog.search(submitted).filter { $0.episodes.contains { !library.sources(for: $0).isEmpty } }
    }
    private var flixMovieTitles: [FlixMovieTitle] { flixMovie?.titles ?? [] }

    var body: some View {
        ShelfSearchPage(mode: "anime", cancel: { focused = false; cancel() }) {
            if !scopes.isEmpty { ShelfSourceFilters(sources: scopes, selection: $source, name: \.name) }
        } results: {
            VStack(alignment: .leading, spacing: 16) {
                if !collection.isEmpty || !aniWatch.isEmpty || !flixMovieTitles.isEmpty || !aniZone.isEmpty {
                    LazyVGrid(columns: animePosterColumns, alignment: .leading, spacing: 17) {
                        ForEach(collection) { AnimeShowTile(show: $0) }
                        ForEach(aniWatch) { AniWatchTile(show: $0) }
                        ForEach(flixMovieTitles) { FlixMovieTile(title: $0) }
                        ForEach(aniZone) { AnimeWebsiteTile(website: .aniZone, title: $0) }
                    }
                    if pending { MangaGridSkeleton(label: "Searching anime") }
                } else if pending {
                    MangaGridSkeleton(label: "Searching anime")
                } else if failures.isEmpty {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                }

                ForEach(remoteProviders, id: \.self) { provider in
                    if let failure = failures[provider] {
                        ShelfStateView(failure: failure, title: "Couldn’t search \(provider.name)",
                                       message: "Try again to search this source.", style: .compact,
                                       action: .init("Retry", perform: submit))
                    }
                }
                if flixMovie?.catalogOnly == true || failures[.flixMovie] != nil {
                    AnimeWebsiteBrowserButton(url: FlixMovieCatalog.searchURL(submitted)) {
                        Label("Search on FlixMovie", systemImage: "safari")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(Color.papertrailAccent)
                    .accessibilityIdentifier("anime-flixmovie-search-website")
                }
            }
            .shelfAnimation(collection.map(\.id))
            .shelfAnimation(aniWatch.map(\.id))
            .shelfAnimation(flixMovieTitles.map(\.id))
            .shelfAnimation(aniZone.map(\.id))
        } searchBar: {
            ShelfSearchBar(hasQuery: !query.isEmpty, submit: submit, submitIdentifier: "anime-search-submit",
                           canSubmit: !term.isEmpty && !scopes.isEmpty, clear: { query = ""; focused = true }) {
                TextField("Show or episode title", text: $query)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submit)
                    .accessibilityIdentifier("anime-search-field")
            }
        }
        .task { if query.isEmpty { focused = true } }
        .onChange(of: query) {
            if term != submitted {
                submitted = ""
                resetResults()
            }
        }
        .onChange(of: scopes) {
            if let source, !scopes.contains(source) { self.source = nil }
        }
        .task(id: request) { await fetch(request) }
    }

    private func fetch(_ request: Request) async {
        guard !Task.isCancelled, request == self.request else { return }
        resetResults()
        guard !request.query.isEmpty, !request.providers.isEmpty else { return }
        pending = true
        await withTaskGroup(of: Result.self) { group in
            for provider in request.providers {
                group.addTask { await Self.find(request.query, on: provider) }
            }
            for await result in group {
                guard !Task.isCancelled, request == self.request else { return }
                switch result {
                case .aniWatch(let matches): aniWatch = matches
                case .flixMovie(let matches): flixMovie = matches
                case .aniZone(let matches): aniZone = matches
                case .failed(let provider, let error): failures[provider] = error
                }
            }
        }
        if !Task.isCancelled, request == self.request { pending = false }
    }

    private nonisolated static func find(_ query: String, on provider: AnimeProvider) async -> Result {
        do {
            switch provider {
            case .aniWatch: return .aniWatch(try await AniWatchCatalog.search(query))
            case .flixMovie: return .flixMovie(try await FlixMovieCatalog.search(query))
            case .aniZone: return .aniZone(try await AniZoneCatalog.search(query))
            case .archive: throw SourceFailure.unavailable
            }
        } catch {
            return .failed(provider, SourceLoadFailure(error))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if scopes.isEmpty {
            ShelfStateView("No anime sources", message: "Enable a provider to search for anime.",
                           action: .init("Manage sources") { focused = false; manageSources() })
        } else if submitted.isEmpty {
            ShelfStateView("Find an anime", message: "Search for a show or episode.")
        } else if flixMovie?.catalogOnly == true {
            ShelfStateView("No matching titles", message: "Try another title or search the full catalog on FlixMovie.")
        } else {
            ShelfStateView("No matching anime", message: "Try another title or change the source filter.",
                           action: .init("Edit search") { focused = true })
        }
    }

    private func resetResults() {
        aniWatch = []
        flixMovie = nil
        aniZone = []
        failures = [:]
        pending = false
    }

    private func submit() {
        guard !term.isEmpty && !scopes.isEmpty else { return }
        ShelfHaptics.tap.play()
        focused = false
        resetResults()
        pending = !remoteProviders.isEmpty
        submitted = term
        retry += 1
    }
}

private struct AnimeRail<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                content()
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollIndicators(.hidden)
    }
}

private struct AnimeArtwork: View {
    let url: URL?
    let aspect: CGFloat
    var size = 650

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.papertrailPanel
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                GeometryReader { frame in
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else if url != nil, !failed {
                            LoadingSkeleton(label: "Loading artwork") { SkeletonBlock(radius: 0) }
                        } else {
                            Image(systemName: "play.rectangle").font(.title2)
                                .foregroundStyle(Color.papertrailDetail)
                        }
                    }
                    .frame(width: frame.size.width, height: frame.size.height)
                    .clipped()
                }
            }
            .shelfAnimation(image != nil)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .task(id: url) {
                image = nil
                failed = false
                guard let url else { return }
                do {
                    let artwork = try await Artwork.cover(at: url, size: size)
                    try Task.checkCancellation()
                    image = artwork
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }
}

private struct AnimePosterTile: View {
    let title: String
    let detail: String
    let artwork: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AnimeArtwork(url: artwork, aspect: 0.72)
                .clipShape(.rect(cornerRadius: 11))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Text(detail).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AnimeShowTile: View {
    let show: AnimeShow

    var body: some View {
        NavigationLink(value: AnimeRoute.show(show.id)) {
            AnimePosterTile(title: show.title, detail: show.studio, artwork: show.artwork)
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityIdentifier("anime-show-\(show.id)")
    }
}

private struct AniWatchTile: View {
    let show: AniWatchTitle
    var episode: AniWatchEpisode? = nil

    var body: some View {
        AniWatchLaunchButton(show: show, episode: episode) {
            AnimePosterTile(title: show.title, detail: show.format.isEmpty ? "AniWatch" : "\(show.format) · AniWatch",
                           artwork: show.artwork)
        }
        .accessibilityHint("Opens the in-app player")
        .accessibilityIdentifier("anime-aniwatch-\(show.id)")
    }
}

private struct AnimeWebsiteRail: View {
    let website: AnimeWebsite
    let refresh: Int
    @State private var titles: [AnimeWebsiteTitle] = []
    @State private var loading = true
    @State private var failure: SourceLoadFailure?
    @State private var retry = 0

    private struct Request: Hashable {
        let refresh: Int
        let retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfHeading(website == .flixMovie ? "Popular animation" : "Latest on AniZone")
                Spacer(minLength: 8)
                AnimeWebsiteBrowserButton(website: website, url: website.browseURL) {
                    Label("See all", systemImage: "safari")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.papertrailAccent)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Browse all \(website.name) animation")
                .accessibilityIdentifier("anime-\(website.id)-browse")
            }
            if !titles.isEmpty {
                AnimeRail {
                    ForEach(titles) { title in AnimeWebsiteTile(website: website, title: title).frame(width: 126) }
                }
            } else if let failure {
                ShelfStateView(failure: failure, title: "\(website.name) is unavailable",
                               message: "Try again to load the animation catalog.", style: .compact,
                               action: .init("Retry") { retry += 1 })
            } else if loading {
                AnimeRail {
                    LoadingSkeleton(label: "Loading \(website.name) animation") {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                SkeletonBlock(radius: 11).frame(width: 126, height: 175)
                            }
                        }
                    }
                }
            }
        }
        .shelfAnimation(titles.map(\.id))
        .task(id: Request(refresh: refresh, retry: retry)) {
            failure = nil
            loading = true
            do {
                let result = try await website.homeTitles()
                try Task.checkCancellation()
                titles = result
                loading = false
            } catch {
                if !Task.isCancelled { failure = SourceLoadFailure(error) }
            }
        }
    }
}

private struct FlixMovieTile: View {
    let title: FlixMovieTitle

    var body: some View {
        AnimeWebsiteTile(website: .flixMovie, title: AnimeWebsiteTitle(title))
    }
}

private struct AnimeWebsiteTile: View {
    let website: AnimeWebsite
    let title: AnimeWebsiteTitle
    @State private var playing = false

    var body: some View {
        if website == .aniZone, let selection = AniZoneCatalog.selection(title.url) {
            Button {
                ShelfHaptics.tap.play()
                playing = true
            } label: {
                poster
            }
            .buttonStyle(ShelfPressStyle())
            .accessibilityHint("Opens the AniZone player")
            .accessibilityIdentifier("anime-\(website.id)-\(title.id)")
            .fullScreenCover(isPresented: $playing) {
                AniZonePlayer(title: title, series: selection.series, episode: selection.episode)
            }
        } else {
            AnimeWebsiteBrowserButton(website: website, url: title.url) { poster }
                .accessibilityHint("Opens \(website.name) in the app’s browser")
                .accessibilityIdentifier("anime-\(website.id)-\(title.id)")
        }
    }

    private var poster: some View {
        AnimePosterTile(title: title.title, detail: "\(title.detail) · \(website.name)", artwork: title.artwork)
    }
}

private struct AnimeHero<Actions: View>: View {
    let show: AnimeShow
    let compact: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { frame in
                AnimeArtwork(url: show.artwork, aspect: frame.size.width / max(1, frame.size.height), size: 1500)
            }
            .allowsHitTesting(false)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black.opacity(0.17), location: 0.33),
                                   .init(color: .black.opacity(0.87), location: 0.78),
                                   .init(color: .black.opacity(0.96), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 8) {
                Text(show.studio)
                    .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                Text(show.title)
                    .font(.largeTitle.weight(.heavy)).tracking(-1)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                if !compact {
                    Text(show.synopsis)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.88))
                        .lineLimit(3)
                        .frame(maxWidth: 380, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions() }
                    VStack(alignment: .leading, spacing: 6) { actions() }
                }
                .padding(.top, 4)
                .foregroundStyle(.white)
            }
            .padding(18)
        }
        .frame(minHeight: compact ? 252 : 324)
        .containerRelativeFrame(.vertical) { height, _ in
            let fraction = compact ? 0.40 : 0.49
            return min(compact ? 305 : 420, max(compact ? 252 : 324, height * fraction))
        }
        .clipShape(.rect(cornerRadius: compact ? 15 : 22))
        .overlay { RoundedRectangle(cornerRadius: compact ? 15 : 22).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false) }
    }
}

private struct AnimeRecentCard: View {
    @Environment(AnimeLibrary.self) private var library
    let recent: AnimeLibrary.Recent

    var body: some View {
        if let watch = recent.aniWatch {
            AniWatchLaunchButton(show: watch.show, episode: watch.episode) {
                card(title: watch.show.title, episode: watch.episode.label, artwork: watch.show.artwork,
                     position: library.position(for: watch.episode), progress: recent.duration)
            }
            .accessibilityIdentifier("anime-recent-\(recent.episodeID)")
        } else if let show = AnimeCatalog.show(recent.showID),
           let episode = show.episodes.first(where: { $0.id == recent.episodeID }),
           let source = episode.sources.first(where: { $0.id == recent.sourceID }) {
            AnimeLaunchButton(show: show, episode: episode, source: source) {
                card(title: show.title, episode: episode.displayNumber, artwork: show.artwork,
                     position: library.position(for: episode, source: source), progress: recent.duration)
            }
            .contextMenu {
                NavigationLink(value: AnimeRoute.episode(showID: show.id, episodeID: episode.id)) {
                    Label("Episode details", systemImage: "info.circle")
                }
            }
            .accessibilityIdentifier("anime-recent-\(episode.id)")
        }
    }

    private func card(title: String, episode: String, artwork: URL?, position: Double, progress duration: Double?) -> some View {
        let progress = duration.flatMap { $0.isFinite && $0 > 0 && position > 0 ? min(1, position / $0) : nil }
        return VStack(alignment: .leading, spacing: 7) {
            AnimeArtwork(url: artwork, aspect: 16 / 9)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.black)
                        .frame(width: 36, height: 36).background(.white, in: Circle())
                        .padding(9)
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { frame in
                            Color.papertrailAccent.frame(width: frame.size.width * progress)
                        }
                        .frame(height: 3)
                        .background(.black.opacity(0.4))
                    }
                }
                .clipShape(.rect(cornerRadius: 11))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            let time = position >= 1 ? " · \(AnimePlaybackTime.label(position))" : ""
            Text(episode + time).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Resume watching")
    }
}

private struct AnimeShowView: View {
    @Environment(AnimeLibrary.self) private var library
    let show: AnimeShow
    @State private var selection: String?
    @State private var episodeQuery = ""

    private var season: AnimeSeason? {
        show.seasons.first { $0.id == selection } ?? show.seasons.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                AnimeHero(show: show, compact: true) { AnimePrimaryAction(show: show) }
                Text(show.synopsis).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: 530, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { saveActions }
                    VStack(alignment: .leading, spacing: 8) { saveActions }
                }
                if let season {
                    HStack {
                        ShelfHeading("Episodes")
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(show.seasons) { item in
                                Button(item.title, systemImage: item.id == season.id ? "checkmark" : "") {
                                    guard selection != item.id else { return }
                                    selection = item.id
                                    ShelfHaptics.selection.play()
                                }
                            }
                        } label: {
                            Label(season.title, systemImage: "chevron.down")
                                .labelStyle(.titleAndIcon)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 10).frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("anime-season-picker")
                    }
                    ShelfListSearch(prompt: "Episode number or title", identifier: "anime-episode-search", query: $episodeQuery)
                    let query = ShelfListQuery(episodeQuery)
                    let results = query.isEmpty ? season.episodes : show.episodes.filter {
                        query.matches(number: $0.number.map(String.init), title: $0.title, label: $0.displayNumber)
                    }
                    if results.isEmpty {
                        ShelfStateView("No matching episodes", message: "Try a different number or title.", style: .compact)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { episode in episodeRow(episode) }
                        }
                        .shelfAnimation(season.id)
                    }
                }
                Link(destination: show.officialPage) {
                    Label("Official show page", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
            .padding(18)
            .frame(maxWidth: 730)
            .frame(maxWidth: .infinity)
        }
        .background(Color.papertrailBackground.ignoresSafeArea())
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            guard selection == nil, let recent = library.recent.first(where: { $0.showID == show.id }) else { return }
            selection = show.seasons.first(where: { $0.episodes.contains { $0.id == recent.episodeID } })?.id
        }
        .shelfEntrance()
    }

    private func episodeRow(_ episode: AnimeEpisode) -> some View {
        NavigationLink(value: AnimeRoute.episode(showID: show.id, episodeID: episode.id)) {
            HStack(spacing: 12) {
                AnimeArtwork(url: show.artwork, aspect: 16 / 9)
                    .frame(width: 112)
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                            .accessibilityHidden(true)
                    }
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.displayNumber).font(.caption.weight(.semibold)).foregroundStyle(Color.papertrailDetail)
                    Text(episode.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityIdentifier("anime-episode-\(episode.id)")
    }

    @ViewBuilder
    private var saveActions: some View {
        saveButton(.bookmarks, name: "Save to My List", savedName: "In My List", icon: "bookmark")
        saveButton(.later, name: "Watch Later", savedName: "In Watch Later", icon: "heart")
    }

    private func saveButton(_ shelf: AnimeLibrary.Shelf, name: String, savedName: String, icon: String) -> some View {
        let saved = library.contains(show, in: shelf)
        return Button(saved ? savedName : name, systemImage: saved ? "\(icon).fill" : icon) {
            library.toggle(show, in: shelf)
            (saved ? ShelfHaptics.selection : .success).play()
        }
        .buttonStyle(.bordered)
        .shelfAnimation(saved, animation: ShelfMotion.feedback)
        .accessibilityIdentifier(shelf == .bookmarks ? "anime-bookmark" : "anime-watch-later")
    }
}

private struct AnimePrimaryAction: View {
    @Environment(AnimeLibrary.self) private var library
    let show: AnimeShow

    private var target: (episode: AnimeEpisode, source: AnimeSource)? {
        for entry in library.recent where entry.showID == show.id {
            if let episode = show.episodes.first(where: { $0.id == entry.episodeID }),
               let source = library.sources(for: episode).first(where: { $0.id == entry.sourceID }) {
                return (episode, source)
            }
        }
        for episode in show.episodes {
            if let source = library.sources(for: episode).first { return (episode, source) }
        }
        return nil
    }

    var body: some View {
        if let target {
            let position = library.position(for: target.episode, source: target.source)
            let label = position >= 1 ? "Resume" : "Play"
            AnimeLaunchButton(show: show, episode: target.episode, source: target.source) {
                Label(label, systemImage: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 17).frame(minHeight: 44)
                    .foregroundStyle(.black)
                    .background(.white, in: .rect(cornerRadius: 9))
            }
            .accessibilityIdentifier("anime-quick-play")
        }
    }
}

private struct AnimeEpisodeView: View {
    @Environment(AnimeLibrary.self) private var library
    let show: AnimeShow
    let episode: AnimeEpisode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                AnimeArtwork(url: show.artwork, aspect: 16 / 9)
                    .clipShape(.rect(cornerRadius: 15))
                Text("\(show.title) · \(episode.displayNumber)").font(.subheadline).foregroundStyle(.secondary)
                Text(episode.title).font(.largeTitle.bold()).tracking(-0.65)
                let sources = library.sources(for: episode)
                if sources.isEmpty {
                    ShelfStateView("No enabled sources", message: "Enable a provider in Anime Settings to play this episode.")
                } else {
                    ShelfHeading("Where to watch").padding(.top, 5)
                    ForEach(sources) { source in
                        AnimeLaunchButton(show: show, episode: episode, source: source) {
                            sourceRow(source)
                        }
                        .accessibilityIdentifier("anime-source-\(source.id)")
                    }
                }
                if let credits = episode.credits {
                    Link("Credits and license", destination: credits).font(.footnote).frame(minHeight: 44)
                }
            }
            .padding(18)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color.papertrailBackground.ignoresSafeArea())
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func sourceRow(_ source: AnimeSource) -> some View {
        let seconds = library.position(for: episode, source: source)
        let detail = seconds >= 1 ? "Resume at \(AnimePlaybackTime.label(seconds))" : "Play in app"
        return HStack(spacing: 12) {
            Image(systemName: "play.circle")
                .foregroundStyle(Color.papertrailDetail).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .modifier(ShelfSurface(radius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct AnimeLaunchButton<Content: View>: View {
    let show: AnimeShow
    let episode: AnimeEpisode
    let source: AnimeSource
    @ViewBuilder let content: () -> Content

    @State private var playing = false

    var body: some View {
        Button {
            ShelfHaptics.tap.play()
            playing = true
        } label: { content() }
        .buttonStyle(ShelfPressStyle())
        .fullScreenCover(isPresented: $playing) {
            AnimePlayer(show: show, episode: episode, source: source)
        }
    }
}
