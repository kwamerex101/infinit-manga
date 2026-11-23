import SwiftUI
import UIKit

struct NovelReadingRoute: Hashable {
    let novel: Novel
    let chapter: NovelChapter
}

enum NovelReadingLayout: String, CaseIterable, Identifiable {
    case vertical = "Continuous scroll", paged = "Horizontal pages"

    var id: Self { self }
}

enum NovelPageTheme: String, CaseIterable, Identifiable {
    case system = "App appearance", paper = "Paper", sepia = "Sepia", night = "Night"

    var id: Self { self }

    var title: String {
        switch self {
        case .paper: "White"
        case .night: "Black"
        default: rawValue
        }
    }

    var background: Color {
        switch self {
        case .system: .papertrailBackground
        case .paper: .white
        case .sepia: Color(red: 0.94, green: 0.89, blue: 0.78)
        case .night: .black
        }
    }

    var foreground: Color {
        switch self {
        case .system: .primary
        case .paper, .sepia: Color(red: 0.20, green: 0.16, blue: 0.12)
        case .night: Color(red: 0.88, green: 0.87, blue: 0.85)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .paper, .sepia: .light
        case .night: .dark
        }
    }
}

struct NovelReadingPreferences: View {
    @AppStorage("novel-reading-layout") private var layout = NovelReadingLayout.vertical
    @AppStorage("novel-text-size") private var textSize = 20.0
    @AppStorage("novel-line-spacing") private var lineSpacing = 7.0
    @AppStorage("novel-serif") private var serif = true
    @AppStorage("novel-page-theme") private var theme = NovelPageTheme.system

