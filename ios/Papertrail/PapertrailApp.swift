import SwiftUI
import UIKit

@main
struct PapertrailApp: App {
    @UIApplicationDelegateAdaptor(ChapterNotificationDelegate.self) private var notificationDelegate
    @State private var library = ReadingStore()
    @State private var comicLibrary = ComicLibrary()
    @State private var comicDownloads = ComicDownloadStore()
    @State private var novelLibrary = NovelLibrary()
    @State private var animeLibrary = AnimeLibrary()
    @State private var novelAgent = NovelAgent()
    @State private var mangaAgent = MangaAgent()
    @AppStorage("media-mode") private var mediaMode = MediaMode.manga
    @AppStorage("novel-appearance") private var novelAppearance = AppAppearance.dark
    @State private var chapterAlerts = ChapterAlerts.shared
    @AppStorage("app-appearance") private var appearance = AppAppearance.dark
    @AppStorage("walkthrough-step") private var walkthroughStep: Int?

    init() {
        _ = CacheStorage.locations
    }

    private var firstLaunchStep: WalkthroughStep {
        if let walkthroughStep, let step = WalkthroughStep(rawValue: walkthroughStep) { return step }
        let existingPreferences = ["app-appearance", "reading-layout", "reading-direction", "chapters-unread-only"]
        let savedPreferences = Bundle.main.bundleIdentifier.flatMap {
            UserDefaults.standard.persistentDomain(forName: $0)
        }
        let isReturningReader = library.hadLibraryFile || existingPreferences.contains {
            savedPreferences?[$0] != nil
        }
        return isReturningReader ? .complete : .discover
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if firstLaunchStep == .complete {
                    switch mediaMode {
                    case .novel:
                        NovelShelf(mode: $mediaMode, appearance: $novelAppearance, agent: novelAgent)
                            .environment(novelLibrary)
                    case .comics:
                        ComicShelf(mode: $mediaMode)
                            .environment(comicLibrary)
                            .environment(comicDownloads)
                    case .anime:
                        AnimeShelf(mode: $mediaMode)
                            .environment(animeLibrary)
                    case .manga:
                        ShelfView(appearance: $appearance, mode: $mediaMode, mangaAgent: mangaAgent)
                    }
                } else {
                    FirstLaunchWalkthrough(step: firstLaunchStep) { next in
                        walkthroughStep = next.rawValue
                    }
                }
            }
                .modifier(LaunchIntro())
                .background(Color.papertrailBackground.ignoresSafeArea())
                .environment(library)
                .environment(chapterAlerts)
                .tint(.papertrailAccent)
                .preferredColorScheme((mediaMode == .novel ? novelAppearance : appearance).colorScheme)
                .environment(\.openURL, OpenURLAction { _ in
                    ShelfHaptics.tap.play()
                    return .systemAction
                })
                .onChange(of: chapterAlerts.pendingChapter, initial: true) {
                    if chapterAlerts.pendingChapter != nil { mediaMode = .manga }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    SourceMemory.removeAll()
                }
        }
        .backgroundTask(.appRefresh(ChapterAlerts.refreshID)) {
            await chapterAlerts.refresh(library)
        }
    }

}

struct ShelfView: View {
    @Environment(ReadingStore.self) private var library
    @Environment(ChapterAlerts.self) private var chapterAlerts
    @Environment(\.scenePhase) private var scenePhase
    @Binding var appearance: AppAppearance
    @Binding var mode: MediaMode
    let mangaAgent: MangaAgent
    @State private var path = NavigationPath()
    @State private var tab = ShelfDestination.home
    @State private var tabBeforeSearch = ShelfDestination.home
    @State private var catalogs: [ReadingSource: Catalog] = [:]
    @State private var feedFailures: [ReadingSource: SourceLoadFailure] = [:]
    @State private var latestUpdates: [Manga] = []
    @State private var nextUpdatePages: [ReadingSource: Int] = [:]
    @State private var loadedFeed: FeedRequest?
    @State private var loadingMoreUpdates = false
    @State private var pageFailures: [ReadingSource: SourceLoadFailure] = [:]
    @State private var filter: ReadingSource?
    @State private var comixPage: ComixPage?
    @State private var librarySection = LibrarySection.saved
    @State private var savedUpdates = SavedChapterUpdates()
    @State private var loadingUpdates = false
    @State private var reload = 0
    @State private var forceFeedRefresh = false
    @State private var query = ""
    @State private var searchRequest: SearchRequest?
    @State private var searchResults: [ReadingSource: [Manga]]?
    @State private var searchIssue: SearchIssue?
    @State private var searching = false
    @State private var pendingSearch: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var activeSources: [ReadingSource] {
        let sources = library.enabledSources
        if let filter, sources.contains(filter) { return [filter] }
        return sources
    }

