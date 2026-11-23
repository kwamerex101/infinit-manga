import SwiftUI
import UIKit

enum ReadingLayout: String, CaseIterable, Identifiable {
    case automatic = "Auto spread"
    case single = "Single page"
    case vertical = "Vertical scroll"

    var id: Self { self }
}

extension Chapter {
    var displayTitle: String {
        if number.isEmpty { return "Reader" }
        if provider == .webtoon { return "Episode \(number)" }
        return number == "Oneshot" ? number : "Chapter \(number)"
    }
}

struct ReaderScreen: View {
    @Environment(ReadingStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("reading-layout") private var layout = ReadingLayout.automatic
    @AppStorage("reading-direction") private var direction = ReadingDirection.rightToLeft
    @AppStorage("reader-image-quality") private var imageQuality = ReaderImageQuality.optimized
    @State private var chapter: Chapter
    @State private var chapters: [ChapterContent] = []
    @State private var page = 0
    @State private var loadedPages: Set<Int> = []
    @State private var viewedPageEnds: Set<Int> = []
    @State private var manuallyUnread: Set<String> = []
    @State private var failedNext: (key: String, failure: SourceLoadFailure)?
    @State private var continuationRetry = 0
    @State private var spread = false
    @State private var failure: SourceLoadFailure?
    @State private var reload = 0
    @State private var caption: ControlCaption?
    @State private var showsChapters = false
    @State private var hasSidebarWidth = false

    private var hasRoomForSidebar: Bool { hasSidebarWidth && verticalSizeClass != .compact }

    init(chapter: Chapter) {
        _chapter = State(initialValue: chapter)
    }

    var body: some View {
        let book = ReadingBook(chapters, quality: imageQuality)
        let current = book.segment(at: page)
        Group {
            if let current {
                readingView(book, current: current)
                    .shelfEntrance()
            } else if let failure {
                chapterUnavailable(failure)
            } else {
                LoadingSkeleton(label: "Loading chapter") { ReaderPageSkeleton() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.papertrailInk)
        .safeAreaInset(edge: .leading, spacing: 0) {
            if hasRoomForSidebar, showsChapters, let current {
                chapterPicker(current.content, in: book)
                    .frame(width: 270)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.papertrailStroke).frame(width: 1)
                    }
                    .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 680
        } action: { isWide in
            hasSidebarWidth = isWide
        }
        .sheet(isPresented: Binding(
            get: { showsChapters && !hasRoomForSidebar && current != nil },
            set: { if !$0 && !hasRoomForSidebar { showsChapters = false } }
        )) {
            if let current {
                chapterPicker(current.content, in: book)
                    .presentationDragIndicator(.visible)
            }
        }
        .navigationTitle((current?.content.chapter ?? chapter).displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: caption?.id) {
            guard caption != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled {
                withAnimation(reduceMotion ? nil : ShelfMotion.feedback) { caption = nil }
            }
        }
        .task(id: LoadKey(id: chapter.localKey, reload: reload)) { await load(chapter) }
        .onChange(of: page) { previous, current in
            guard let active = book.segment(at: current) else { return }
            let content = active.content
            library.record(content.chapter, manga: content.manga, page: current - active.start)
            if let old = book.segment(at: previous), old.content.chapter.localKey != content.chapter.localKey {
                showCaption(content.chapter.displayTitle, icon: "book")
            }
        }
    }

    private func chapterUnavailable(_ failure: SourceLoadFailure) -> some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    ShelfStateView(failure: failure, title: "Chapter unavailable",
                                   message: "Couldn’t load this chapter from \(chapter.provider.name).",
                                   action: .init("Retry") { reload += 1 })
                    Link(destination: chapter.source) {
                        Label("Open on \(chapter.provider.name)", systemImage: "arrow.up.right")
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                    }
                }
                .padding(16)
                .frame(minHeight: viewport.size.height)
            }
        }
        .shelfEntrance()
    }

    private func readingView(_ book: ReadingBook, current: ReadingBook.Segment) -> some View {
        let quality = imageQuality
        let groups = book.groups(spread: layout == .automatic && spread)
        let group = groups.firstIndex(where: { $0.contains(page) }) ?? 0
        let visible = groups[group]
        let end = visible.last ?? page
        let next = book.nextCandidate(current: current, visibleEnd: end)
        let finished = readyToFinish(current, visible: visible)
        return Group {
            if layout == .vertical {
                ContinuousPages(pages: book.pages, quality: quality, page: $page, didLoad: markLoaded, didReachEnd: markPageEnd)
                    .transition(.opacity)
            } else {
                BookPageTurn(count: groups.count, selection: Binding(
                    get: { group }, set: { move(to: groups[$0][0]) }
                ), direction: direction, reduceMotion: reduceMotion, background: .papertrailInk) { index in
                    let indices = groups[index]
                    SpreadArt(pages: book.pages, indices: direction.isRTL ? Array(indices.reversed()) : indices,
                              quality: quality, didLoad: markLoaded, didReachEnd: markPageEnd)
                }
                .id("\(layout == .automatic && spread)-\(reduceMotion)-\(direction.rawValue)-\(quality.rawValue)")
                .transition(.opacity)
            }
        }
        .shelfAnimation(layout)
        .shelfAnimation(direction)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 560 && (proxy.size.height >= 480 || proxy.size.width > proxy.size.height)
        } action: { useSpread in
            spread = useSpread
        }
        .toolbar { readerToolbar(book, current: current, groups: groups, group: group) }
        .overlay(alignment: .topTrailing) {
            if let caption {
                Label(caption.text, systemImage: caption.icon)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .transition(reduceMotion ? .identity : .offset(y: -5).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if end == book.pages.count - 1, let next {
                if let failedNext, failedNext.key == next.localKey {
                    Button("Retry next chapter", systemImage: failedNext.failure == .offline ? "wifi.slash" : "arrow.clockwise") {
                        ShelfHaptics.tap.play()
                        retryContinuation()
                    }
                    .foregroundStyle(Color.papertrailOnAccent)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(failedNext.failure == .offline ? "No internet connection." : "The next chapter couldn’t load.")
                    .padding(12)
                } else {
                    LoadingSkeleton(label: "Loading next chapter") {
                        SkeletonBlock(radius: 8).frame(width: 118, height: 18)
                    }
                    .padding(12)
                }
            }
        }
        .task(id: PrefetchKey(chapter: current.content.chapter.localKey, end: end, count: book.pages.count, quality: quality)) {
            await prefetch(book.pages, after: end, quality: quality)
        }
        .task(id: ContinuationKey(next: next?.localKey, retry: continuationRetry)) {
            if let next { await appendChapter(next) }
        }
        .task(id: finished ? current.content.chapter.localKey : nil) {
            guard finished else { return }
            if layout != .vertical { try? await Task.sleep(for: .milliseconds(350)) }
            let key = current.content.chapter.localKey
            if !Task.isCancelled && !manuallyUnread.contains(key) {
                library.setRead(true, chapter: current.content.chapter)
            }
        }
    }

    private struct ControlCaption {
        let id = UUID()
        let text: String
        let icon: String
    }

    private func showCaption(_ text: String, icon: String) {
        withAnimation(reduceMotion ? nil : ShelfMotion.fade) {
            caption = ControlCaption(text: text, icon: icon)
        }
    }

    private func chapterPicker(_ content: ChapterContent, in book: ReadingBook) -> some View {
        ChapterPicker(manga: content.manga, current: content.chapter) { selected in
            setChaptersVisible(false)
            if selected.localKey != content.chapter.localKey {
                jump(to: selected, in: book)
            }
        } close: {
            ShelfHaptics.tap.play()
            setChaptersVisible(false)
        }
    }

    private func setChaptersVisible(_ visible: Bool) {
        withAnimation(hasRoomForSidebar && !reduceMotion ? ShelfMotion.layout : nil) {
            showsChapters = visible
        }
    }

    private var layoutPicker: some View {
        Picker("Reading layout", selection: Binding(get: { layout }, set: { option in
            guard option != layout else { return }
            layout = option
            ShelfHaptics.selection.play()
            showCaption(option.rawValue, icon: option == .vertical ? "arrow.up.and.down" : "book")
        })) {
            ForEach(ReadingLayout.allCases) { option in Text(option.rawValue).tag(option) }
        }
    }

    private var directionPicker: some View {
        Picker("Page direction", selection: Binding(get: { direction }, set: { option in
            guard direction != option else { return }
            direction = option
            ShelfHaptics.selection.play()
            showCaption(option.rawValue, icon: option.isRTL ? "arrow.left" : "arrow.right")
        })) {
            ForEach(ReadingDirection.allCases) { option in Text(option.rawValue).tag(option) }
        }
    }

    private var imageQualityPicker: some View {
        Picker("Image quality", selection: $imageQuality.withSelectionFeedback()) {
            ForEach(ReaderImageQuality.allCases) { option in Text(option.rawValue).tag(option) }
        }
    }

    @ViewBuilder
    private func readerActions(_ content: ChapterContent) -> some View {
        let read = library.progress(content.chapter).read
        Button(read ? "Mark unread" : "Mark read", systemImage: read ? "circle" : "checkmark.circle") {
            if read { manuallyUnread.insert(content.chapter.localKey) }
            else { manuallyUnread.remove(content.chapter.localKey) }
            library.setRead(!read, chapter: content.chapter)
            (read ? ShelfHaptics.selection : .success).play()
        }
        MangaSaveButton(manga: content.manga, placement: .inline)
        MangaSaveButton(manga: content.manga, kind: .readLater, placement: .inline)
        Link(destination: content.chapter.source) {
            Label("Open on \(content.chapter.provider.name)", systemImage: "arrow.up.right")
        }
    }

    private struct PrefetchKey: Equatable {
        let chapter: String
        let end: Int
        let count: Int
        let quality: ReaderImageQuality
    }

    private func prefetch(_ pages: [ReadingBook.Page], after page: Int, quality: ReaderImageQuality) async {
        for entry in pages.dropFirst(page + 1).prefix(quality == .highResolution ? 1 : 2) {
            guard !Task.isCancelled else { return }
            _ = try? await Artwork.image(at: entry.url, quality: quality,
                                          mangaDexPage: entry.chapter.provider == .mangaDex,
                                          referer: entry.chapter.provider.pageReferer, prefetch: true)
        }
    }

    private struct LoadKey: Equatable { let id: String; let reload: Int }
    private struct ContinuationKey: Equatable { let next: String?; let retry: Int }

    private func load(_ requested: Chapter) async {
        chapters = []
        caption = nil
        failure = nil
        loadedPages = []
        viewedPageEnds = []
        manuallyUnread = []
        failedNext = nil
        do {
            let loaded = try await requested.provider.content(requested)
            try Task.checkCancellation()
            page = min(max(0, library.progress(loaded.chapter).page), loaded.pages.count - 1)
            chapters = [loaded]
            library.record(loaded.chapter, manga: loaded.manga, page: page)
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }

    private func appendChapter(_ requested: Chapter) async {
        let tailID = chapters.last?.chapter.localKey
        guard failedNext?.key != requested.localKey, !chapters.contains(where: { $0.chapter.localKey == requested.localKey }) else { return }
        do {
            let release = library.readingRelease(requested)
            let loaded = try await release.provider.content(release)
            try Task.checkCancellation()
            guard chapters.last?.chapter.localKey == tailID,
                  !chapters.contains(where: { $0.chapter.localKey == loaded.chapter.localKey }) else { return }
            chapters.append(loaded)
        } catch {
            if !Task.isCancelled && chapters.last?.chapter.localKey == tailID {
                failedNext = (requested.localKey, SourceLoadFailure(error))
            }
        }
    }

    private func retryContinuation() {
        failedNext = nil
        continuationRetry += 1
    }

    private func markLoaded(_ index: Int) { loadedPages.insert(index) }

    private func markPageEnd(_ index: Int) {
        guard viewedPageEnds.insert(index).inserted, layout == .vertical else { return }
        let pages = ReadingBook(chapters, quality: imageQuality).pages
        guard pages.indices.contains(index) else { return }
        let entry = pages[index]
        if entry.isLast && loadedPages.contains(index) &&
            !manuallyUnread.contains(entry.chapter.localKey) && !library.progress(entry.chapter).read {
            library.setRead(true, chapter: entry.chapter)
        }
    }

    private func readyToFinish(_ current: ReadingBook.Segment, visible: [Int]) -> Bool {
        let last = current.end - 1
        let chapter = current.content.chapter
        return visible.contains(last) && loadedPages.contains(last) && viewedPageEnds.contains(last) &&
            !manuallyUnread.contains(chapter.localKey) && !library.progress(chapter).read
    }

    @ToolbarContentBuilder
    private func readerToolbar(_ book: ReadingBook, current: ReadingBook.Segment,
                               groups: [[Int]], group: Int) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            pageStep("chevron.left", forward: false, groups: groups, group: group)
        }
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .bottomBar) {
                positionMenu(book, segment: current, current: groups[group])
            }
            .axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .bottomBar) {
                positionMenu(book, segment: current, current: groups[group])
            }
        }
        ToolbarItem(placement: .bottomBar) {
            pageStep("chevron.right", forward: true, groups: groups, group: group)
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                setChaptersVisible(!showsChapters)
                ShelfHaptics.selection.play()
            } label: {
                Image(systemName: showsChapters ? "sidebar.left" : "list.bullet")
            }
            .tint(Color.primary)
            .accessibilityLabel(showsChapters ? "Hide chapters" : "Show chapters")
            .accessibilityIdentifier("reader-chapters")
        }
        ToolbarItem(placement: .bottomBar) {
            readerMenu(current.content)
        }
    }

    private func pageStep(_ icon: String, forward: Bool, groups: [[Int]], group: Int) -> some View {
        let target = group + (forward ? 1 : -1)
        return Button {
            guard groups.indices.contains(target) else { return }
            move(to: groups[target][0])
        } label: {
            Image(systemName: icon)
        }
        .tint(Color.primary)
        .accessibilityLabel(forward ? "Next page" : "Previous page")
        .disabled(!groups.indices.contains(target))
    }

    private func positionMenu(_ book: ReadingBook, segment: ReadingBook.Segment, current: [Int]) -> some View {
        let content = segment.content
        let total = content.pages.count
        let first = current[0] - segment.start + 1
        let label = current.count == 1 ? String(first) : "\(first)–\(first + 1)"
        let read = library.progress(content.chapter).read
        return Menu {
            if let previous = content.previous {
                Button("Previous chapter", systemImage: "backward.end") { jump(to: previous, in: book) }
            }
            if let next = content.next {
                Button("Next chapter", systemImage: "forward.end") { jump(to: next, in: book) }
            }
            Button("Go to first page", systemImage: "book") { move(to: segment.start) }
                .disabled(page == segment.start)
            Button("Go to last page", systemImage: "book.closed") { move(to: segment.end - 1) }
                .disabled(page == segment.end - 1)
        } label: {
            Group {
                if #available(iOS 27.1, *) {
                    AdaptivePageCaption(label: label, total: total)
                } else {
                    Text("\(label) / \(total)").font(.subheadline.monospacedDigit().weight(.medium))
                }
            }
            .foregroundStyle(.primary)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .shelfAnimation(label, animation: ShelfMotion.feedback)
        }
        .tint(Color.primary)
        .accessibilityLabel("Page \(label) of \(total)" + (read ? ", chapter read" : ""))
        .accessibilityHint("Shows page and chapter navigation")
        .accessibilityIdentifier("reader-position")
    }

    private func jump(to chapter: Chapter, in book: ReadingBook) {
        ShelfHaptics.selection.play()
        if let segment = book.segments.first(where: { $0.content.chapter.localKey == chapter.localKey }) {
            page = segment.start
        } else {
            self.chapter = chapter
        }
    }

    private func move(to page: Int) {
        guard self.page != page else { return }
        self.page = page
        ShelfHaptics.pageTurn.play()
    }

    private func readerMenu(_ content: ChapterContent) -> some View {
        Menu {
            layoutPicker
            directionPicker
            Divider()
            imageQualityPicker
            Divider()
            readerActions(content)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .tint(Color.primary)
        .accessibilityLabel("Reader settings")
        .accessibilityHint("Changes layout, reading direction, and image quality")
    }

}