    var body: some View {
        Picker("Reading layout", selection: $layout.withSelectionFeedback()) {
            ForEach(NovelReadingLayout.allCases) { Text($0.rawValue).tag($0) }
        }
        .accessibilityIdentifier("novel-reading-layout")
        Stepper("Text size: \(Int(textSize)) pt", value: $textSize.withSelectionFeedback(), in: 14...36)
        Stepper("Line spacing: \(Int(lineSpacing)) pt", value: $lineSpacing.withSelectionFeedback(), in: 0...16)
        Toggle("Serif type", isOn: $serif.withSelectionFeedback())
        Picker("Page theme", selection: $theme.withSelectionFeedback()) {
            ForEach(NovelPageTheme.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct NovelReadingPosition: Hashable {
    let chapterID: String
    let paragraph: Int
    var character: Int? = nil

    var scrollAnchor: Self { Self(chapterID: chapterID, paragraph: paragraph) }
}

private struct LoadedNovelChapter: Identifiable {
    let chapter: NovelChapter
    let text: NovelText

    var id: String { chapter.id }
}

struct NovelReader: View {
    @Environment(NovelLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("novel-reading-layout") private var layout = NovelReadingLayout.vertical
    @AppStorage("novel-text-size") private var textSize = 20.0
    @AppStorage("novel-line-spacing") private var lineSpacing = 7.0
    @AppStorage("novel-serif") private var serif = true
    @AppStorage("novel-page-theme") private var theme = NovelPageTheme.system
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 1.0

    let route: NovelReadingRoute
    @State private var requestedChapter: NovelChapter
    @State private var chapters: [LoadedNovelChapter] = []
    @State private var position: NovelReadingPosition?
    @State private var scrollAnchor: NovelReadingPosition?
    @State private var initialAnchor: NovelReadingPosition?
    @State private var endReached: String?
    @State private var failure: String?
    @State private var continuationFailure: String?
    @State private var retry = 0
    @State private var showPreferences = false
    @State private var showChapterPicker = false

    init(route: NovelReadingRoute) {
        self.route = route
        _requestedChapter = State(initialValue: route.chapter)
    }

    private struct Load: Hashable {
        let chapter: NovelChapter
        let retry: Int
    }

    private var current: LoadedNovelChapter? {
        chapters.first { $0.id == position?.chapterID } ?? chapters.first
    }

    private var nextChapter: NovelChapter? {
        guard layout == .vertical, continuationFailure == nil,
              let tail = chapters.last, let position, position.chapterID == tail.id,
              endReached == tail.id || position.paragraph >= max(0, tail.text.paragraphs.count - 5),
              let next = tail.text.next, !next.locked, !chapters.contains(where: { $0.id == next.id }) else { return nil }
        return next
    }

    var body: some View {
        Group {
            if let current {
                if layout == .paged {
                    PagedNovelChapter(section: current, position: $position, size: textSize * dynamicScale,
                                      lineSpacing: lineSpacing, serif: serif, theme: theme,
                                      open: open) {
                        readerActions(current)
                    }
                    .id(current.id)
                } else {
                    continuousReader
                }
            } else if let failure {
                ShelfStateView("Couldn’t open this chapter", message: failure,
                               action: .init("Retry") { retry += 1 })
            } else {
                NovelTextSkeleton(label: "Loading chapter")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
        .navigationTitle(current?.chapter.label ?? requestedChapter.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let current, layout == .vertical {
                continuousToolbar(current)
                ToolbarItemGroup(placement: .bottomBar) { readerActions(current) }
            }
        }
        .sheet(isPresented: $showChapterPicker) {
            NovelChapterPicker(novel: route.novel, current: current?.chapter ?? requestedChapter) { chapter in
                showChapterPicker = false
                if chapter.id != current?.id { open(chapter) }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPreferences) {
            NavigationStack {
                Form { NovelReadingPreferences() }
                    .navigationTitle("Reading preferences")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPreferences = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: Load(chapter: requestedChapter, retry: retry)) { await load(requestedChapter) }
        .task(id: nextChapter) {
            if let next = nextChapter { await append(next) }
        }
        .task(id: position) {
            guard let position else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, position == self.position else { return }
            savePosition()
        }
        .onChange(of: layout) { _, selected in
            savePosition()
            if selected == .vertical { initialAnchor = position?.scrollAnchor }
        }
        .onChange(of: scenePhase) { if scenePhase != .active { savePosition() } }
        .onDisappear(perform: savePosition)
    }

    @ToolbarContentBuilder
    private func continuousToolbar(_ section: LoadedNovelChapter) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            chapterButton("Previous chapter", icon: "backward.end", chapter: section.text.previous)
        }
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .bottomBar) { paragraphMenu(section) }.axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .bottomBar) { paragraphMenu(section) }
        }
        ToolbarItem(placement: .bottomBar) {
            chapterButton("Next chapter", icon: "forward.end", chapter: section.text.next)
        }
    }

    private func chapterButton(_ title: String, icon: String, chapter: NovelChapter?) -> some View {
        Button(title, systemImage: icon) {
            if let chapter { open(chapter) }
        }
        .tint(Color.primary)
        .disabled(chapter?.locked ?? true)
    }

    private func paragraphMenu(_ section: LoadedNovelChapter) -> some View {
        let number = position?.paragraph ?? 0
        let total = section.text.paragraphs.count
        return Menu {
            Button("First paragraph", systemImage: "arrow.up.to.line") { jump(to: 0, in: section) }.disabled(number == 0)
            Button("Last paragraph", systemImage: "arrow.down.to.line") { jump(to: total - 1, in: section) }
                .disabled(number >= total - 1)
            Button("Switch to horizontal pages", systemImage: "book") {
                layout = .paged
                ShelfHaptics.selection.play()
            }
        } label: {
            if #available(iOS 27.1, *) {
                AdaptivePageCaption(label: String(number + 1), total: total)
            } else {
                Text("\(number + 1) / \(total)").font(.subheadline.monospacedDigit())
            }
        }
        .tint(Color.primary)
        .accessibilityLabel("Paragraph \(number + 1) of \(total)")
        .accessibilityIdentifier("novel-paragraph-counter")
    }

    private func jump(to paragraph: Int, in section: LoadedNovelChapter) {
        let target = NovelReadingPosition(chapterID: section.id, paragraph: paragraph)
        position = target
        initialAnchor = target
        ShelfHaptics.pageTurn.play()
    }

    @ViewBuilder
    private func readerActions(_ section: LoadedNovelChapter) -> some View {
        Button("Chapters", systemImage: "list.bullet") {
            ShelfHaptics.tap.play()
            showChapterPicker = true
        }
        .accessibilityIdentifier("novel-reader-chapters")
        .tint(Color.primary)
        readerOptions(section)
    }

    private func readerOptions(_ section: LoadedNovelChapter) -> some View {
        let read = library.progress(section.chapter).read
        return Menu {
            Section("Text size · \(Int(textSize)) pt") {
                Button("Smaller text", systemImage: "textformat.size.smaller") {
                    textSize = max(14, textSize - 1)
                    ShelfHaptics.selection.play()
                }
                .disabled(textSize <= 14)
                Button("Larger text", systemImage: "textformat.size.larger") {
                    textSize = min(36, textSize + 1)
                    ShelfHaptics.selection.play()
                }
                .disabled(textSize >= 36)
            }
            Picker("Reading layout", selection: $layout.withSelectionFeedback()) {
                ForEach(NovelReadingLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            Menu("Page theme", systemImage: "circle.lefthalf.filled") {
                Picker("Page theme", selection: $theme.withSelectionFeedback()) {
                    ForEach(NovelPageTheme.allCases) { Text($0.title).tag($0) }
                }
            }
            Button("More reading settings", systemImage: "slider.horizontal.3") { showPreferences = true }
            if layout == .paged {
                Section {
                    chapterButton("Previous chapter", icon: "backward.end", chapter: section.text.previous)
                    chapterButton("Next chapter", icon: "forward.end", chapter: section.text.next)
                }
            }
            Section {
                Button(read ? "Mark as unread" : "Mark as read", systemImage: read ? "circle" : "checkmark.circle") {
                    savePosition()
                    library.setRead(!read, chapter: section.chapter)
                    (read ? ShelfHaptics.selection : .success).play()
                }
                NovelSaveButton(novel: route.novel, shelf: .bookmarks)
                NovelSaveButton(novel: route.novel, shelf: .later)
                Link(destination: section.chapter.url) {
                    Label("Open on \(route.novel.provider.name)", systemImage: "arrow.up.right")
                }
            }
        } label: {
            Label("Reading options", systemImage: "textformat.size")
        }
        .tint(Color.primary)
        .accessibilityIdentifier("novel-reader-preferences")
    }

    private var continuousReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(chapters) { section in
                        if section.id != chapters.first?.id {
                            ShelfHeading(section.chapter.label).padding(.top, 16)
                        }
                        ForEach(section.text.paragraphs.indices, id: \.self) { index in
                            Text(section.text.paragraphs[index])
                                .font(.system(size: textSize * dynamicScale, design: serif ? .serif : .default))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.foreground)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("novel-paragraph-\(index)")
                                .id(NovelReadingPosition(chapterID: section.id, paragraph: index))
                        }
                        chapterFooter(section).padding(.top, 14)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: 650, alignment: .leading)
                .padding(.horizontal, 23)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $scrollAnchor, anchor: .top)
            .accessibilityIdentifier("novel-chapter-text")
            .task(id: initialAnchor) {
                guard let anchor = initialAnchor else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(anchor, anchor: .top)
                scrollAnchor = anchor
                initialAnchor = nil
            }
            .onChange(of: scrollAnchor) { _, anchor in
                guard initialAnchor == nil, let anchor, anchor != position?.scrollAnchor else { return }
                position = anchor
            }
        }
    }

    private func chapterFooter(_ section: LoadedNovelChapter) -> some View {
        let read = library.progress(section.chapter).read
        return VStack(spacing: 14) {
            Divider()
            Button(read ? "Mark unread" : "Mark as read", systemImage: read ? "circle" : "checkmark.circle") {
                ShelfHaptics.selection.play()
                savePosition()
                library.setRead(!read, chapter: section.chapter)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("novel-mark-read")
            if section.id == chapters.last?.id, let next = section.text.next {
                if next.locked {
                    Label("Next chapter is locked", systemImage: "lock")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let continuationFailure {
                    ShelfStateView("Couldn’t load the next chapter", message: continuationFailure,
                                   style: .compact, action: .init("Retry") { self.continuationFailure = nil })
                } else {
                    SkeletonLine(label: "Loading next chapter")
                        .accessibilityIdentifier("novel-loading-next-chapter")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { endReached = section.id }
    }

    private func open(_ chapter: NovelChapter) {
        guard !chapter.locked else { return }
        ShelfHaptics.pageTurn.play()
        savePosition()
        if requestedChapter.id == chapter.id {
            retry += 1
        }
        chapters = []
        position = nil
        requestedChapter = chapter
    }

    private func savePosition() {
        guard let position, let chapter = chapters.first(where: { $0.id == position.chapterID })?.chapter else { return }
        library.record(chapter, of: route.novel, paragraph: position.paragraph, character: position.character)
    }

    private func load(_ chapter: NovelChapter) async {
        failure = nil
        continuationFailure = nil
        endReached = nil
        do {
            let text = try await route.novel.provider.text(chapter, of: route.novel)
            try Task.checkCancellation()
            let saved = library.progress(chapter)
            let index = min(max(0, saved.paragraph), text.paragraphs.count - 1)
            guard text.paragraphs.indices.contains(index) else { throw SourceFailure.noPages }
            let restored = NovelReadingPosition(chapterID: chapter.id, paragraph: index,
                                                character: saved.character)
            scrollAnchor = nil
            initialAnchor = restored.scrollAnchor
            position = restored
            chapters = [LoadedNovelChapter(chapter: chapter, text: text)]
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    private func append(_ chapter: NovelChapter) async {
        let preceding = chapters.last?.id
        do {
            let text = try await route.novel.provider.text(chapter, of: route.novel)
            try Task.checkCancellation()
            guard chapters.last?.id == preceding, !chapters.contains(where: { $0.id == chapter.id }) else { return }
            guard !text.paragraphs.isEmpty else { throw SourceFailure.noPages }
            chapters.append(LoadedNovelChapter(chapter: chapter, text: text))
        } catch {
            guard !Task.isCancelled, chapters.last?.id == preceding else { return }
            continuationFailure = error.localizedDescription
        }
    }
}

private struct PagedNovelChapter<Actions: View>: View {
    private struct Page {
        let glyphs: NSRange
        let position: NovelReadingPosition
        let range: NSRange
        let text: String
    }

    private struct Pagination: Hashable {
        let width: CGFloat
        let height: CGFloat
        let pagesPerTurn: Int
        let size: CGFloat
        let lineSpacing: CGFloat
        let serif: Bool
        let dark: Bool
        let theme: NovelPageTheme
    }

    private struct ChapterPages {
        let pagination: Pagination
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let pages: [Page]

        var count: Int { pages.count }
        var pagesPerTurn: Int { pagination.pagesPerTurn }

        func pages(in turn: Int) -> Range<Int> {
            let first = turn * pagesPerTurn
            return first..<min(first + pagesPerTurn, count)
        }
    }

    let section: LoadedNovelChapter
    @Binding var position: NovelReadingPosition?
    let size: CGFloat
    let lineSpacing: CGFloat
    let serif: Bool
    let theme: NovelPageTheme
    let open: (NovelChapter) -> Void
    @ViewBuilder let actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var chapterPages: ChapterPages?
    @State private var selected = 0
    @State private var hingeClosed = false
    @State private var choosingPage = false

    private let pageMargin = 23.0
    private let gutter = 32.0

    var body: some View {
        if #available(iOS 27.1, *) {
            pager.onHingeChange { _, context in
                hingeClosed = context.hinge?.status == .closed
            }
        } else {
            pager
        }
    }

    private var pager: some View {
        GeometryReader { geometry in
            // The Duo cover and standard iPhones stay single-page even in landscape.
            let spread = !hingeClosed && geometry.size.width >= 560 && geometry.size.height >= 480
            let columns = spread ? 2 : 1
            let available = geometry.size.width - pageMargin * 2 - (spread ? gutter : 0)
            let request = Pagination(width: max(1, floor(min(650, available / CGFloat(columns)))),
                                     height: max(1, floor(geometry.size.height - 24)),
                                     pagesPerTurn: columns, size: size, lineSpacing: lineSpacing,
                                     serif: serif, dark: colorScheme == .dark, theme: theme)
            Group {
                if let chapterPages, chapterPages.pagination == request {
                    if chapterPages.pages.isEmpty {
                        ScrollView {
                            Text(chapterPages.storage.string)
                                .font(.system(size: size, design: serif ? .serif : .default))
                                .lineSpacing(lineSpacing)
                                .foregroundStyle(theme.foreground)
                                .textSelection(.enabled)
                                .padding(.horizontal, pageMargin)
                        }
                    } else {
                        pageTurnView(chapterPages)
                            .id(request)
                    }
                } else {
                    NovelTextSkeleton(label: "Preparing pages")
                }
            }
            .task(id: request) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                paginate(request)
            }
        }
        .toolbar {
            if let chapterPages, !chapterPages.pages.isEmpty {
                pageControls(chapterPages)
            }
            ToolbarItemGroup(placement: .bottomBar) { actions() }
        }
        .sheet(isPresented: $choosingPage) {
            if let chapterPages {
                pagePicker(chapterPages)
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func pageTurnView(_ book: ChapterPages) -> some View {
        let request = book.pagination
        let turns = (book.count + book.pagesPerTurn - 1) / book.pagesPerTurn
        return BookPageTurn(count: turns, selection: Binding(
            get: { selected },
            set: { index in
                if chapterPages?.pagination == request { move(to: index, in: book) }
            }
        ), direction: .leftToRight, reduceMotion: reduceMotion, background: theme.background) { turn in
            let visible = book.pages(in: turn)
            HStack(alignment: .top, spacing: gutter) {
                ForEach(visible, id: \.self) { index in
                    NovelPageText(manager: book.manager, glyphs: book.pages[index].glyphs,
                                  text: book.pages[index].text)
                        .frame(width: request.width, height: request.height)
                        .clipped()
                        .accessibilityIdentifier("novel-horizontal-page-\(index + 1)")
                }
                if visible.count < book.pagesPerTurn {
                    Color.clear.frame(width: request.width, height: request.height)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
            .clipped()
            .background(theme.background)
        }
        .id(reduceMotion)
    }

    @ToolbarContentBuilder
    private func pageControls(_ book: ChapterPages) -> some ToolbarContent {
        let visible = book.pages(in: selected)
        let hasPrevious = selected > 0
        let hasNext = visible.upperBound < book.count

        ToolbarItem(placement: .bottomBar) {
            Button {
                if hasPrevious { move(to: selected - 1, in: book) }
                else if let previous = section.text.previous { open(previous) }
            } label: {
                Image(systemName: hasPrevious ? "chevron.left" : "backward.end")
            }
            .tint(Color.primary)
            .accessibilityLabel(hasPrevious ? "Previous page" : "Previous chapter")
            .accessibilityIdentifier("novel-previous-page")
            .disabled(!hasPrevious && (section.text.previous?.locked ?? true))
        }
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .bottomBar) { positionMenu(book, visible: visible) }
                .axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .bottomBar) { positionMenu(book, visible: visible) }
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                if hasNext { move(to: selected + 1, in: book) }
                else if let next = section.text.next { open(next) }
            } label: {
                Image(systemName: hasNext ? "chevron.right" : "forward.end")
            }
            .tint(Color.primary)
            .accessibilityLabel(hasNext ? "Next page" : "Next chapter")
            .accessibilityIdentifier("novel-next-page")
            .disabled(!hasNext && (section.text.next?.locked ?? true))
        }
    }

    private func positionMenu(_ book: ChapterPages, visible: Range<Int>) -> some View {
        let first = visible.lowerBound + 1
        let last = visible.upperBound
        let label = visible.count > 1 ? "\(first)–\(last)" : String(first)
        return Menu {
            Button("Go to page", systemImage: "list.number") { choosingPage = true }
            Button("Go to first page", systemImage: "backward.end") { move(to: 0, in: book) }
                .disabled(first == 1)
            Button("Go to last page", systemImage: "forward.end") {
                move(to: (book.count - 1) / book.pagesPerTurn, in: book)
            }
            .disabled(last == book.count)
        } label: {
            if #available(iOS 27.1, *) {
                AdaptivePageCaption(label: label, total: book.count)
            } else {
                Text("\(label) / \(book.count)").font(.subheadline.monospacedDigit())
            }
        }
        .tint(Color.primary)
        .contentTransition(.numericText())
        .shelfAnimation(selected, animation: ShelfMotion.feedback)
        .accessibilityLabel(visible.count > 1 ? "Pages \(label) of \(book.count)" : "Page \(label) of \(book.count)")
        .accessibilityHint("Shows page navigation")
        .accessibilityIdentifier("novel-page-counter")
    }

    private func pagePicker(_ book: ChapterPages) -> some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(1...book.count, id: \.self) { page in
                    let visible = book.pages(in: selected).contains(page - 1)
                    Button {
                        choosingPage = false
                        move(to: (page - 1) / book.pagesPerTurn, in: book)
                    } label: {
                        HStack {
                            Text("Page \(page)")
                            Spacer()
                            if visible { Image(systemName: "checkmark") }
                        }
                    }
                    .id(page)
                    .accessibilityAddTraits(visible ? .isSelected : [])
                }
                .onAppear { proxy.scrollTo(book.pages(in: selected).lowerBound + 1, anchor: .center) }
            }
            .navigationTitle("Go to page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingPage = false } } }
        }
    }

    private func move(to turn: Int, in book: ChapterPages) {
        guard turn != selected, turn >= 0,
              book.pages.indices.contains(turn * book.pagesPerTurn) else { return }
        selected = turn
        ShelfHaptics.pageTurn.play()
        position = book.pages[book.pages(in: turn).lowerBound].position
    }

    private func paginate(_ request: Pagination) {
        let paragraphs = section.text.paragraphs
        var offsets: [Int] = []
        var nextOffset = 0
        for paragraph in paragraphs {
            offsets.append(nextOffset)
            nextOffset += paragraph.utf16.count + 1
        }
        let regular = UIFont.systemFont(ofSize: request.size)
        let serifDescriptor = request.serif ? regular.fontDescriptor.withDesign(.serif) : nil
        let font = serifDescriptor.map { UIFont(descriptor: $0, size: request.size) } ?? regular
        let style = NSMutableParagraphStyle()
        style.lineSpacing = request.lineSpacing
        style.paragraphSpacing = 15
        let ink = request.theme == .system
            ? (request.dark ? UIColor.white : UIColor.black)
            : UIColor(request.theme.foreground)
        let text = paragraphs.joined(separator: "\n")
        let storage = NSTextStorage(string: text, attributes: [
            .font: font, .paragraphStyle: style, .foregroundColor: ink
        ])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var pages: [Page] = []
        var end = 0
        while end < storage.length {
            let container = NSTextContainer(size: CGSize(width: request.width, height: request.height))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            if glyphs.length == 0 { break }
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard NSMaxRange(range) > end else { break }
            let index = offsets.lastIndex(where: { $0 <= range.location }) ?? 0
            let character = range.location - offsets[index]
            let anchor = NovelReadingPosition(chapterID: section.id, paragraph: index,
                                              character: character > 0 ? character : nil)
            pages.append(Page(glyphs: glyphs, position: anchor, range: range,
                              text: (text as NSString).substring(with: range)))
            end = NSMaxRange(range)
        }
        if end != storage.length { pages = [] }

        var restoredTurn = 0
        if !pages.isEmpty, let position {
            let paragraph = min(max(0, position.paragraph), offsets.count - 1)
            let character = min(max(0, position.character ?? 0), paragraphs[paragraph].utf16.count)
            let location = offsets[paragraph] + character
            let page = pages.firstIndex { NSLocationInRange(location, $0.range) } ?? (pages.count - 1)
            restoredTurn = page / request.pagesPerTurn
        }
        selected = restoredTurn
        chapterPages = ChapterPages(pagination: request, storage: storage, manager: manager, pages: pages)
    }
}

private struct NovelPageText: UIViewRepresentable {
    let manager: NSLayoutManager
    let glyphs: NSRange
    let text: String

    func makeUIView(context: Context) -> PageView {
        let view = PageView()
        view.isOpaque = false
        view.clipsToBounds = true
        view.isAccessibilityElement = true
        view.accessibilityTraits = .staticText
        return view
    }

    func updateUIView(_ view: PageView, context: Context) {
        guard view.manager !== manager || view.glyphs != glyphs else { return }
        view.manager = manager
        view.glyphs = glyphs
        view.accessibilityLabel = text
        view.setNeedsDisplay()
    }

    final class PageView: UIView {
        var manager: NSLayoutManager?
        var glyphs = NSRange()

        override func draw(_ rect: CGRect) {
            // Draw the same line fragments used to paginate, including continuations of long paragraphs.
            manager?.drawBackground(forGlyphRange: glyphs, at: .zero)
            manager?.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }
    }
}

private struct NovelChapterPicker: View {
    @Environment(\.dismiss) private var dismiss
    let novel: Novel
    let current: NovelChapter
    let open: (NovelChapter) -> Void
    @State private var details: NovelDetails?
    @State private var failure: SourceLoadFailure?
    @State private var loading = true
    @State private var attempt = 0
    @State private var query = ""
    @State private var submitted: String?

    private var search: ShelfListQuery { ShelfListQuery(query) }

    private func matches(_ chapter: NovelChapter, query: ShelfListQuery) -> Bool {
        query.matches(number: chapter.number, title: chapter.title ?? chapter.label, label: chapter.label)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let details {
                        let chapters = details.chapters.filter { matches($0, query: search) }.sorted(by: NovelChapter.earlier)
                        ForEach(chapters) { chapter in
                            Button {
                                open(chapter)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chapter.label)
                                        if let title = chapter.title, title != chapter.label {
                                            Text(title).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if chapter.id == current.id { Image(systemName: "checkmark") }
                                    if chapter.locked { Image(systemName: "lock") }
                                }
                            }
                            .disabled(chapter.locked)
                            .id(chapter.id)
                            .accessibilityAddTraits(chapter.id == current.id ? .isSelected : [])
                        }
                        if chapters.isEmpty && !search.isEmpty && !loading && failure == nil {
                            ShelfStateView("No matching chapters", message: details.nextOffset == nil
                                           ? "Try a different chapter number or title." : "Tap Go to search more chapters.",
                                           style: .compact)
                        }
                    }
                    if loading {
                        ForEach(0..<(details == nil ? 5 : 2), id: \.self) { index in
                            LoadingSkeleton(label: "Loading chapters") { ChapterRowSkeleton() }
                                .accessibilityHidden(index != 0)
                        }
                    } else if let failure {
                        ShelfStateView(failure: failure, title: "Chapters unavailable",
                                       message: "Try again to load the chapter list.", style: .compact,
                                       action: .init("Retry") { attempt += 1 })
                    } else if details?.nextOffset != nil {
                        Button("Load more chapters") { submitted = nil; attempt += 1 }
                    }
                }
                .safeAreaInset(edge: .top) {
                    ShelfListSearch(prompt: "Chapter number or title", identifier: "novel-chapter-search", query: $query) {
                        guard !loading, failure == nil else { return }
                        let request = search
                        if let chapter = details?.chapters.first(where: { matches($0, query: request) && !$0.locked }) {
                            open(chapter)
                        } else if details?.nextOffset != nil {
                            submitted = request.text
                            attempt += 1
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.papertrailBackground)
                }
                .task(id: attempt) {
                    await load()
                    if attempt == 0, search.isEmpty { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            if details == nil {
                let loaded = try await novel.provider.details(novel)
                try Task.checkCancellation()
                details = loaded
            }
            let lookup = submitted
            if let lookup, lookup == search.text {
                let request = ShelfListQuery(lookup)
                while let currentDetails = details, currentDetails.nextOffset != nil, search.text == lookup,
                      !currentDetails.chapters.contains(where: { matches($0, query: request) }) {
                    try await loadNextPage()
                }
                if search.text == lookup,
                   let found = details?.chapters.first(where: { matches($0, query: request) && !$0.locked }) {
                    open(found)
                }
            } else if attempt > 0 {
                try await loadNextPage()
            }
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }

    private func loadNextPage() async throws {
        guard let details, let offset = details.nextOffset else { return }
        let page = try await novel.provider.nextChapters(details, offset: offset)
        try Task.checkCancellation()
        if let next = page.nextOffset, next <= offset { throw SourceFailure.unavailable }
        self.details = details.merging(page)
    }
}

struct NovelSeriesView: View {
    @Environment(NovelLibrary.self) private var library
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("novel-chapters-unread-only") private var unreadOnly = false
    let novel: Novel

    @State private var details: NovelDetails?
    @State private var failure: SourceLoadFailure?
    @State private var pageFailure: SourceLoadFailure?
    @State private var retry = 0
    @State private var loadingMore = false
    @State private var ascending = false
    @State private var showingSynopsis = false
    @State private var selecting = false
    @State private var selection = Set<NovelChapter.ID>()
    @State private var selectAllTask: Task<Void, Never>?

    private struct Request: Hashable {
        let ascending: Bool
        let retry: Int
    }

    private var displayedNovel: Novel { details?.novel ?? novel }
    private var resumeChapter: NovelChapter? { library.lastRead(novel)?.chapter }

    private var visibleChapters: [NovelChapter] {
        let available = details?.chapters ?? []
        return available.filter { !unreadOnly || (!$0.locked && !library.progress($0).read) }
            .sorted { ascending ? NovelChapter.earlier($0, $1) : NovelChapter.earlier($1, $0) }
    }

    private var selectableChapters: [NovelChapter] { visibleChapters.filter { !$0.locked } }
    private var allSelected: Bool {
        details?.nextOffset == nil && !selectableChapters.isEmpty &&
            selectableChapters.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            content(side: side)
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if side { Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing)) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if side {
                        VStack(spacing: 8) {
                            NovelSaveButton(novel: displayedNovel, shelf: .bookmarks, dock: true)
                            NovelSaveButton(novel: displayedNovel, shelf: .later, dock: true)
                            readingLink(side: true)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Done" : "Select") {
                    ShelfHaptics.selection.play()
                    endSelection()
                    selecting.toggle()
                }
                .disabled(!selecting && selectableChapters.isEmpty && details?.nextOffset == nil)
                .accessibilityIdentifier("novel-select-chapters")
            }
        }
        .task(id: Request(ascending: ascending, retry: retry)) { await load() }
        .onDisappear { endSelection() }
        .shelfAnimation(selecting)
    }

    private func content(side: Bool) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 15) {
                    CoverView(url: displayedNovel.cover, mangaID: displayedNovel.id)
                        .frame(width: 90, height: 122)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayedNovel.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        if !side {
                            NovelSaveButton(novel: displayedNovel, shelf: .bookmarks).buttonStyle(.bordered)
                            NovelSaveButton(novel: displayedNovel, shelf: .later).buttonStyle(.bordered)
                        }
                        Link(destination: displayedNovel.url) {
                            Label(displayedNovel.provider.name, systemImage: "arrow.up.right").font(.footnote)
                        }
                    }
                }
                .padding(.vertical, 5)
                if !side && (resumeChapter != nil || details?.firstReadableChapter != nil) {
                    readingLink(side: false)
                }
                if !displayedNovel.synopsis.isEmpty {
                    DisclosureGroup("Synopsis", isExpanded: $showingSynopsis.withSelectionFeedback()) {
                        Text(displayedNovel.synopsis).font(.subheadline).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
            Section {
                ForEach(visibleChapters) { chapterRow($0) }
                if details == nil && failure == nil || loadingMore {
                    ForEach(0..<(details == nil ? 4 : 2), id: \.self) { index in
                        LoadingSkeleton(label: "Loading chapters") { ChapterRowSkeleton() }
                            .accessibilityHidden(index != 0)
                    }
                } else if let failure = failure ?? pageFailure {
                    ShelfStateView(failure: failure, title: "Chapters unavailable",
                                   message: "Try again to load the chapter list.", style: .compact,
                                   action: .init("Retry") { loadMoreOrRetry() })
                } else {
                    if details != nil, visibleChapters.isEmpty {
                        ShelfStateView(unreadOnly ? "No unread chapters" : "No chapters available",
                                       message: details?.nextOffset == nil && unreadOnly ? "Show all chapters to revisit them." : nil,
                                       style: .compact)
                    }
                    if let offset = details?.nextOffset {
                        Button("Load more chapters") { Task { await loadMore(offset) } }
                            .disabled(selectAllTask != nil)
                    }
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
                    .accessibilityIdentifier("novel-chapter-order")
                    .disabled(selecting || loadingMore)
                }
            }
            .shelfAnimation(visibleChapters.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar.transition(.opacity) }
        }
    }

    private func readingLink(side: Bool) -> some View {
        let chapter = resumeChapter ?? details?.firstReadableChapter
        let route = chapter.map { NovelReadingRoute(novel: displayedNovel, chapter: $0) }
        let label = resumeChapter.map { "Resume \($0.label.lowercased())" } ?? "Start reading"
        let symbol = resumeChapter == nil ? "book" : "play.fill"
        return NavigationLink(value: route) {
            if side {
                ShelfDockIcon(symbol: symbol).opacity(route == nil ? 0.45 : 1)
            } else {
                Label(label, systemImage: symbol)
            }
        }
        .disabled(route == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier("novel-start-reading")
    }

    @ViewBuilder
    private func chapterRow(_ chapter: NovelChapter) -> some View {
        let progress = library.progress(chapter)
        if chapter.locked {
            chapterLabel(chapter, progress: progress)
        } else if selecting {
            let selected = selection.contains(chapter.id)
            Button {
                if !selection.insert(chapter.id).inserted { selection.remove(chapter.id) }
                ShelfHaptics.selection.play()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.papertrailNavigation : Color.secondary)
                        .accessibilityHidden(true)
                    chapterLabel(chapter, progress: progress)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectAllTask != nil)
            .accessibilityIdentifier("novel-select-chapter-\(chapter.number)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .shelfAnimation(selected, animation: ShelfMotion.feedback)
        } else {
            NavigationLink(value: NovelReadingRoute(novel: displayedNovel, chapter: chapter)) {
                chapterLabel(chapter, progress: progress)
            }
            .accessibilityIdentifier("novel-chapter-\(chapter.number)")
            .contextMenu { readAction(chapter) }
            .swipeActions { readAction(chapter).tint(.indigo) }
            .shelfAnimation(progress.read)
        }
    }

    private func readAction(_ chapter: NovelChapter) -> some View {
        let read = library.progress(chapter).read
        return Button(read ? "Mark as Unread" : "Mark as Read", systemImage: read ? "circle" : "checkmark") {
            library.setRead(!read, chapter: chapter)
            (read ? ShelfHaptics.selection : .success).play()
        }
    }

    private func chapterLabel(_ chapter: NovelChapter, progress: NovelLibrary.Progress) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.label).fontWeight(.medium)
                if let title = chapter.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if chapter.locked {
                Label("Locked", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            } else if progress.read {
                Label("Read", systemImage: "checkmark").font(.caption.weight(.semibold))
                    .foregroundStyle(Color.papertrailDetail)
            } else if progress.paragraph > 0 {
                Text("Paragraph \(progress.paragraph + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var selectionBar: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 7)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 4) {
            layout {
                if selectAllTask != nil {
                    SkeletonLine(label: "Loading all chapters")
                    Button("Cancel") { endSelection() }.buttonStyle(.borderless)
                } else {
                    Text("\(selection.count) selected")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Button(allSelected ? "Deselect All" : unreadOnly ? "Select All Unread" : "Select All") { selectAll() }
                        .buttonStyle(.borderless)
                        .disabled(loadingMore || (selectableChapters.isEmpty && details?.nextOffset == nil))
                        .accessibilityIdentifier("novel-select-all-chapters")
                }
            }
            .font(.footnote.weight(.medium))
            layout {
                Button("Mark read", systemImage: "checkmark") { markSelection(true) }
                Button("Mark unread", systemImage: "circle") { markSelection(false) }
            }
            .buttonStyle(.bordered)
            .disabled(selection.isEmpty || selectAllTask != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func selectAll() {
        guard !loadingMore, selectAllTask == nil, let details else { return }
        ShelfHaptics.selection.play()
        if allSelected {
            selection.removeAll()
        } else if details.nextOffset == nil {
            selection = Set(selectableChapters.map(\.id))
        } else {
            let order = ascending
            pageFailure = nil
            selectAllTask = Task {
                do {
                    var combined = details
                    while let offset = combined.nextOffset {
                        let page = try await novel.provider.nextChapters(combined, offset: offset, ascending: order)
                        try Task.checkCancellation()
                        if let next = page.nextOffset, next <= offset { throw SourceFailure.unavailable }
                        combined = combined.merging(page)
                        if combined.nextOffset != nil { try await Task.sleep(for: .milliseconds(225)) }
                    }
                    self.details = combined
                    selection = Set(selectableChapters.map(\.id))
                } catch {
                    guard !Task.isCancelled else { return }
                    pageFailure = SourceLoadFailure(error)
                    ShelfHaptics.error.play()
                }
                selectAllTask = nil
            }
        }
    }

    private func endSelection() {
        selectAllTask?.cancel()
        selectAllTask = nil
        selection.removeAll()
    }

    private func markSelection(_ read: Bool) {
        library.setRead(read, chapters: (details?.chapters ?? []).filter { selection.contains($0.id) })
        endSelection()
        selecting = false
        (read ? ShelfHaptics.success : .selection).play()
    }

    private func loadMoreOrRetry() {
        if let offset = details?.nextOffset {
            Task { await loadMore(offset) }
        } else {
            retry += 1
        }
    }

    private func load() async {
        if let details, details.nextOffset == nil, failure == nil { return }
        failure = nil
        pageFailure = nil
        details = nil
        let order = ascending
        do {
            let result = try await novel.provider.details(novel, ascending: order)
            try Task.checkCancellation()
            if order == ascending { details = result }
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }

    private func loadMore(_ offset: Int) async {
        guard !loadingMore, selectAllTask == nil, let details, details.nextOffset == offset else { return }
        loadingMore = true
        pageFailure = nil
        defer { loadingMore = false }
        do {
            let page = try await novel.provider.nextChapters(details, offset: offset, ascending: ascending)
            try Task.checkCancellation()
            if let next = page.nextOffset, next <= offset { throw SourceFailure.unavailable }
            self.details = details.merging(page)
        } catch {
            if !Task.isCancelled { pageFailure = SourceLoadFailure(error) }
        }
    }
}