    private struct ComixPage: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private enum LibrarySection: String, CaseIterable {
        case saved = "Saved"
        case readLater = "Read Later"
        case recent = "Recent"
    }

    private var feedRequest: FeedRequest { FeedRequest(sources: activeSources, revision: reload) }

    private struct FeedRequest: Equatable {
        let sources: [ReadingSource]
        let revision: Int
    }

    private struct AlertCheck: Equatable {
        let active: Bool
        let enabled: Bool
        let bookmarks: [String]
        let sources: [ReadingSource]
    }

    private struct SearchRequest: Equatable {
        let term: String
        let sources: [ReadingSource]
    }

    private enum SearchIssue: Equatable {
        case invalidLink, unsupportedWebsite, missingSources
        case sources(SourceLoadFailure, incomplete: Bool)
    }

    var body: some View {
        NavigationStack(path: $path) {
            appShell
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $comixPage) { page in
                InAppWebsiteBrowser(site: .comix, url: page.url)
            }
            .onChange(of: tab) { previous, current in
                if current == .search {
                    tabBeforeSearch = previous
                }
            }
            .onChange(of: path.count) { ShelfHaptics.tap.play() }
            .onChange(of: chapterAlerts.pendingChapter, initial: true) {
                if let chapter = chapterAlerts.takePendingChapter() { path.append(chapter) }
            }
            .onChange(of: query) { clearSearchResults() }
            .onChange(of: activeSources) {
                if tab == .search, !term.isEmpty {
                    submit()
                } else {
                    clearSearchResults()
                }
            }
            .onChange(of: library.enabledSources) {
                if let filter, !library.enabledSources.contains(filter) { self.filter = nil }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active { reload += 1 }
            }
            .task(id: feedRequest) {
                let request = feedRequest
                let refresh = forceFeedRefresh
                forceFeedRefresh = false
                await loadCatalog(request, refresh: refresh)
            }
            .task(id: AlertCheck(active: scenePhase == .active, enabled: chapterAlerts.enabled,
                                 bookmarks: library.bookmarks.map(\.id), sources: library.enabledSources)) {
                if scenePhase == .active { await chapterAlerts.refresh(library) }
            }
            .navigationDestination(for: Manga.self) { manga in
                SeriesView(manga: manga) { path.append($0) }
            }
            .navigationDestination(for: Chapter.self) { chapter in
                ReaderScreen(chapter: chapter)
            }
            .overlay(alignment: .bottom) {
                if library.saveError {
                    Label("Local library data could not be saved or opened.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .padding(12)
                        .background(.regularMaterial, in: Capsule())
                        .padding()
                        .transition(.opacity)
                }
            }
            .shelfAnimation(library.saveError)
        }
        .environment(savedUpdates)
    }

