import SwiftUI

struct NovelShelf: View {
    @Environment(NovelLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Binding var mode: MediaMode
    @Binding var appearance: AppAppearance
    let agent: NovelAgent

    @State private var tab = ShelfDestination.home
    @State private var tabBeforeSearch = ShelfDestination.home
    @State private var shelf = NovelLibrary.Shelf.bookmarks
    @State private var source: NovelSource?
    @State private var releases: [NovelRelease] = []
    @State private var failedSources: [NovelSource] = []
    @State private var books: [Novel] = []
    @State private var loading = true
    @State private var refresh = 0
    @State private var path = NavigationPath()
    @State private var appearanceExpanded = true
    @State private var readingExpanded = false
    @State private var sourcesExpanded = false

    private var visibleReleases: [NovelRelease] {
        releases.filter { source == nil || $0.novel.provider == source }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ShelfNavigation(selection: $tab, identifierPrefix: "novel-dock", showsDock: tab != .search, inlineDock: tab == .agent) {
                Group {
                    switch tab {
                    case .home: home
                    case .library: libraryPage
                    case .settings: settings
                    case .agent: NovelAgentView(agent: agent)
                    case .search:
                        NovelSearchView(cancel: { tab = tabBeforeSearch }, manageSources: { tab = .settings })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.papertrailBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: path.count) { ShelfHaptics.tap.play() }
            .onChange(of: tab) { previous, current in
                if current == .search { tabBeforeSearch = previous }
            }
            .navigationDestination(for: Novel.self) { NovelSeriesView(novel: $0) }
            .navigationDestination(for: NovelReadingRoute.self) { NovelReader(route: $0) }
            .task(id: FeedRequest(sources: library.enabledSources, refresh: refresh)) {
                await load(library.enabledSources)
            }
            .onChange(of: library.enabledSources) {
                if let source, !library.enabledSources.contains(source) { self.source = nil }
                releases.removeAll { !library.enabledSources.contains($0.novel.provider) }
                books.removeAll { !library.enabledSources.contains($0.provider) }
            }
            .onChange(of: scenePhase) { if scenePhase == .active { refresh += 1 } }
            .overlay(alignment: .bottom) {
                if library.saveError {
                    Label("Novel library data couldn’t be saved or opened.", systemImage: "exclamationmark.circle")
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 68)
                }
            }
        }
    }

    private struct FeedRequest: Hashable {
        let sources: [NovelSource]
        let refresh: Int
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                MediaModeMenu(mode: $mode)
                continueReading
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeading(source == .standardEbooks ? "Books" : "Latest updates")
                    if !library.enabledSources.isEmpty {
                        ShelfSourceFilters(sources: library.enabledSources, selection: $source, name: \.name)
                    }
                    if library.enabledSources.isEmpty {
                        ShelfStateView("No novel sources", message: "Enable a source in Novel Settings.",
                                       style: .compact, action: .init("Manage sources") { tab = .settings })
                    } else if source == .standardEbooks {
                        if loading && books.isEmpty {
                            MangaGridSkeleton(label: "Loading books")
                        } else if !books.isEmpty {
                            NovelGrid(novels: books)
                        }
                    } else if loading && visibleReleases.isEmpty {
                        MangaGridSkeleton(label: "Loading novel updates")
                    } else if visibleReleases.isEmpty && failedSources.isEmpty {
                        ShelfStateView("No recent releases", message: "Search the enabled sources for a novel.", style: .compact)
                    } else {
                        NovelGrid(novels: visibleReleases.map(\.novel),
                                  notes: Dictionary(uniqueKeysWithValues: visibleReleases.map { ($0.id, $0.chapter.label) }))
                    }
                    if !failedSources.isEmpty {
                        ShelfStateView("Couldn’t refresh novel updates",
                                       message: failedSources.map(\.name).joined(separator: ", "),
                                       style: .compact, action: .init("Retry") { refresh += 1 })
                    }
                }
                if source == nil && !books.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeading("Books")
                        NovelGrid(novels: books)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .refreshable { await load(library.enabledSources) }
        .shelfEntrance()
    }