@available(iOS 27.1, *)
struct AdaptivePageCaption: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let label: String
    let total: Int

    var body: some View {
        if edge != nil {
            VStack(spacing: 0) {
                Text(label).fontWeight(.semibold)
                Text("/ \(total)")
            }
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            Text("\(label) / \(total)").font(.subheadline.monospacedDigit().weight(.medium))
        }
    }
}

private struct ReadingBook {
    struct Segment {
        let content: ChapterContent
        let start: Int
        var end: Int { start + content.pages.count }
    }

    struct Page {
        let chapter: Chapter
        let url: URL
        let number: Int
        let isLast: Bool
    }

    let segments: [Segment]
    let pages: [Page]

    init(_ chapters: [ChapterContent], quality: ReaderImageQuality) {
        var segments: [Segment] = []
        var pages: [Page] = []
        for content in chapters {
            segments.append(Segment(content: content, start: pages.count))
            for (index, url) in content.pages(for: quality).enumerated() {
                pages.append(Page(chapter: content.chapter, url: url, number: index, isLast: index == content.pages.count - 1))
            }
        }
        self.segments = segments
        self.pages = pages
    }

    func segment(at index: Int) -> Segment? {
        segments.first { $0.start <= index && index < $0.end }
    }

    func groups(spread: Bool) -> [[Int]] {
        guard spread else { return pages.indices.map { [$0] } }
        return segments.flatMap { segment in
            stride(from: segment.start, to: segment.end, by: 2).map { Array($0..<min($0 + 2, segment.end)) }
        }
    }