    private var appShell: some View {
        ShelfNavigation(selection: $tab, showsDock: tab != .search, inlineDock: tab == .agent) {
            tabs
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house", value: .home) { discover.toolbar(.hidden, for: .tabBar) }
                Tab("Library", systemImage: "books.vertical", value: .library) { shelf.toolbar(.hidden, for: .tabBar) }
                Tab("Agent", systemImage: "bubble.left.and.text.bubble.right", value: .agent) {
                    agentPage.toolbar(.hidden, for: .tabBar)
                }
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    SourceSettings(appearance: $appearance).toolbar(.hidden, for: .tabBar)
                }
                Tab(value: .search, role: .search) { searchPage }
            }
        } else {
            TabView(selection: $tab) {
                discover.toolbar(.hidden, for: .tabBar).tabItem { Label("Home", systemImage: "house") }.tag(ShelfDestination.home)
                shelf.toolbar(.hidden, for: .tabBar).tabItem { Label("Library", systemImage: "books.vertical") }.tag(ShelfDestination.library)
                agentPage
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("Agent", systemImage: "bubble.left.and.text.bubble.right") }
                    .tag(ShelfDestination.agent)
                SourceSettings(appearance: $appearance)
                    .toolbar(.hidden, for: .tabBar)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(ShelfDestination.settings)
                searchPage.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(ShelfDestination.search)
            }
        }
    }

    private var agentPage: some View {
        MangaAgentView(agent: mangaAgent)
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchBar: some View {
        ShelfSearchBar(hasQuery: !query.isEmpty, submit: { submit(feedback: true) },
                       canSubmit: !term.isEmpty, clear: {
            query = ""
            searchFocused = true
        }) {
            TextField("Title or chapter link", text: $query)
                .accessibilityIdentifier("manga-search-field")
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { submit(feedback: true) }
        }
    }

    private var discover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                MediaModeMenu(mode: $mode)
                RecentShelf(showEmpty: true)
                if library.hasComix {
                    Button {
                        ShelfHaptics.tap.play()
                        comixPage = ComixPage(url: InAppWebsite.comixURL)
                    } label: {
                        HStack(spacing: 10) {
                            ShelfIcon(name: "globe")
                            Text("Browse Comix").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                    .modifier(ShelfSurface())
                    .accessibilityIdentifier("manga-browse-comix")
                }
                if !library.hasComix || !library.enabledSources.isEmpty { updates }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .background(Color.papertrailBackground)
        .refreshable { refreshFeed() }
        .shelfEntrance()
    }

    private var sourceFilters: some View {
        ShelfSourceFilters(sources: library.enabledSources, selection: $filter, name: \.name)
    }

    private var updates: some View {
        let sources = activeSources
        let items = loadedFeed?.sources == sources ? latestUpdates : []
        let failure = SourceLoadFailure.combined(sources.compactMap { feedFailures[$0] })
        let hasCatalog = sources.contains { catalogs[$0] != nil }
        return VStack(alignment: .leading, spacing: 6) {
            ShelfHeading("Latest updates")
            if library.enabledSources.count > 1 { sourceFilters }
            if library.enabledSources.isEmpty {
                ShelfStateView("No streaming sources",
                               message: "Add a source to see new chapters.",
                               style: .compact, action: .init("Manage sources") { tab = .settings })
            } else if !items.isEmpty {
                MangaGrid(items: items, showSource: true, loadMore: { await loadMoreUpdates() })
                moreUpdatesFooter
                if !loadingUpdates, let failure {
                    ShelfStateView(failure: failure, title: "Some updates couldn’t refresh",
                                   message: "Try again to refresh the remaining sources.",
                                   offlineMessage: "Reconnect to refresh your sources.",
                                   style: .compact, action: .init("Retry", perform: refreshFeed))
                }
            } else if loadingUpdates || (!hasCatalog && failure == nil) {
                MangaGridSkeleton(label: "Loading latest updates")
            } else if let failure {
                ShelfStateView(failure: failure, title: "Updates unavailable",
                               message: "The selected sources couldn’t load the latest chapters.",
                               style: .compact, action: .init("Retry", perform: refreshFeed))
            } else {
                ShelfStateView("No recent updates",
                               message: "Try another source or search for a title.", style: .compact)
            }
        }
        .shelfAnimation(loadingUpdates)
        .shelfAnimation(feedFailures)
        .shelfAnimation(activeSources)
    }

    @ViewBuilder
    private var moreUpdatesFooter: some View {
        if loadingMoreUpdates {
            SkeletonLine(label: "Loading more updates")
                .frame(maxWidth: .infinity, minHeight: 44)
        } else if let failure = SourceLoadFailure.combined(activeSources.compactMap { pageFailures[$0] }) {
            ShelfStateView(failure: failure, title: "Couldn’t load more updates",
                           message: "Try again to continue browsing.", style: .compact,
                           action: .init("Retry") { Task { await loadMoreUpdates(retry: true) } })
        } else if !loadingUpdates && !nextUpdatePages.isEmpty {
            Button("Load more updates") { Task { await loadMoreUpdates() } }
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var searchPage: some View {
        let results = activeSources.flatMap { searchResults?[$0] ?? [] }
        return ShelfSearchPage(mode: "manga", cancel: cancelSearch) {
            if library.enabledSources.count > 1 { sourceFilters }
        } results: {
            VStack(alignment: .leading, spacing: 13) {
                if !results.isEmpty {
                    MangaGrid(items: results, showSource: true)
                    if let searchIssue { searchState(searchIssue, compact: true) }
                } else if searching {
                    MangaGridSkeleton(label: "Searching manga")
                } else {
                    Spacer(minLength: 0)
                    searchState(searchIssue, compact: false)
                    Spacer(minLength: 0)
                }
            }
            .shelfAnimation(results.map(\.id))
            .shelfAnimation(searching)
            .shelfAnimation(searchIssue)
        } searchBar: {
            searchBar
        }
        .task(id: tab) {
            if tab == .search, term.isEmpty { searchFocused = true }
        }
    }

    @ViewBuilder
    private func searchState(_ issue: SearchIssue?, compact: Bool) -> some View {
        let editSearch = ShelfStateView.Action("Edit search") { searchFocused = true }
        switch issue {
        case .invalidLink:
            ShelfStateView("Use a series or chapter link",
                           message: "Copy the address from the series or chapter page.",
                           action: editSearch)
        case .unsupportedWebsite:
            ShelfStateView("Unsupported website",
                           message: "Paste a series or chapter link from a supported source.",
                           action: editSearch)
        case .missingSources where library.hasComix:
            ShelfStateView("Search on Comix",
                           message: "Open Comix to search its catalog.",
                           action: .init("Open Comix") { comixPage = ComixPage(url: InAppWebsite.comixURL) })
        case .missingSources:
            ShelfStateView("No streaming sources",
                           message: "Add a source to search by title.",
                           action: .init("Manage sources") { tab = .settings })
        case .sources(let failure, let incomplete):
            ShelfStateView(failure: failure, title: incomplete ? "Search incomplete" : "Search unavailable",
                           message: incomplete ? "Some sources couldn’t finish searching." : "The selected sources couldn’t finish the search.",
                           style: compact ? .compact : .standard, action: .init("Retry") { submit() })
        case nil where searchResults != nil:
            ShelfStateView("No matches",
                           message: "Try a different title or change the source filter.", action: editSearch)
        case nil:
            ShelfStateView("Find a manga",
                           message: "Search by title or paste a series or chapter link.")
        }
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfMasthead(title: "Library")
                Picker("Library view", selection: $librarySection.withSelectionFeedback()) {
                    ForEach(LibrarySection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440, alignment: .leading)

                switch librarySection {
                case .saved:
                    if library.bookmarks.isEmpty {
                        ShelfStateView("No bookmarks yet",
                                       message: "Bookmark a series to find it here.",
                                       action: .init("Browse manga") { tab = .home })
                    } else {
                        savedMangaGrid
                            .task(id: library.bookmarks.map(\.id)) {
                                await savedUpdates.refresh(library.bookmarks)
                            }
                    }
                case .readLater:
                    if library.readLater.isEmpty {
                        ShelfStateView("Nothing in Read Later",
                                       message: "Tap the heart on a manga to save it for later.",
                                       action: .init("Browse manga") { tab = .home })
                    } else {
                        MangaGrid(items: library.readLater, showSource: true)
                    }
                case .recent:
                    if library.recent.isEmpty {
                        ShelfStateView("No recent chapters",
                                       message: "Open a chapter to see it here.",
                                       action: .init("Browse manga") { tab = .home })
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 255), spacing: 10)], spacing: 10) {
                            ForEach(library.recent) { item in RecentReadingLink(item: item) }
                        }
                    }
                }
            }
            .shelfAnimation(librarySection)
            .shelfAnimation(library.bookmarks.map(\.id))
            .shelfAnimation(library.readLater.map(\.id))
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .background(Color.papertrailBackground)
        .shelfEntrance()
        .refreshable { await savedUpdates.refresh(library.bookmarks, force: true) }
    }

    private var savedMangaGrid: some View {
        let rows = library.bookmarks.enumerated().map { index, manga in
            let snapshot = savedUpdates.entries[manga.id]
            let status: SavedChapterUpdates.TitleState
            if let snapshot {
                status = snapshot.chapterKeys.allSatisfy { key in
                    library.isChapterRead(key) || snapshot.alternateKeys?[key]?.contains(where: library.isChapterRead) == true
                } ? .caughtUp : .unread
            } else {
                status = .unknown
            }
            return (manga: manga, index: index, status: status, latest: snapshot?.latestRelease ?? .distantPast)
        }.sorted {
            if $0.status != $1.status { return $0.status.sortOrder < $1.status.sortOrder }
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.index < $1.index
        }
        return MangaGrid(items: rows.map(\.manga), showSource: true,
                         titleStates: Dictionary(uniqueKeysWithValues: rows.map { ($0.manga.id, $0.status) }))
    }

    private func refreshFeed() {
        forceFeedRefresh = true
        reload += 1
    }

    private func loadCatalog(_ request: FeedRequest, refresh: Bool) async {
        guard request == feedRequest else { return }
        loadingUpdates = !request.sources.isEmpty
        loadingMoreUpdates = false
        feedFailures = [:]
        pageFailures = [:]
        let results = await fetchCatalogs(request.sources.map { ($0, nil) }, refresh: refresh)
        guard !Task.isCancelled, request == feedRequest else { return }
        var didRefresh = false
        for (source, result) in results {
            switch result {
            case .success(let catalog):
                catalogs[source] = catalog
                didRefresh = true
            case .failure(let failure):
                feedFailures[source] = failure
            }
        }
        if didRefresh || loadedFeed?.sources != request.sources {
            latestUpdates = Catalog.merged(request.sources.compactMap { catalogs[$0] }).latest
            nextUpdatePages = Dictionary(uniqueKeysWithValues: request.sources.compactMap { source in
                catalogs[source]?.nextPage.map { (source, $0) }
            })
        }
        loadedFeed = request
        loadingUpdates = false
    }

    private func loadMoreUpdates(retry: Bool = false) async {
        let request = feedRequest
        guard loadedFeed == request, !loadingUpdates, !loadingMoreUpdates else { return }
        if retry { pageFailures = [:] }
        loadingMoreUpdates = true
        defer { if loadedFeed == request { loadingMoreUpdates = false } }
        for _ in 0..<3 {
            let pages: [(ReadingSource, Int?)] = request.sources.compactMap { source in
                guard pageFailures[source] == nil, let page = nextUpdatePages[source] else { return nil }
                return (source, page)
            }
            guard !pages.isEmpty else { return }

            let results = await fetchCatalogs(pages)
            guard !Task.isCancelled, request == feedRequest else { return }
            var incoming: [Catalog] = []
            for (source, page) in pages {
                switch results[source] {
                case .success(let catalog):
                    incoming.append(catalog)
                    if let next = catalog.nextPage, let page, next > page {
                        nextUpdatePages[source] = next
                    } else {
                        nextUpdatePages[source] = nil
                    }
                case .failure(let failure):
                    pageFailures[source] = failure
                case nil:
                    break
                }
            }
            // A source can repeat titles if a release moves the feed between requests.
            let additions = Catalog.merged(incoming, excluding: latestUpdates).latest
            if !additions.isEmpty {
                latestUpdates.append(contentsOf: additions)
                return
            }
        }
    }

    private func fetchCatalogs(_ pages: [(ReadingSource, Int?)], refresh: Bool = false) async
        -> [ReadingSource: Result<Catalog, SourceLoadFailure>] {
        await withTaskGroup(of: (ReadingSource, Result<Catalog, SourceLoadFailure>).self) { group in
            for (source, page) in pages {
                group.addTask {
                    do {
                        return (source, .success(try await source.catalog(page: page, refresh: refresh)))
                    } catch {
                        return (source, .failure(SourceLoadFailure(error)))
                    }
                }
            }
            var results: [ReadingSource: Result<Catalog, SourceLoadFailure>] = [:]
            for await (source, result) in group { results[source] = result }
            return results
        }
    }

    private func cancelSearch() {
        searchFocused = false
        query = ""
        clearSearchResults()
        tab = tabBeforeSearch
    }

    private func clearSearchResults() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchRequest = nil
        searchResults = nil
        searchIssue = nil
        searching = false
    }

    private func submit(feedback: Bool = false) {
        let term = self.term
        guard !term.isEmpty else { return }
        searchFocused = false
        if let url = SourceHTTP.url(term), InAppWebsite.comix.contains(url) {
            clearSearchResults()
            query = ""
            comixPage = ComixPage(url: url)
            if feedback { ShelfHaptics.tap.play() }
            return
        }
        if let url = SourceHTTP.url(term), let provider = ReadingSource.match(url) {
            clearSearchResults()
            // Canonicalize aliases so older RoliaScan link parsing can use its primary host.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = provider.homepage.host
            let link = components?.url ?? url
            if let chapter = provider.chapterLink(link) {
                query = ""
                path.append(chapter)
                return
            }
            if let slug = provider.seriesLink(link) {
                query = ""
                path.append(Manga(slug: slug, title: slug, cover: nil, sourceID: provider))
                return
            }
            searchIssue = .invalidLink
            if feedback { ShelfHaptics.error.play() }
            return
        }
        if term.contains("://") {
            clearSearchResults()
            searchIssue = .unsupportedWebsite
            if feedback { ShelfHaptics.error.play() }
            return
        }
        let sources = activeSources
        guard !sources.isEmpty else {
            clearSearchResults()
            searchIssue = .missingSources
            if feedback { ShelfHaptics.error.play() }
            return
        }
        let request = SearchRequest(term: term, sources: sources)
        if searchRequest != request { clearSearchResults() }
        pendingSearch?.cancel()
        searchRequest = request
        let previousMatches = searchResults ?? [:]
        searchIssue = nil
        searching = true
        if feedback { ShelfHaptics.tap.play() }
        pendingSearch = Task {
            let (matches, failures) = await withTaskGroup(of: (ReadingSource, Result<[Manga], SourceLoadFailure>).self) { group in
                for source in sources {
                    group.addTask {
                        do {
                            return (source, .success(try await source.search(String(term.prefix(120)))))
                        } catch {
                            return (source, .failure(SourceLoadFailure(error)))
                        }
                    }
                }
                var matches = previousMatches
                var failures: [SourceLoadFailure] = []
                for await (source, result) in group {
                    switch result {
                    case .success(let manga): matches[source] = manga
                    case .failure(let failure): failures.append(failure)
                    }
                }
                return (matches, failures)
            }
            guard !Task.isCancelled, term == self.term, sources == activeSources else { return }
            searching = false
            searchResults = matches
            if let failure = SourceLoadFailure.combined(failures) {
                searchIssue = .sources(failure, incomplete: !matches.isEmpty)
                if feedback && !matches.values.contains(where: { !$0.isEmpty }) { ShelfHaptics.error.play() }
            }
        }
    }
}

