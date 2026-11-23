import SwiftUI
import UIKit

struct ComicReader: View {
    @Environment(ComicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let route: ComicReadingRoute

    @State private var pages: [URL] = []
    @State private var page = 0
    @State private var failure: SourceLoadFailure?
    @State private var attempt = 0
    @State private var showsPagePicker = false
    @State private var showsOriginalIssue = false
    @State private var showsNote = false
    @State private var note: String?
    @State private var pageQuery = ""
    @State private var loadedPages: Set<Int> = []
    @State private var zoomedPage: Int?
    @State private var skippedOpeningPages: Int?

    var body: some View {
        Group {
            if pages.indices.contains(page) {
                if route.series.source.isWebtoon {
                    pageView(page, turn: { offset in turn(to: page + offset) })
                        .id(page)
                } else {
                    BookPageTurn(count: pages.count, selection: Binding(get: { page }, set: turn(to:)),
                                 direction: .leftToRight, reduceMotion: reduceMotion, background: .papertrailInk,
                                 allowsGestureTurning: zoomedPage != page) { index in
                        pageView(index, zoomChanged: { zoomed in
                            if page == index { zoomedPage = zoomed ? index : nil }
                        })
                    }
                    .id(reduceMotion)
                }
            } else if let failure {
                ShelfStateView(failure: failure, title: "Issue unavailable", message: "Try again to load the pages.",
                               style: .standard, action: .init("Retry") { attempt += 1 })
            } else {
                LoadingSkeleton(label: "Loading issue") { ReaderPageSkeleton() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let skippedOpeningPages, page == skippedOpeningPages {
                let message = skippedOpeningPages == 1 ? "XOXO didn’t provide page 1."
                    : "XOXO didn’t provide pages 1–\(skippedOpeningPages)."
                HStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                    Spacer(minLength: 0)
                    Button("Dismiss page notice", systemImage: "xmark") { self.skippedOpeningPages = nil }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.leading, 12)
                .background(Color.papertrailPanel)
                .accessibilityIdentifier("xoxo-missing-opening-pages")
            }
        }
        .background(Color.papertrailBackground.ignoresSafeArea())
        .navigationTitle(route.issue.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !pages.isEmpty { controls }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if note != nil {
                        Button("Creator’s note", systemImage: "text.quote") { showsNote = true }
                    }
                    if route.series.source == .xoxo {
                        Button("Open original", systemImage: "arrow.up.right") { openOriginalIssue() }
                    } else if route.issue.downloadID == nil || route.series.website.scheme == "https" {
                        Link(destination: route.issue.downloadID == nil ? route.issue.website : route.series.website) {
                            Label("Open original", systemImage: "arrow.up.right")
                        }
                    }
                } label: {
                    Label("Comic options", systemImage: "ellipsis.circle")
                }
            }
        }
        .onChange(of: page) { previous, _ in
            if skippedOpeningPages == previous { skippedOpeningPages = nil }
            if zoomedPage != page { zoomedPage = nil }
            recordLoadedPage(page)
        }
        .alert("Creator’s note", isPresented: $showsNote) {
            Button("Done", role: .cancel) {}
        } message: {
            if let note { Text(note) }
        }
        .fullScreenCover(isPresented: $showsOriginalIssue) {
            let url = page == 0 ? route.issue.website : route.issue.website.appending(component: String(page + 1))
            InAppWebsiteBrowser(site: .xoxoComics, url: url)
        }
        .sheet(isPresented: $showsPagePicker) {
            NavigationStack {
                ScrollViewReader { proxy in
                    let query = ShelfListQuery(pageQuery)
                    let matches = pages.indices.filter {
                        query.matches(number: String($0 + 1), title: "Page \($0 + 1)")
                    }
                    List {
                        ForEach(matches, id: \.self) { index in
                            Button {
                                turn(to: index)
                                showsPagePicker = false
                            } label: {
                                HStack {
                                    Text("Page \(index + 1)")
                                    Spacer()
                                    if index == page {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .accessibilityAddTraits(index == page ? .isSelected : [])
                            .id(index)
                        }
                        if matches.isEmpty {
                            ShelfStateView("No matching pages", message: "Enter a page from 1 to \(pages.count).", style: .compact)
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        ShelfListSearch(prompt: "Page number", identifier: "comic-page-search", query: $pageQuery)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.papertrailBackground)
                    }
                    .onAppear { proxy.scrollTo(page, anchor: .center) }
                }
                .navigationTitle("Go to page")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDragIndicator(.visible)
        }
        .task(id: attempt) {
            failure = nil
            do {
                let loaded: ComicPages
                if let id = route.issue.downloadID {
                    loaded = ComicPages(images: try ComicDownload.pages(id))
                } else {
                    loaded = try await route.series.source.pages(for: route.issue)
                }
                guard !loaded.images.isEmpty else { throw SourceFailure.noPages }
                let saved = library.progress(route.issue)?.page
                let openingPage = route.series.source == .xoxo && saved == nil
                    ? try? await XOXOComics.firstReadablePage(of: route.issue, pages: loaded.images, from: 0) : nil
                try Task.checkCancellation()
                if let openingPage, openingPage > 0 { skippedOpeningPages = openingPage }
                page = min(max(0, saved ?? openingPage ?? 0), loaded.images.count - 1)
                note = loaded.note
                pages = loaded.images
            } catch {
                if !Task.isCancelled { failure = SourceLoadFailure(error) }
            }
        }
    }

    private func pageView(_ index: Int, turn: ((Int) -> Void)? = nil,
                          zoomChanged: ((Bool) -> Void)? = nil) -> some View {
        let xoxo = route.series.source == .xoxo
        let canLookAhead = xoxo && pages.indices.contains(index + 1)
        return ComicPage(url: pages[index], referer: pageReferer, webtoonLayout: route.series.source.isWebtoon,
                         number: index + 1, openOriginalIssue: xoxo ? openOriginalIssue : nil,
                         checkFollowingPages: canLookAhead ? { try await findReadablePage(after: index) } : nil,
                         didLoad: {
            loadedPages.insert(index)
            recordLoadedPage(index)
        }, turn: turn, zoomChanged: zoomChanged)
    }

    private func findReadablePage(after index: Int) async throws -> Bool {
        guard let next = try await XOXOComics.firstReadablePage(of: route.issue, pages: pages, from: index + 1) else {
            return false
        }
        try Task.checkCancellation()
        if page == index { turn(to: next) }
        return true
    }

    private func openOriginalIssue() {
        ShelfHaptics.tap.play()
        showsOriginalIssue = true
    }

    private func recordLoadedPage(_ index: Int) {
        guard page == index, loadedPages.contains(index) else { return }
        library.record(route, page: index, pageCount: pages.count)
    }

    private var pageReferer: URL? {
        if route.series.source == .xoxo { return route.issue.website.appending(component: "all") }
        return route.series.source.referer
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Previous page", systemImage: "chevron.left") { turn(to: page - 1) }
                .tint(Color.primary)
                .disabled(page == 0)
                .accessibilityIdentifier("comic-previous-page")
        }
        if #available(iOS 27.1, *) {
            ToolbarItem(placement: .bottomBar) { pageCounter }.axisBehavior(.verticalPreferred)
        } else {
            ToolbarItem(placement: .bottomBar) { pageCounter }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Next page", systemImage: "chevron.right") { turn(to: page + 1) }
                .tint(Color.primary)
                .disabled(page == pages.count - 1)
                .accessibilityIdentifier("comic-next-page")
        }
    }

    private var pageCounter: some View {
        Button {
            ShelfHaptics.tap.play()
            pageQuery = ""
            showsPagePicker = true
        } label: {
            if #available(iOS 27.1, *) {
                AdaptivePageCaption(label: String(page + 1), total: pages.count)
            } else {
                Text("\(page + 1) / \(pages.count)").font(.subheadline.monospacedDigit())
            }
        }
        .tint(Color.primary)
        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
        .accessibilityHint("Choose a page")
        .accessibilityIdentifier("comic-page-counter")
        .contentTransition(.numericText())
        .shelfAnimation(page, animation: ShelfMotion.feedback)
    }

    private func turn(to index: Int) {
        guard pages.indices.contains(index), index != page else { return }
        ShelfHaptics.pageTurn.play()
        page = index
    }
}

private struct ComicPage: View {
    let url: URL
    let referer: URL?
    let webtoonLayout: Bool
    let number: Int
    let openOriginalIssue: (() -> Void)?
    let checkFollowingPages: (() async throws -> Bool)?
    let didLoad: () -> Void
    let turn: ((Int) -> Void)?
    let zoomChanged: ((Bool) -> Void)?