    func nextCandidate(current: Segment, visibleEnd: Int) -> Chapter? {
        guard let tail = segments.last, current.start == tail.start, tail.end - visibleEnd <= 4,
              let next = tail.content.next,
              !segments.contains(where: { $0.content.chapter.localKey == next.localKey }) else { return nil }
        return next
    }
}

private struct ContinuousPages: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pages: [ReadingBook.Page]
    let quality: ReaderImageQuality
    @Binding var page: Int
    let didLoad: (Int) -> Void
    let didReachEnd: (Int) -> Void
    @State private var scrollID: Int?
    @State private var loaded: Set<Int> = []

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(pages.indices, id: \.self) { index in
                        let entry = pages[index]
                        VStack(spacing: 1) {
                            if index > 0 && entry.number == 0 {
                                Text(entry.chapter.displayTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            PageArtwork(chapter: entry.chapter, url: entry.url, page: entry.number,
                                        scrolling: true, quality: quality, active: abs(index - page) <= 1, didLoad: { _ in
                                            loaded.insert(index)
                                            didLoad(index)
                                        })
                        }
                        .background {
                            if entry.isLast && loaded.contains(index) {
                                GeometryReader { proxy in
                                    Color.clear.preference(key: EndPosition.self,
                                                           value: [index: proxy.frame(in: .named("chapter")).maxY])
                                }
                            }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .coordinateSpace(name: "chapter")
            .scrollPosition(id: $scrollID, anchor: .top)
            .onAppear { scrollID = page }
            .onChange(of: page) {
                guard scrollID != page else { return }
                let adjacent = scrollID.map { abs($0 - page) <= 2 } ?? false
                withAnimation(adjacent && !reduceMotion ? ShelfMotion.layout : nil) { scrollID = page }
            }
            .onChange(of: scrollID) {
                if let scrollID, scrollID != page { page = scrollID }
            }
            .onPreferenceChange(EndPosition.self) { frames in
                for (index, y) in frames where y <= viewport.size.height + 2 && y > 0 {
                    didReachEnd(index)
                }
            }
        }
    }

    private struct EndPosition: PreferenceKey {
        static let defaultValue: [Int: CGFloat] = [:]
        static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
        }
    }
}