let mangaGridColumns = [GridItem(.adaptive(minimum: 105, maximum: 166), spacing: 12)]

struct MangaGrid: View {
    let items: [Manga]
    var showSource = false
    var titleStates: [String: SavedChapterUpdates.TitleState] = [:]
    var loadMore: (() async -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: mangaGridColumns, alignment: .leading, spacing: 17) {
            ForEach(items) { manga in
                let status = titleStates[manga.id]
                VStack(alignment: .leading, spacing: 5) {
                    NavigationLink(value: manga) {
                        VStack(alignment: .leading, spacing: 7) {
                            CoverView(url: manga.cover, mangaID: manga.id)
                                .aspectRatio(0.72, contentMode: .fit)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.papertrailStroke)
                                        .allowsHitTesting(false)
                                }
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            Text(manga.title)
                                .font(.subheadline.weight(titleWeight(status)))
                                .foregroundStyle(status == .caughtUp ? Color.secondary : Color.primary)
                                .lineLimit(2, reservesSpace: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                    .accessibilityValue(titleAccessibilityValue(status))
                    if showSource {
                        Text(manga.provider.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.papertrailDetail)
                            .lineLimit(1)
                    }
                    if let note = manga.note, !note.isEmpty {
                        Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .topLeading) {
                    MangaSaveButton(manga: manga, kind: .readLater)
                        .padding(1)
                }
                .overlay(alignment: .topTrailing) {
                    MangaSaveButton(manga: manga)
                        .padding(1)
                }
                .transition(.opacity)
                .task(id: manga.id == items.last?.id) {
                    if manga.id == items.last?.id { await loadMore?() }
                }
            }
        }
        .transition(.opacity)
    }
    private func titleWeight(_ status: SavedChapterUpdates.TitleState?) -> Font.Weight {
        switch status {
        case .unread: .bold
        case .caughtUp: .regular
        default: .semibold
        }
    }

    private func titleAccessibilityValue(_ status: SavedChapterUpdates.TitleState?) -> String {
        switch status {
        case .unread: "Unread chapters"
        case .caughtUp: "Caught up"
        default: ""
        }
    }

}

struct RecentShelf: View {
    @Environment(ReadingStore.self) private var library
    var showEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeading("Continue reading")
            let items = Array(library.recent.prefix(3))
            if items.count == 1, let current = items.first {
                resumeCard(current).shelfResumeTile()
            } else if let current = items.first {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        resumeCard(current).frame(width: 340)
                        VStack(spacing: 0) {
                            ForEach(items.dropFirst()) { item in RecentReadingLink(item: item) }
                        }
                    }
                    .frame(minWidth: 560, alignment: .leading)