    private var continueReading: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeading("Continue reading")
            if library.recent.isEmpty {
                ShelfStateView("No novels in progress", message: "Open a chapter and your place will appear here.", style: .compact)
            } else {
                ForEach(Array(library.recent.prefix(3))) { recent in
                    NavigationLink(value: NovelReadingRoute(novel: recent.novel, chapter: recent.chapter)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(recent.novel.title).font(.headline).lineLimit(2)
                                let position = library.progress(recent.chapter)
                                Text("\(recent.chapter.label) · \(position.read ? "Read" : "Paragraph \(position.paragraph + 1)")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Label("Resume", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.papertrailDetail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            CoverView(url: recent.novel.cover, mangaID: recent.novel.id)
                                .frame(width: 64, height: 88)
                                .accessibilityHidden(true)
                        }
                        .padding(12)
                        .background(Color.papertrailFeature, in: .rect(cornerRadius: 13))
                    }
                    .buttonStyle(ShelfPressStyle())
                    .accessibilityIdentifier("novel-resume")
                    .shelfResumeTile()
                }
            }
        }
    }

    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfMasthead(title: "Novel Library")
                Picker("Novel shelf", selection: $shelf.withSelectionFeedback()) {
                    ForEach(NovelLibrary.Shelf.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                let novels = library.titles(in: shelf)
                if novels.isEmpty {
                    ShelfStateView("No \(shelf.rawValue.lowercased()) yet", style: .compact)
                } else {
                    NovelGrid(novels: novels)
                }
            }
            .padding(18)
        }
        .shelfEntrance()
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShelfMasthead(title: "Novel Settings")
                ShelfSettingsDisclosure(title: "Appearance", expanded: $appearanceExpanded) {
                    Picker("App appearance", selection: $appearance.withSelectionFeedback()) {
                        ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .modifier(ShelfSurface())
                }
                ShelfSettingsDisclosure(title: "Reader", expanded: $readingExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        NovelReadingPreferences()
                    }
                    .padding(12)
                    .modifier(ShelfSurface())
                }
                ShelfSettingsDisclosure(title: "Sources", expanded: $sourcesExpanded) {
                    VStack(spacing: 12) {
                        ForEach(NovelSource.allCases) { source in
                            Toggle(source.name, isOn: Binding {
                                library.enabledSources.contains(source)
                            } set: { library.setEnabled($0, source: source) }.withSelectionFeedback())
                        }
                    }
                    .padding(12)
                    .modifier(ShelfSurface())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .shelfEntrance()
    }

    private func load(_ sources: [NovelSource]) async {
        loading = true
        async let releasesRequest = NovelCatalog.collect(sources.filter { $0 != .standardEbooks }) { try await $0.latest() }
        let bookSources = sources.filter { $0 == .standardEbooks }
        async let booksRequest = NovelCatalog.collect(bookSources) { _ in try await StandardEbooks.books() }
        let (result, bookResult) = await (releasesRequest, booksRequest)
        guard !Task.isCancelled, sources == library.enabledSources else { return }
        let completed = sources.filter { !result.failed.contains($0) }
        let kept = releases.filter { result.failed.contains($0.novel.provider) }
        let combined = kept + result.items.filter { completed.contains($0.novel.provider) }
        var seen = Set<Novel.ID>()
        releases = combined.sorted {
            let first = $0.date ?? .distantPast
            let second = $1.date ?? .distantPast
            return first == second ? $0.id < $1.id : first > second
        }.filter { seen.insert($0.id).inserted }
        if bookResult.failed.isEmpty { books = bookResult.items }
        failedSources = result.failed + bookResult.failed
        loading = false
    }
}

enum NovelCatalog {
    static func collect<Item: Sendable>(_ sources: [NovelSource],
                                         request: @escaping @Sendable (NovelSource) async throws -> [Item])
    async -> (items: [Item], failed: [NovelSource]) {
        await withTaskGroup(of: (NovelSource, [Item]?).self) { group in
            for source in sources {
                group.addTask { (source, try? await request(source)) }
            }
            var entries = [NovelSource: [Item]]()
            for await (source, items) in group { entries[source] = items }
            return (sources.flatMap { entries[$0] ?? [] }, sources.filter { entries[$0] == nil })
        }
    }

    static func unique(_ novels: [Novel]) -> [Novel] {
        var ids = Set<Novel.ID>()
        return novels.filter { ids.insert($0.id).inserted }
    }
}

struct NovelGrid: View {
    let novels: [Novel]
    var notes: [Novel.ID: String] = [:]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 190), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(novels) { novel in
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .top) {
                        NavigationLink(value: novel) {
                            CoverView(url: novel.cover, mangaID: novel.id)
                                .aspectRatio(0.72, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(novel.title)")
                        .accessibilityIdentifier("novel-cover-\(novel.slug)")
                        HStack(spacing: 2) {
                            NovelSaveButton(novel: novel, shelf: .later, compact: true)
                            Spacer(minLength: 0)
                            NovelSaveButton(novel: novel, shelf: .bookmarks, compact: true)
                        }
                        .padding(3)
                    }
                    NavigationLink(value: novel) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(novel.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(novel.provider.name).font(.caption.weight(.semibold)).foregroundStyle(Color.papertrailDetail)
                            if let note = notes[novel.id] {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("novel-title-\(novel.slug)")
                }
            }
        }
    }
}