struct BookPageTurn<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var selection: Int
    let direction: ReadingDirection
    let reduceMotion: Bool
    let background: Color
    var allowsGestureTurning = true
    @ViewBuilder let content: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: reduceMotion ? .scroll : .pageCurl,
            navigationOrientation: .horizontal,
            options: reduceMotion ? nil : [.spineLocation: (direction.isRTL ? UIPageViewController.SpineLocation.max : .min).rawValue]
        )
        controller.view.backgroundColor = UIColor(background)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        if let page = context.coordinator.host(selection) {
            controller.setViewControllers([page], direction: .reverse, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldCount = coordinator.parent.count
        coordinator.parent = self
        controller.view.backgroundColor = UIColor(background)
        for gesture in controller.gestureRecognizers where gesture.isEnabled != allowsGestureTurning {
            gesture.isEnabled = allowsGestureTurning
        }
        guard !coordinator.transitioning,
              let active = controller.viewControllers?.first as? PageController else { return }
        if active.index == selection {
            if oldCount != count && active.index == oldCount - 1 {
                controller.setViewControllers([active], direction: .reverse, animated: false)
            }
            return
        }
        let target = selection
        guard let next = coordinator.host(target) else { return }
        coordinator.transitioning = true
        controller.setViewControllers([next], direction: (target > active.index) == direction.isRTL ? .reverse : .forward,
                                      animated: !reduceMotion) { [weak coordinator, weak controller] _ in
            guard let coordinator, let controller else { return }
            coordinator.transitioning = false
            if coordinator.parent.selection != target, let latest = coordinator.host(coordinator.parent.selection) {
                controller.setViewControllers([latest], direction: .reverse, animated: false)
            }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: BookPageTurn
        var transitioning = false
        private var gestureStart: Int?

        init(_ parent: BookPageTurn) {
            self.parent = parent
        }

        fileprivate func host(_ index: Int) -> PageController? {
            guard (0..<parent.count).contains(index) else { return nil }
            return PageController(index: index, content: parent.content(index), background: parent.background)
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageController else { return nil }
            return host(page.index + (parent.direction.isRTL ? 1 : -1))
        }

        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? PageController else { return nil }
            return host(page.index + (parent.direction.isRTL ? -1 : 1))
        }

        func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            transitioning = true
            gestureStart = parent.selection
        }

        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            defer { gestureStart = nil }
            if gestureStart != parent.selection, let latest = host(parent.selection) {
                controller.setViewControllers([latest], direction: .reverse, animated: false)
            } else if completed, let active = controller.viewControllers?.first as? PageController,
                      (0..<parent.count).contains(active.index) {
                parent.selection = active.index
            }
        }
    }

    fileprivate final class PageController: UIHostingController<Page> {
        let index: Int

        init(index: Int, content: Page, background: Color) {
            self.index = index
            super.init(rootView: content)
            view.backgroundColor = UIColor(background)
        }

        @MainActor required dynamic init?(coder: NSCoder) { fatalError("Use init(index:content:background:)") }
    }
}

private struct SpreadArt: View {
    let pages: [ReadingBook.Page]
    let indices: [Int]
    let quality: ReaderImageQuality
    let didLoad: (Int) -> Void
    let didReachEnd: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(indices, id: \.self) { index in
                    let entry = pages[index]
                    PageArtwork(chapter: entry.chapter, url: entry.url, page: entry.number, scrolling: false, quality: quality,
                                didLoad: { _ in didLoad(index) }, didReachEnd: { _ in didReachEnd(index) })
                        .frame(width: geometry.size.width / CGFloat(indices.count))
                }
            }
        }
        .background(Color.papertrailInk)
    }
}
