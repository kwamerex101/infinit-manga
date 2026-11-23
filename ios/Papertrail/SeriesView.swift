import SwiftUI

struct SeriesView: View {
    @Environment(ReadingStore.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("chapters-unread-only") private var unreadOnly = false
    let manga: Manga
    let openChapter: (Chapter) -> Void
    @State private var series: Series?
    @State private var chapters: [Chapter] = []
    @State private var nextOffset: Int?
    @State private var ascending = false
    @State private var loading = true
    @State private var failure: SourceLoadFailure?
    @State private var showingSynopsis = false
    @State private var selectingChapters = false
    @State private var selectedChapterIDs: Set<String> = []
    @State private var selectAllTask: Task<Void, Never>?
    @State private var selectAllFailed = false

    private var visibleChapters: [Chapter] {
        unreadOnly ? chapters.filter { !library.progress($0).read } : chapters
    }

    private var allChaptersSelected: Bool {
        nextOffset == nil && !visibleChapters.isEmpty &&
            visibleChapters.allSatisfy { selectedChapterIDs.contains($0.rowKey) }
    }

    private var seriesManga: Manga { series?.manga ?? manga }

    private var recentChapter: Chapter? {
        guard let recent = library.recent.first(where: { $0.manga.id == manga.id })?.chapter else { return nil }
        guard let group = chapters.first(where: { $0.rowKey == recent.rowKey }),
              let release = group.releases.first(where: { $0.localKey == recent.localKey }) else { return recent }
        return group.opening(release)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            chapterList(side: side)
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if side {
                        Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if side {
                        seriesDock
                            .padding(.trailing, geometry.safeAreaInsets.trailing >= 24 ? 23 : 10)
                            .padding(.bottom, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .ignoresSafeArea(.container, edges: .trailing)
                    }
                }
        }
        .background(Color.papertrailBackground)
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selectingChapters ? "Done" : "Select") {
                    ShelfHaptics.selection.play()
                    cancelSelectAll()
                    selectAllFailed = false
                    selectedChapterIDs.removeAll()
                    selectingChapters.toggle()
                }
                .disabled(visibleChapters.isEmpty && !selectingChapters)
                .accessibilityIdentifier("select-chapters")
            }
        }
        .shelfAnimation(selectingChapters)
        .task(id: ascending) { await load(offset: 0) }
        .onDisappear { cancelSelectAll() }
    }

    private var seriesDock: some View {
        VStack(spacing: 8) {
            MangaSaveButton(manga: seriesManga, placement: .dock)
            MangaSaveButton(manga: seriesManga, kind: .readLater, placement: .dock)
            readingLink(side: true)
        }
        .buttonStyle(ShelfPressStyle())
    }

    private func readingLink(side: Bool) -> some View {
        let recent = recentChapter
        let chapter = recent ?? series?.first.map { first in
            library.readingRelease(chapters.first(where: { $0.rowKey == first.rowKey }) ?? first)
        }
        let title = recent.map { "Resume chapter \($0.number)" } ?? "Start reading"
        let icon = recent == nil ? "book" : "play.fill"
        return NavigationLink(value: chapter) {
            if side {
                ShelfDockIcon(symbol: icon).opacity(chapter == nil ? 0.45 : 1)
            } else {
                Label(title, systemImage: icon)
            }
        }
        .disabled(chapter == nil)
        .accessibilityLabel(title)
        .accessibilityIdentifier("series-reading")
    }

    private func chapterList(side: Bool) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 15) {
                    CoverView(url: series?.manga.cover ?? manga.cover, mangaID: manga.id)
                        .frame(width: 90, height: 122)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(series?.manga.title ?? manga.title).font(.title2.bold())
                        if !side {
                            MangaSaveButton(manga: seriesManga, placement: .inline)
                                .buttonStyle(.bordered)
                            MangaSaveButton(manga: seriesManga, kind: .readLater, placement: .inline)
                                .buttonStyle(.bordered)
                        }
                        Link(destination: manga.source) {
                            Label(manga.provider.name, systemImage: "arrow.up.right").font(.footnote)
                        }
                    }
                }
                .padding(.vertical, 5)
                if !side && (recentChapter != nil || series?.first != nil) {
                    readingLink(side: false)
                }
                if let synopsis = series?.synopsis, !synopsis.isEmpty {
                    DisclosureGroup("Synopsis", isExpanded: $showingSynopsis.withSelectionFeedback()) {
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
            Section {
                ForEach(visibleChapters, id: \.rowKey) { chapter in
                    chapterRow(chapter)
                }
                if !loading, failure == nil, unreadOnly, visibleChapters.isEmpty, !chapters.isEmpty {
                    ShelfStateView("No unread chapters",
                                   message: nextOffset == nil ? "Show all chapters to revisit them." : "Load more to check the remaining chapters.",
                                   style: .compact)
                }
                if loading {
                    ForEach(0..<(visibleChapters.isEmpty ? 4 : 2), id: \.self) { index in
                        LoadingSkeleton(label: "Loading chapters") {
                            ChapterRowSkeleton()
                        }
                        .accessibilityHidden(index != 0)
                    }
                } else if let failure {
                    ShelfStateView(failure: failure, title: "Chapters unavailable",
                                   message: "Couldn’t load chapters from \(manga.provider.name).",
                                   style: .compact, action: .init("Retry") {
                        Task { await load(offset: nextOffset ?? 0) }
                    })
                } else if let nextOffset {
                    Button("Load more chapters") {
                        ShelfHaptics.tap.play()
                        Task { await load(offset: nextOffset) }
                    }
                    .disabled(selectAllTask != nil)
                } else if chapters.isEmpty {
                    ShelfStateView("No chapters available",
                                   message: "\(manga.provider.name) lists no chapters for this series.",
                                   style: .compact)
                }
            } header: {
                HStack {
                    Text("Chapters")
                    Spacer()
                    Menu {
                        Picker("Chapter order", selection: $ascending.withSelectionFeedback()) {
                            Text("Newest first").tag(false)
                            Text("Oldest first").tag(true)
                        }
                        Divider()
                        Toggle("Unread only", isOn: $unreadOnly.withSelectionFeedback())
                    } label: {
                        Label(ascending ? "Oldest first" : "Newest first", systemImage: "arrow.up.arrow.down")
                            .textCase(nil)
                    }
                    .accessibilityValue(unreadOnly ? "Unread only" : "All chapters")
                    .disabled(selectingChapters)
                }
            }
            .shelfAnimation(visibleChapters.map(\.rowKey))
            .shelfAnimation(loading)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectingChapters { chapterSelectionBar.transition(.opacity) }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: Chapter) -> some View {
        let read = library.progress(chapter).read
        if selectingChapters {
            let selected = selectedChapterIDs.contains(chapter.rowKey)
            Button {
                if !selectedChapterIDs.insert(chapter.rowKey).inserted {
                    selectedChapterIDs.remove(chapter.rowKey)
                }
                ShelfHaptics.selection.play()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.papertrailNavigation : Color.secondary)
                        .accessibilityHidden(true)
                    chapterLabel(chapter, read: read)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectAllTask != nil)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("chapter-select-\(chapter.rowKey)")
            .shelfAnimation(selected, animation: ShelfMotion.feedback)
        } else {
            NavigationLink(value: library.readingRelease(chapter)) {
                chapterLabel(chapter, read: read)
            }
            .shelfAnimation(read)
            .contextMenu {
                chapterReadAction(chapter, read: read)
                if chapter.alternateReleases != nil {
                    Menu("Other releases") {
                        ForEach(chapter.releases) { release in
                            Button(release.releaseLabel) { openChapter(chapter.opening(release)) }
                        }
                    }
                }
            }
            .swipeActions {
                chapterReadAction(chapter, read: read)
                    .tint(.indigo)
            }
        }
    }

    private func chapterReadAction(_ chapter: Chapter, read: Bool) -> some View {
        Button {
            library.setRead(!read, chapter: chapter)
            (read ? ShelfHaptics.selection : .success).play()
        } label: {
            Label(read ? "Mark as Unread" : "Mark as Read", systemImage: read ? "circle" : "checkmark")
        }
    }

    private func chapterLabel(_ chapter: Chapter, read: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.displayTitle).fontWeight(.medium)
                if let note = chapter.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if read {
                Label("Read", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.papertrailDetail)
            }
        }
        .contentShape(Rectangle())
    }

    private var chapterSelectionBar: some View {
        let actions = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 4) {
            actions {
                if selectAllTask != nil {
                    SkeletonLine(label: "Loading all chapters")
                    Button(action: cancelSelectAll) {
                        Text("Cancel").frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("\(selectedChapterIDs.count) selected")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .shelfAnimation(selectedChapterIDs.count)
                    Button(action: selectAllChapters) {
                        Text(allChaptersSelected ? "Deselect All" : unreadOnly ? "Select All Unread" : "Select All")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .disabled(loading || (visibleChapters.isEmpty && nextOffset == nil))
                    .accessibilityIdentifier("select-all-chapters")
                }
            }
            .font(.footnote.weight(.medium))
            if selectAllFailed {
                Text("Couldn’t select every chapter. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            actions {
                Button("Mark read", systemImage: "checkmark") { markSelection(read: true) }
                Button("Mark unread", systemImage: "circle") { markSelection(read: false) }
            }
            .buttonStyle(.bordered)
            .disabled(selectedChapterIDs.isEmpty || selectAllTask != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func selectAllChapters() {
        guard selectAllTask == nil, !loading else { return }
        ShelfHaptics.selection.play()
        selectAllFailed = false
        if allChaptersSelected {
            selectedChapterIDs.removeAll()
        } else if let firstOffset = nextOffset, let series {
            selectAllTask = Task {
                do {
                    var additional: [Chapter] = []
                    var offset: Int? = firstOffset
                    while let current = offset {
                        let page = try await manga.provider.chapters(series, offset: current, ascending: ascending)
                        try Task.checkCancellation()
                        if let next = page.nextOffset, next <= current { throw SourceFailure.unavailable }
                        additional.append(contentsOf: page.items)
                        offset = page.nextOffset
                        if offset != nil { try await Task.sleep(for: .milliseconds(225)) }
                    }
                    appendChapters(additional)
                    nextOffset = nil
                    selectedChapterIDs = Set(visibleChapters.map(\.rowKey))
                } catch {
                    guard !Task.isCancelled else { return }
                    selectAllFailed = true
                    ShelfHaptics.error.play()
                }
                selectAllTask = nil
            }
        } else {
            selectedChapterIDs = Set(visibleChapters.map(\.rowKey))
        }
    }

    private func cancelSelectAll() {
        selectAllTask?.cancel()
        selectAllTask = nil
    }

    private func appendChapters(_ items: [Chapter]) {
        chapters = Chapter.coalesced(chapters + items.filter { $0.slug == manga.slug })
    }

    private func markSelection(read: Bool) {
        library.setRead(read, chapters: chapters.filter { selectedChapterIDs.contains($0.rowKey) })
        selectedChapterIDs.removeAll()
        selectingChapters = false
        (read ? ShelfHaptics.success : .selection).play()
    }

    private func load(offset: Int) async {
        if offset > 0 && (loading || selectAllTask != nil) { return }
        loading = true
        failure = nil
        if offset == 0 {
            chapters = []
            nextOffset = nil
        }
        defer { if !Task.isCancelled { loading = false } }
        do {
            let info = try await manga.provider.series(manga.slug)
            try Task.checkCancellation()
            series = info
            let result = try await manga.provider.chapters(info, offset: offset, ascending: ascending)
            try Task.checkCancellation()
            appendChapters(result.items)
            nextOffset = result.nextOffset
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }
}