struct NovelSaveButton: View {
    @Environment(NovelLibrary.self) private var library
    let novel: Novel
    let shelf: NovelLibrary.Shelf
    var compact = false
    var dock = false

    var body: some View {
        let saved = library.contains(novel, in: shelf)
        let symbol = shelf == .later ? "heart" : "bookmark"
        let label = shelf == .later ? "Read Later" : "Bookmark"
        let icon = saved ? "\(symbol).fill" : symbol
        Button {
            library.toggle(novel, in: shelf)
            (saved ? ShelfHaptics.selection : .success).play()
        } label: {
            if dock {
                ShelfDockIcon(symbol: icon, selected: saved)
            } else if compact {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(saved ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle().fill(saved ? Color.papertrailAccent : Color.black.opacity(0.72)).padding(3)
                    }
            } else {
                Label(saved && shelf == .bookmarks ? "Bookmarked" : label, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(ShelfPressStyle())
        .shelfAnimation(saved, animation: ShelfMotion.feedback)
        .accessibilityLabel(compact ? "\(label), \(novel.title)" : label)
        .accessibilityValue(saved ? "Saved" : "Not saved")
        .accessibilityAddTraits(saved ? .isSelected : [])
        .accessibilityIdentifier("novel-\(symbol)-\(novel.slug)")
    }
}

struct NovelSearchView: View {
    @Environment(NovelLibrary.self) private var library
    @FocusState private var focused: Bool
    let cancel: () -> Void
    let manageSources: () -> Void

    @State private var query = ""
    @State private var source: NovelSource?
    @State private var request: String?
    @State private var novels: [Novel] = []
    @State private var failures: [NovelSource] = []
    @State private var loading = false
    @State private var revision = 0

    private struct Search: Hashable {
        let title: String?
        let sources: [NovelSource]
        let revision: Int
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sources: [NovelSource] { source.map { [$0] } ?? library.enabledSources }

    var body: some View {
        ShelfSearchPage(mode: "novel", cancel: close) {
            if !library.enabledSources.isEmpty {
                ShelfSourceFilters(sources: library.enabledSources, selection: $source, name: \.name)
            }
        } results: {
            VStack(alignment: .leading, spacing: 13) {
                if loading {
                    MangaGridSkeleton(label: "Searching novels")
                } else if !novels.isEmpty {
                    NovelGrid(novels: novels)
                    if !failures.isEmpty { failedSearch(compact: true) }
                } else {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                }
            }
            .shelfAnimation(novels.map(\.id))
            .shelfAnimation(loading)
        } searchBar: {
            ShelfSearchBar(hasQuery: !query.isEmpty, submit: submit, submitIdentifier: "novel-search-submit",
                           canSubmit: !term.isEmpty && !sources.isEmpty, clear: {
                query = ""
                focused = true
            }) {
                TextField("Novel title", text: $query)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(submit)
                    .accessibilityIdentifier("novel-search-field")
            }
        }
        .task { if query.isEmpty { focused = true } }
        .onChange(of: query) {
            if term != request {
                request = nil
                resetResults()
            }
        }
        .onChange(of: source) {
            if request != nil { resetResults(); loading = true }
        }
        .task(id: Search(title: request, sources: sources, revision: revision)) {
            guard let request, !sources.isEmpty else { return }
            loading = true
            let result = await NovelCatalog.collect(sources) { try await $0.search(String(request.prefix(120))) }
            guard !Task.isCancelled else { return }
            novels = NovelCatalog.unique(result.items)
            failures = result.failed
            loading = false
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.enabledSources.isEmpty {
            ShelfStateView("No novel sources", message: "Enable a source to search for novels.",
                           action: .init("Manage sources") { focused = false; manageSources() })
        } else if !failures.isEmpty {
            failedSearch(compact: false)
        } else if request != nil {
            ShelfStateView("No matching novels", message: "Try a different title or change the source filter.",
                           action: .init("Edit search") { focused = true })
        } else {
            ShelfStateView("Find a novel", message: "Search by title across your novel sources.")
        }
    }

    private func failedSearch(compact: Bool) -> some View {
        ShelfStateView(compact ? "Search incomplete" : "Search unavailable",
                       message: "Couldn’t search \(failures.map(\.name).joined(separator: ", ")).",
                       style: compact ? .compact : .standard, action: .init("Retry", perform: submit))
    }

    private func resetResults() {
        novels = []
        failures = []
        loading = false
    }

    private func close() {
        focused = false
        cancel()
    }

    private func submit() {
        guard !term.isEmpty, !sources.isEmpty else { return }
        ShelfHaptics.tap.play()
        focused = false
        resetResults()
        loading = true
        request = term
        revision += 1
    }
}