    @State private var image: UIImage?
    @State private var failure: SourceLoadFailure?
    @State private var attempt = 0
    @State private var missingXOXOImage = false
    @State private var checkingPages = false
    @State private var recoveryMessage: String?

    var body: some View {
        Group {
            if let image {
                Group {
                    if webtoonLayout {
                        GeometryReader { frame in
                            let width = min(frame.size.width, 640)
                            let height = width * image.size.height / max(1, image.size.width)
                            if height > frame.size.height {
                                ScrollView {
                                    Image(uiImage: image).resizable().frame(width: width, height: height)
                                        .frame(maxWidth: .infinity)
                                }
                            } else {
                                ComicZoomView(image: image, turn: turn, zoomChanged: zoomChanged)
                            }
                        }
                    } else {
                        ComicZoomView(image: image, turn: turn, zoomChanged: zoomChanged)
                    }
                }
                .accessibilityLabel("Comic page \(number)")
                .accessibilityIdentifier("comic-page-image-\(number)")
            } else if let failure {
                VStack(spacing: 8) {
                    ShelfStateView(failure: failure, title: "Page \(number) unavailable", message: "Try again to load this page.",
                                   style: .compact, action: .init("Retry page \(number)") { attempt += 1 })
                    if missingXOXOImage, checkFollowingPages != nil {
                        Button("Check following pages", systemImage: "chevron.right") {
                            ShelfHaptics.tap.play()
                            recoveryMessage = nil
                            checkingPages = true
                        }
                        .disabled(checkingPages)
                        .accessibilityIdentifier("xoxo-check-following-pages")
                        if checkingPages {
                            LoadingSkeleton(label: "Checking following pages") { SkeletonBlock(radius: 6).frame(width: 116, height: 14) }
                        } else if let recoveryMessage {
                            Text(recoveryMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let openOriginalIssue, failure != .offline {
                        Button(action: openOriginalIssue) {
                            Label("Open issue on XOXO Comics", systemImage: "arrow.up.right")
                                .font(.subheadline)
                                .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("comic-open-issue-original")
                    }
                }
            } else {
                LoadingSkeleton(label: "Loading page \(number)") { ReaderPageSkeleton() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.papertrailInk)
        .task(id: checkingPages) {
            guard checkingPages, let checkFollowingPages else { return }
            defer { checkingPages = false }
            do {
                if try await !checkFollowingPages() && !Task.isCancelled {
                    recoveryMessage = "XOXO didn’t provide images for the next pages checked."
                }
            } catch {
                if !Task.isCancelled { recoveryMessage = error.localizedDescription }
            }
        }
        .task(id: attempt) {
            failure = nil
            missingXOXOImage = false
            recoveryMessage = nil
            do {
                let loaded: UIImage
                if url.isFileURL {
                    loaded = try await Artwork.localImage(at: url, maxPixelSize: ReaderImageQuality.highResolution.targetWidth)
                } else {
                    loaded = try await Artwork.image(at: url, quality: .highResolution, referer: referer)
                }
                try Task.checkCancellation()
                image = loaded
                didLoad()
            } catch {
                if !Task.isCancelled {
                    if openOriginalIssue != nil, case .noPages? = error as? SourceFailure {
                        missingXOXOImage = true
                        failure = .source("XOXO didn’t send an image for this page.")
                    } else {
                        failure = SourceLoadFailure(error)
                    }
                }
            }
        }
    }
}

private struct ComicZoomView: UIViewRepresentable {
    let image: UIImage
    let turn: ((Int) -> Void)?
    let zoomChanged: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        let imageView = context.coordinator.imageView
        imageView.image = image
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        if turn != nil {
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
                swipe.direction = direction
                swipe.delegate = context.coordinator
                scroll.addGestureRecognizer(swipe)
                scroll.panGestureRecognizer.require(toFail: swipe)
            }
        } else {
            scroll.panGestureRecognizer.isEnabled = false
        }
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.turn = turn
        context.coordinator.zoomChanged = zoomChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(turn: turn, zoomChanged: zoomChanged) }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = UIImageView()
        var turn: ((Int) -> Void)?
        var zoomChanged: ((Bool) -> Void)?
        private var zoomed = false

        init(turn: ((Int) -> Void)?, zoomChanged: ((Bool) -> Void)?) {
            self.turn = turn
            self.zoomChanged = zoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard turn == nil else { return }
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard isZoomed != zoomed else { return }
            zoomed = isZoomed
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            zoomChanged?(isZoomed)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = gestureRecognizer.view as? UIScrollView else { return false }
            return scroll.zoomScale <= scroll.minimumZoomScale + 0.01
        }

        @objc func swipe(_ gesture: UISwipeGestureRecognizer) {
            turn?(gesture.direction == .left ? 1 : -1)
        }
    }
}
