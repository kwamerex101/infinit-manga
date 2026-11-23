import SwiftUI

struct ComicShelf: View {
    @Environment(ComicLibrary.self) private var library
    @Binding var mode: MediaMode

    @State private var tab = ShelfDestination.home
    @State private var tabBeforeSearch = ShelfDestination.home
    @State private var shelf = ComicLibrary.Shelf.bookmarks
    @State private var source: ComicSource?
    @State private var path = NavigationPath()
    @Environment(ComicDownloadStore.self) private var downloads
    @State private var remoteFeeds: [ComicSource: [ComicSeries]] = [:]
    @State private var unavailableFeeds: Set<ComicSource> = []
    @State private var comicRefresh = 0

    private struct Feed: Hashable {
        let sources: [ComicSource]
        let refresh: Int
    }

    var body: some View {
        NavigationStack(path: $path) {
            ShelfNavigation(selection: $tab, destinations: [.home, .library, .settings, .search],
                            identifierPrefix: "comic-dock", showsDock: tab != .search) {
                Group {
                    switch tab {
                    case .library: libraryPage
                    case .search:
                        ComicSearchPage(cancel: { tab = tabBeforeSearch }, manageSources: { tab = .settings })
                    case .settings:
                        ShelfProviderSettings(title: "Comics Settings", sources: ComicSource.allCases,
                                              name: { $0 == .getComics ? "GetComics · Download only" : $0.name },
                                              website: \.website,
                                              isEnabled: library.isEnabled(_:), setEnabled: library.setEnabled(_:source:))
                    default: home
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.papertrailBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: tab) { previous, current in
                if current == .search { tabBeforeSearch = previous }
            }
            .onChange(of: library.enabledSources) {
                if let source, !library.isEnabled(source) { self.source = nil }
            }
            .onChange(of: path.count) { ShelfHaptics.tap.play() }
            .task(id: Feed(sources: dynamicSources, refresh: comicRefresh)) {
                let result = await ComicDiscovery.load(dynamicSources)
                guard !Task.isCancelled else { return }
                remoteFeeds = result.feeds
                unavailableFeeds = result.failures
            }
            .navigationDestination(for: ComicSeries.self) { series in
                if series.source == .getComics {
                    GetComicsDetail(series: series, downloads: downloads)
                } else {
                    ComicSeriesView(series: series.catalogEntry)
                }
            }
            .navigationDestination(for: ComicReadingRoute.self) { ComicReader(route: $0) }
            .overlay(alignment: .bottom) {
                if library.saveError {
                    Label("Comics library data couldn’t be saved or opened.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 70)
                }
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                MediaModeMenu(mode: $mode)
                VStack(alignment: .leading, spacing: 12) {
                    ShelfHeading("Continue reading")
                    if let recent = library.recent.first {
                        ComicResumeRow(recent: recent, feature: true).shelfResumeTile()
                    } else {
                        ShelfStateView("Nothing in progress", message: "Open a comic to see it here.", style: .compact)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeading("Browse comics")
                    if library.enabledSources.isEmpty {
                        ShelfStateView("No comic sources", message: "Enable a source to browse comics.",
                                       action: .init("Manage sources") { tab = .settings })
                    } else {
                        if !library.enabledSources.isEmpty {
                            ShelfSourceFilters(sources: library.enabledSources, selection: $source, name: \.name)
                        }
                        if source == .getComics { GetComicsNotice() }
                        ComicGrid(titles: homeTitles)
                        if let source, dynamicSources.contains(source), remoteFeeds[source] == nil {
                            if unavailableFeeds.contains(source) {
                                ShelfStateView("\(source.name) is unavailable", message: "Try again to load the latest comics.",
                                               style: .compact, action: .init("Retry") { comicRefresh += 1 })
                            } else {
                                MangaGridSkeleton(label: "Loading \(source.name)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .refreshable { comicRefresh += 1 }
        .shelfEntrance()
    }

    private var dynamicSources: [ComicSource] { ComicDiscovery.sources.filter(library.isEnabled) }

    private var homeTitles: [ComicSeries] {
        let current = dynamicSources.filter { source == nil || source == $0 }.flatMap {
            let feed = remoteFeeds[$0] ?? []
            return source == nil ? Array(feed.prefix(8)) : feed
        }
        return current + ComicSeries.catalog.filter { library.isEnabled($0.source) && (source == nil || $0.source == source) }
    }

    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfMasthead(title: "Library")
                Picker("Library view", selection: $shelf.withSelectionFeedback()) {
                    ForEach(ComicLibrary.Shelf.allCases) { section in
                        Text(section == .bookmarks ? "Saved" : section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                if shelf == .downloads {
                    ComicDownloadsSection(downloads: downloads)
                } else if shelf == .recent, !library.recent.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(library.recent) { recent in
                            ComicResumeRow(recent: recent)
                            Divider()
                        }
                    }
                } else if !library.titles(in: shelf).isEmpty {
                    ComicGrid(titles: library.titles(in: shelf))
                } else {
                    ShelfStateView("Nothing here yet", message: emptyShelfMessage, style: .compact)
                }
            }
            .padding(18)
        }
        .shelfEntrance()
    }

    private var emptyShelfMessage: String {
        switch shelf {
        case .bookmarks: "Bookmark a comic to keep it here."
        case .later: "Save a comic to Read Later to find it here."
        case .recent: "Issues you open will appear here."
        case .downloads: "Download or import a comic to read offline."
        }
    }
}

private struct ComicSearchPage: View {
    @Environment(ComicLibrary.self) private var library
    let cancel: () -> Void
    let manageSources: () -> Void
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var submitted = ""
    @State private var source: ComicSource?
    @State private var remoteMatches: [ComicSeries] = []
    @State private var searchingSources = false
    @State private var failedSources: Set<ComicSource> = []

    private struct Search: Hashable {
        let query: String
        let sources: [ComicSource]
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dynamicSources: [ComicSource] {
        ComicDiscovery.sources.filter { library.isEnabled($0) && (source == nil || source == $0) }
    }

    private var matches: [ComicSeries] {
        guard !submitted.isEmpty else { return [] }
        let words = submitted.split(whereSeparator: \.isWhitespace)
        return remoteMatches + ComicSeries.catalog.filter { series in
            library.isEnabled(series.source) && (source == nil || series.source == source) && words.allSatisfy { word in
                [series.title, series.credit, series.source.name].contains { $0.localizedStandardContains(String(word)) }
            }
        }
    }

    var body: some View {
        ShelfSearchPage(mode: "comic", cancel: { focused = false; cancel() }) {
            if !library.enabledSources.isEmpty {
                ShelfSourceFilters(sources: library.enabledSources, selection: $source, name: \.name)
            }
        } results: {
            VStack(spacing: 13) {
                if source == .getComics { GetComicsNotice() }
                if !matches.isEmpty {
                    ComicGrid(titles: matches)
                } else if searchingSources {
                    MangaGridSkeleton(label: "Searching comics")
                } else {
                    Spacer(minLength: 0)
                    if library.enabledSources.isEmpty {
                        ShelfStateView("No comic sources", message: "Enable a source to search for comics.",
                                       action: .init("Manage sources") { focused = false; manageSources() })
                    } else if submitted.isEmpty {
                        ShelfStateView("Find a comic", message: "Search by title, creator, or source.")
                    } else if !failedSources.isEmpty {
                        ShelfStateView("Couldn’t search comics", message: "Try again shortly.", style: .compact)
                    } else {
                        ShelfStateView("No matching comics", message: "Try another title or change the source filter.",
                                       action: .init("Edit search") { focused = true })
                    }
                    Spacer(minLength: 0)
                }
            }
            .shelfAnimation(matches.map(\.id))
        } searchBar: {
            ShelfSearchBar(hasQuery: !query.isEmpty, submit: submit, submitIdentifier: "comic-search-submit",
                           canSubmit: !term.isEmpty && !library.enabledSources.isEmpty, clear: { query = ""; focused = true }) {
                TextField("Title or creator", text: $query)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submit)
                    .accessibilityIdentifier("comic-search-field")
            }
        }
        .task { if query.isEmpty { focused = true } }
        .onChange(of: query) { if term != submitted { submitted = "" } }
        .task(id: Search(query: submitted, sources: dynamicSources)) {
            remoteMatches = []
            failedSources = []
            searchingSources = false
            guard !submitted.isEmpty, !dynamicSources.isEmpty else { return }
            let sources = dynamicSources
            searchingSources = true
            let result = await ComicDiscovery.load(sources, query: submitted)
            guard !Task.isCancelled else { return }
            remoteMatches = sources.flatMap { result.feeds[$0] ?? [] }
            failedSources = result.failures
            searchingSources = false
        }
    }

    private func submit() {
        guard !term.isEmpty && !library.enabledSources.isEmpty else { return }
        ShelfHaptics.tap.play()
        focused = false
        submitted = term
    }
}

private struct ComicGrid: View {
    let titles: [ComicSeries]

    var body: some View {
        LazyVGrid(columns: mangaGridColumns, alignment: .leading, spacing: 17) {
            ForEach(titles) { series in
                VStack(alignment: .leading, spacing: 5) {
                    NavigationLink(value: series) {
                        VStack(alignment: .leading, spacing: 7) {
                            CoverView(url: series.cover, mangaID: series.id)
                                .aspectRatio(0.72, contentMode: .fit)
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.papertrailStroke) }
                                .accessibilityHidden(true)
                            Text(series.title).font(.subheadline.weight(.semibold))
                                .lineLimit(2, reservesSpace: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                    .accessibilityIdentifier("comic-series-\(series.id)")
                    Text(series.source.name).font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.papertrailDetail).lineLimit(1)
                }
                .overlay(alignment: .topLeading) {
                    ComicSaveButton(series: series, shelf: .later, placement: .cover).padding(1)
                }
                .overlay(alignment: .topTrailing) {
                    ComicSaveButton(series: series, shelf: .bookmarks, placement: .cover).padding(1)
                }
            }
        }
        .shelfAnimation(titles.map(\.id))
    }
}

private struct ComicSaveButton: View {
    enum Placement { case cover, inline, dock }

    @Environment(ComicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let series: ComicSeries
    let shelf: ComicLibrary.Shelf
    let placement: Placement

    var body: some View {
        let saved = library.contains(series, in: shelf)
        let later = shelf == .later
        let symbol = later ? "heart" : "bookmark"
        let icon = saved ? "\(symbol).fill" : symbol
        let label = later ? "Read Later" : "Bookmark"
        Button {
            library.toggle(series, in: shelf)
            (saved ? ShelfHaptics.selection : .success).play()
        } label: {
            switch placement {
            case .inline:
                Label(saved && !later ? "Bookmarked" : label, systemImage: icon)
            case .dock:
                ShelfDockIcon(symbol: icon, selected: saved)
            case .cover:
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(saved ? Color.papertrailOnAccent : .white)
                    .background(saved ? Color.papertrailAccent : Color.black.opacity(0.74), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        .accessibilityLabel("\(label): \(series.title)")
        .accessibilityValue(saved ? "Saved" : "Not saved")
        .accessibilityIdentifier("comic-\(symbol)-\(series.id)")
        .shelfAnimation(saved, animation: ShelfMotion.feedback)
    }
}

private struct ComicResumeRow: View {
    let recent: ComicLibrary.Recent
    var feature = false

    var body: some View {
        NavigationLink(value: recent.route) {
            HStack(spacing: 14) {
                if !feature { cover.frame(width: 38, height: 51) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(recent.series.title).font(feature ? .headline : .subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(recent.issue.title) · Page \(recent.page + 1)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if feature {
                        Label("Resume", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.papertrailAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if feature {
                    cover.frame(width: 64, height: 88)
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(feature ? 12 : 8)
            .background(feature ? Color.papertrailFeature : .clear, in: .rect(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityIdentifier("comic-resume-\(recent.series.id)-\(recent.issue.number)")
    }

    private var cover: some View {
        CoverView(url: recent.series.cover, mangaID: recent.series.id).accessibilityHidden(true)
    }
}

private struct ComicSeriesView: View {
    @Environment(ComicLibrary.self) private var library
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let series: ComicSeries

    @State private var issues: [ComicIssue] = []
    @State private var failure: SourceLoadFailure?
    @State private var attempt = 0
    @State private var ascending: Bool
    @State private var visibleCount = 50
    @State private var nextPage: Int?
    @State private var firstIssue: ComicIssue?
    @State private var loadingMore = false
    @State private var loading = true
    @State private var showsIssueSearch = false
    @State private var showsXOXOWebsite = false
    @State private var issueQuery = ""
    @State private var lookup = 0

    private struct IssueRequest: Hashable {
        let attempt: Int
        let ascending: Bool?
    }

    init(series: ComicSeries) {
        self.series = series
        _ascending = State(initialValue: series.source.isWebtoon)
    }

    private var resume: ComicLibrary.Recent? { library.lastRead(series) }
    private var orderedIssues: [ComicIssue] {
        let query = ShelfListQuery(issueQuery)
        return issues.filter { matches($0, query: query) }
            .sorted { ascending ? $0.number < $1.number : $0.number > $1.number }
    }

    private func matches(_ issue: ComicIssue, query: ShelfListQuery) -> Bool {
        query.matches(number: String(issue.number), title: issue.title)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            list(side: side)
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if side { Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing)) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if side {
                        VStack(spacing: 8) {
                            ComicSaveButton(series: series, shelf: .bookmarks, placement: .dock)
                            ComicSaveButton(series: series, shelf: .later, placement: .dock)
                            readLink(side: true)
                            Button {
                                ShelfHaptics.selection.play()
                                showsIssueSearch.toggle()
                                if !showsIssueSearch { issueQuery = "" }
                            } label: {
                                ShelfDockIcon(symbol: "magnifyingglass", selected: showsIssueSearch)
                            }
                            .accessibilityLabel("Search \(series.source.issueLabel.lowercased())")
                            .accessibilityIdentifier("comic-issue-search-toggle")
                            .accessibilityAddTraits(showsIssueSearch ? .isSelected : [])
                            .disabled(issues.isEmpty)
                            .opacity(issues.isEmpty ? 0.45 : 1)
                        }
                        .buttonStyle(ShelfPressStyle())
                        .padding(.trailing, geometry.safeAreaInsets.trailing >= 24 ? 23 : 10)
                        .padding(.bottom, 10)
                        .ignoresSafeArea(.container, edges: .trailing)
                    }
                }
        }
        .background(Color.papertrailBackground)
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showsXOXOWebsite) {
            InAppWebsiteBrowser(site: .xoxoComics, url: series.website)
        }
        .task(id: IssueRequest(attempt: attempt, ascending: series.source.isWebtoon ? ascending : nil)) {
            let order = ascending
            failure = nil
            loading = true
            issues = []
            nextPage = nil
            do {
                let result = try await series.source.issues(for: series, ascending: order)
                try Task.checkCancellation()
                issues = result.issues
                nextPage = result.nextPage
                if order || !series.source.isWebtoon {
                    firstIssue = result.issues.min { $0.number < $1.number }
                }
            } catch {
                if !Task.isCancelled { failure = SourceLoadFailure(error) }
            }
            if !Task.isCancelled { loading = false }
        }
        .task(id: lookup) {
            let term = ShelfListQuery(issueQuery)
            guard lookup > 0, !term.isEmpty else { return }
            while let nextPage, term.text == ShelfListQuery(issueQuery).text, !loading, !loadingMore,
                  !issues.contains(where: { matches($0, query: term) }) {
                await loadMore(nextPage)
                if failure != nil || Task.isCancelled { break }
            }
        }
    }

    private func list(side: Bool) -> some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack(alignment: .top, spacing: 15) {
                        CoverView(url: series.cover, mangaID: series.id)
                            .frame(width: 90, height: 122).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(series.title).font(.title2.bold())
                            Text(series.credit).font(.subheadline).foregroundStyle(.secondary)
                            if !side {
                                ComicSaveButton(series: series, shelf: .bookmarks, placement: .inline).buttonStyle(.bordered)
                                ComicSaveButton(series: series, shelf: .later, placement: .inline).buttonStyle(.bordered)
                            }
                            if series.source == .xoxo {
                                Button {
                                    ShelfHaptics.tap.play()
                                    showsXOXOWebsite = true
                                } label: {
                                    Label(series.source.name, systemImage: "arrow.up.right").font(.footnote)
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Link(destination: series.website) {
                                    Label(series.source.name, systemImage: "arrow.up.right").font(.footnote)
                                }
                            }
                            if let license = series.license {
                                Link("License", destination: license).font(.footnote)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    if !side && (resume != nil || !issues.isEmpty) { readLink(side: false) }
                }

                Section {
                    if !side && !issues.isEmpty {
                        issueSearch(autofocus: false)
                            .id("comic-issue-search-row")
                            .listRowBackground(Color.clear)
                    }
                    if let failure, issues.isEmpty {
                        ShelfStateView(failure: failure, title: "\(series.source.issueLabel) unavailable",
                                       message: "Try again to load the list.", style: .compact,
                                       action: .init("Retry") { attempt += 1 })
                    } else if loading {
                        ForEach(0..<4, id: \.self) { index in
                            LoadingSkeleton(label: "Loading \(series.source.issueLabel.lowercased())") { ChapterRowSkeleton() }
                                .accessibilityHidden(index != 0)
                        }
                    } else if issues.isEmpty {
                        ShelfStateView("No readable issues", message: "Check the source’s website for more episodes.", style: .compact)
                    } else {
                        let results = orderedIssues
                        ForEach(results.prefix(visibleCount)) { issue in
                            issueLink(issue)
                        }
                        if results.isEmpty && !loadingMore {
                            ShelfStateView("No matching issues", message: nextPage == nil
                                           ? "Try a different number or title." : "Tap Go to search more episodes.", style: .compact)
                        }
                        if visibleCount < results.count {
                            Button("Load more \(series.source.issueLabel.lowercased())") {
                                ShelfHaptics.tap.play()
                                visibleCount += 50
                            }
                        } else if loadingMore {
                            SkeletonLine(label: "Loading more episodes").frame(minHeight: 30)
                        } else if let nextPage {
                            if let failure {
                                ShelfStateView(failure: failure, title: "Couldn’t load more episodes",
                                               message: "Try again to continue browsing.", style: .compact,
                                               action: .init("Retry") { Task { await loadMore(nextPage) } })
                            } else {
                                Button("Load more episodes") { Task { await loadMore(nextPage) } }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(series.source.issueLabel)
                        Spacer()
                        Menu {
                            Picker("Order", selection: $ascending.withSelectionFeedback()) {
                                Text("Newest first").tag(false)
                                Text("Oldest first").tag(true)
                            }
                        } label: {
                            Label(ascending ? "Oldest first" : "Newest first", systemImage: "arrow.up.arrow.down").textCase(nil)
                        }
                        .disabled(issues.count < 2 || loadingMore)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                if side && showsIssueSearch && !issues.isEmpty {
                    issueSearch(autofocus: true)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.papertrailBackground)
                }
            }
            .onChange(of: issueQuery) { before, after in
                if !side && before.isEmpty && !after.isEmpty { proxy.scrollTo("comic-issue-search-row", anchor: .top) }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: ascending) { visibleCount = 50 }
            .shelfAnimation(ascending)
        }
    }

    private func issueSearch(autofocus: Bool) -> some View {
        ShelfListSearch(prompt: series.source.isWebtoon ? "Episode number or title" : "Issue number or title",
                        identifier: "comic-issue-search", query: $issueQuery, autofocus: autofocus) {
            if !loading && !loadingMore { lookup += 1 }
        }
    }

    @ViewBuilder
    private func issueLink(_ issue: ComicIssue) -> some View {
        if series.source.opensInBrowser {
            Link(destination: issue.website) {
                HStack {
                    issueLabel(issue)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
            }
            .accessibilityIdentifier("comic-issue-\(series.id)-\(issue.number)")
        } else {
            NavigationLink(value: ComicReadingRoute(series: series, issue: issue)) { issueLabel(issue) }
                .accessibilityIdentifier("comic-issue-\(series.id)-\(issue.number)")
        }
    }

    private func issueLabel(_ issue: ComicIssue) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).fontWeight(.medium).lineLimit(2)
                if let date = issue.date { Text(date).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let progress = library.progress(issue) {
                Text("Page \(progress.page + 1) of \(progress.pageCount)")
                    .font(.caption).foregroundStyle(Color.papertrailDetail)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func readLink(side: Bool) -> some View {
        if series.source.opensInBrowser {
            Link(destination: series.website) {
                if side { ShelfDockIcon(symbol: "arrow.up.right") }
                else { Label("Read issue #1", systemImage: "arrow.up.right") }
            }
            .accessibilityIdentifier("comic-start-reading")
            .accessibilityLabel("Read issue 1 on Image Comics")
        } else {
            nativeReadingLink(side: side)
        }
    }

    private func nativeReadingLink(side: Bool) -> some View {
        let route = resume?.route ?? firstIssue.map { ComicReadingRoute(series: series, issue: $0) }
        let title = resume == nil ? "Start reading" : "Resume reading"
        let icon = resume == nil ? "book" : "play.fill"
        return NavigationLink(value: route) {
            if side {
                ShelfDockIcon(symbol: icon).opacity(route == nil ? 0.45 : 1)
            } else {
                Label(title, systemImage: icon)
            }
        }
        .disabled(route == nil)
        .accessibilityIdentifier("comic-start-reading")
        .accessibilityLabel(title)
    }

    private func loadMore(_ page: Int) async {
        guard nextPage == page, !loadingMore else { return }
        loadingMore = true
        failure = nil
        defer { loadingMore = false }
        do {
            let result = try await series.source.issues(for: series, page: page, ascending: ascending)
            try Task.checkCancellation()
            if let next = result.nextPage, next <= page { throw SourceFailure.unavailable }
            var seen = Set(issues.map(\.id))
            issues.append(contentsOf: result.issues.filter { seen.insert($0.id).inserted })
            nextPage = result.nextPage
            failure = nil
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }
}