                    VStack(spacing: 0) {
                        resumeCard(current).padding(.bottom, 5)
                        ForEach(items.dropFirst()) { item in RecentReadingLink(item: item) }
                    }
                }
            } else if showEmpty {
                ShelfStateView("Nothing in progress",
                               message: "Open a chapter to see it here.", style: .compact)
            }
        }
    }

    private func resumeCard(_ item: ReadingStore.Recent) -> some View {
        let image = item.manga.cover ?? library.bookmarks.first { $0.id == item.manga.id }?.cover
        let progress = library.progress(item.chapter)
        return NavigationLink(value: item.chapter) {
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.manga.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("Chapter \(item.chapter.number) · " + (progress.read ? "Read" : "Page \(progress.page + 1)"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Label("Resume", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.papertrailAccent)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CoverView(url: image, mangaID: item.manga.id)
                    .frame(width: 65, height: 89)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(minHeight: 113)
            .background {
                ZStack {
                    Color.papertrailBackground
                    CoverView(url: image, mangaID: item.manga.id)
                        .scaleEffect(1.28)
                        .blur(radius: 22)
                        .opacity(0.72)
                    LinearGradient(stops: [
                        .init(color: Color.papertrailBackground, location: 0),
                        .init(color: Color.papertrailBackground, location: 0.12),
                        .init(color: Color.papertrailBackground.opacity(0.86), location: 0.44),
                        .init(color: Color.papertrailBackground.opacity(0.10), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(ShelfPressStyle())
    }

}

private struct RecentReadingLink: View {
    @Environment(ReadingStore.self) private var library
    let item: ReadingStore.Recent
    var body: some View {
        NavigationLink(value: item.chapter) {
            HStack(spacing: 10) {
                CoverView(url: item.manga.cover ?? library.bookmarks.first { $0.id == item.manga.id }?.cover,
                          mangaID: item.manga.id)
                    .frame(width: 35, height: 47)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.manga.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    let status = library.progress(item.chapter)
                    Text("Chapter \(item.chapter.number) · \(status.read ? "Read" : "Page \(status.page + 1)") · \(item.manga.provider.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.papertrailStroke).frame(height: 1).padding(.leading, 45)
            }
        }
        .buttonStyle(ShelfPressStyle())
    }
}

struct MangaSaveButton: View {
    enum Kind: String {
        case bookmark
        case readLater = "read-later"
    }

    enum Placement {
        case cover, inline, dock
    }

    @Environment(ReadingStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let manga: Manga
    var kind: Kind = .bookmark
    var placement: Placement = .cover

    var body: some View {
        let saved = kind == .bookmark ? library.bookmarked(manga) : library.isInReadLater(manga)
        let symbol = kind == .bookmark ? "bookmark" : "heart"
        let image = saved ? "\(symbol).fill" : symbol
        let actionTitle = switch (kind, saved) {
        case (.bookmark, false): "Bookmark"
        case (.bookmark, true): "Remove bookmark"
        case (.readLater, false): "Read Later"
        case (.readLater, true): "Remove from Read Later"
        }
        Button {
            switch kind {
            case .bookmark: library.toggleBookmark(manga)
            case .readLater: library.toggleReadLater(manga)
            }
            (saved ? ShelfHaptics.selection : .success).play()
        } label: {
            switch placement {
            case .inline:
                Label(saved && kind == .bookmark ? "Bookmarked" : actionTitle, systemImage: image)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            case .dock:
                ShelfDockIcon(symbol: image, selected: saved)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            case .cover:
                Image(systemName: image)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(saved ? Color.papertrailOnAccent : .white)
                    .background(saved ? Color.papertrailAccent : Color.black.opacity(0.74), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel("\(actionTitle): \(manga.title)")
        .accessibilityIdentifier("\(kind.rawValue)-\(manga.id)")
        .shelfAnimation(saved, animation: ShelfMotion.feedback)
    }
}
