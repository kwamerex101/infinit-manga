import SwiftUI
import ImageIO

enum ReaderImageQuality: String, CaseIterable, Identifiable {
    case optimized = "Optimized"
    case highResolution = "High Resolution"

    var id: Self { self }

    var targetWidth: Int { self == .optimized ? 1_400 : 2_600 }

    func thumbnailLimit(width: Double, height: Double) -> Int {
        let pixelBudget: Double = self == .optimized ? 5_000_000 : 14_000_000
        let maxEdge = max(width, height)
        let scale = min(1, Double(targetWidth) / width, sqrt(pixelBudget / (width * height)), 16_384 / maxEdge)
        return max(1, Int(maxEdge * scale))
    }
}

@MainActor
enum Artwork {
    private enum Kind: String {
        case cover
        case readerPage
        case mangaDexPage
    }

    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
    private static var pending: [String: Task<UIImage, Error>] = [:]
    private nonisolated static let coverCache = URLCache(
        memoryCapacity: 8 * 1024 * 1024,
        diskCapacity: 64 * 1024 * 1024,
        directory: CacheStorage.locations.covers
    )
    private nonisolated static let coverSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = coverCache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()
    private nonisolated static let pageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    static func cover(at url: URL, size: Int) async throws -> UIImage {
        if url.isFileURL { return try await localImage(at: url, maxPixelSize: size) }
        return try await image(at: url, size: size, kind: .cover, quality: nil,
                               referer: Mangapill.coverReferer(for: url), prefetch: false)
    }

    nonisolated static func localImage(at url: URL, maxPixelSize: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let settings = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, settings) else {
            throw SourceFailure.noPages
        }
        return UIImage(cgImage: image)
    }

    static func image(at url: URL, quality: ReaderImageQuality, mangaDexPage: Bool = false, referer: URL? = nil,
                      prefetch: Bool = false) async throws -> UIImage {
        try await image(at: url, size: quality.targetWidth, kind: mangaDexPage ? .mangaDexPage : .readerPage,
                        quality: quality, referer: referer, prefetch: prefetch)
    }

    static func clearCache() async {
        let requests = Array(pending.values)
        for request in requests { request.cancel() }
        for request in requests { _ = await request.result }
        memory.removeAllObjects()
        coverCache.removeAllCachedResponses()
        CacheStorage.clearLegacyCovers()
    }

    private static func image(at url: URL, size: Int, kind: Kind, quality: ReaderImageQuality?, referer: URL? = nil, prefetch: Bool) async throws -> UIImage {
        try Task.checkCancellation()
        let key = "\(kind.rawValue):\(quality?.rawValue ?? String(size)):\(url.absoluteString)"
        // Cover requests go through URLCache so the server's freshness and validation rules apply.
        if kind != .cover, let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = pending[key] { return try await existing.value }

        let task = Task(priority: prefetch ? .utility : .userInitiated) {
            defer { pending[key] = nil }
            let cgImage = try await decode(url, size: size, kind: kind, quality: quality, referer: referer)
            try Task.checkCancellation()
            let image = UIImage(cgImage: cgImage)
            if kind != .cover {
                memory.setObject(image, forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            }
            return image
        }
        pending[key] = task
        return try await task.value
    }

    nonisolated private static func decode(_ url: URL, size: Int, kind: Kind, quality: ReaderImageQuality?, referer: URL?) async throws -> CGImage {
        let session = kind == .cover ? coverSession : pageSession
        let started = Date()
        var status: HTTPURLResponse?
        var count = 0
        var success = false
        defer {
            if kind == .mangaDexPage {
                MangaDex.report(url: url, success: success, response: status, bytes: count, started: started)
            } else if kind == .cover, !success, status != nil {
                session.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            }
        }
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let bytes: Data
        if ReadingSource.match(url) == .brainRotComics, url.path.hasPrefix("/wp-content/uploads/") {
            bytes = try await SourceWebPage.brainRotImage(url)
        } else {
            let (body, response) = try await session.data(for: request)
            status = response as? HTTPURLResponse
            guard let status, status.url?.scheme == "https" else { throw SourceFailure.unavailable }
            switch status.statusCode {
            case 200..<300: break
            case 401, 403: throw SourceFailure.restricted
            case 429: throw SourceFailure.rateLimited
            default: throw SourceFailure.unavailable
            }
            bytes = body
        }
        count = bytes.count
        guard bytes.count <= 36 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            throw SourceFailure.noPages
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = max(1, properties?[kCGImagePropertyPixelWidth] as? Double ?? Double(size))
        let height = max(1, properties?[kCGImagePropertyPixelHeight] as? Double ?? Double(size))
        let pixelLimit = quality?.thumbnailLimit(width: width, height: height)
            ?? min(8_000, Int(Double(size) * max(1, min(3, height / width))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit
        ] as CFDictionary) else { throw SourceFailure.noPages }
        success = true
        return image
    }
}

struct CoverView: View {
    let url: URL?
    let mangaID: Manga.ID
    @State private var image: UIImage?
    @State private var unavailable = false

    private static let fallbackAssets = ["CoverFallbackMoon", "CoverFallbackCrane", "CoverFallbackPanels"]

    private var fallbackAsset: String {
        // Select the same artwork for a series across screens and app launches.
        let hash = mangaID.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        let index = Int(hash % UInt64(Self.fallbackAssets.count))
        return Self.fallbackAssets[index]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.papertrailPanel
                if image == nil, url != nil, !unavailable {
                    LoadingSkeleton(label: "Loading cover") { SkeletonBlock(radius: 8) }
                } else {
                    let cover = image.map { Image(uiImage: $0) } ?? Image(fallbackAsset)
                    cover
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                }
            }
            .shelfAnimation(image != nil)
            .shelfAnimation(unavailable)
            .clipped()
        }
        .clipShape(.rect(cornerRadius: 8))
        .task(id: url) {
            image = nil
            unavailable = false
            guard let url else { return }
            do {
                let loaded = try await Artwork.cover(at: url, size: 560)
                if !Task.isCancelled { image = loaded }
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
    }
}

struct PageArtwork: View {
    let chapter: Chapter
    let url: URL
    let page: Int
    let scrolling: Bool
    let quality: ReaderImageQuality
    var active = true
    let didLoad: (Int) -> Void
    var didReachEnd: ((Int) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure: SourceLoadFailure?
    @State private var attempt = 0

    @State private var aspectRatio: CGFloat?

    private struct LoadRequest: Equatable {
        let url: URL
        let quality: ReaderImageQuality
        let attempt: Int
        let active: Bool
    }

    private var placeholderHeight: CGFloat? { scrolling && aspectRatio == nil ? 440 : nil }

    var body: some View {
        Group {
            if let image {
                if scrolling {
                    art(image)
                } else {
                    GeometryReader { geometry in
                        let height = geometry.size.width * image.size.height / image.size.width
                        if height > geometry.size.height + 1 {
                            ScrollView(.vertical) {
                                art(image)
                                    .frame(width: geometry.size.width)
                                    .background {
                                        GeometryReader { position in
                                            Color.clear.preference(key: PageBottom.self, value: position.frame(in: .named(page)).maxY)
                                        }
                                    }
                            }
                            .coordinateSpace(name: page)
                            .onPreferenceChange(PageBottom.self) { bottom in
                                if bottom <= geometry.size.height + 2 && bottom > 0 { didReachEnd?(page) }
                            }
                            .accessibilityIdentifier("vertical-page-\(page + 1)")
                        } else {
                            art(image)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .onAppear { didReachEnd?(page) }
                        }
                    }
                }
            } else if let failure {
                ShelfStateView(failure: failure, title: "Page \(page + 1) unavailable",
                               message: "The source couldn’t load this page.",
                               style: .compact, action: .init("Retry page \(page + 1)") { attempt += 1 })
            } else {
                LoadingSkeleton(label: "Loading page \(page + 1)") {
                    ReaderPageSkeleton()
                }
                .frame(height: placeholderHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: scrolling ? nil : .infinity)
        .background(Color.papertrailInk)
        .aspectRatio(scrolling ? aspectRatio : nil, contentMode: .fit)
        .task(id: LoadRequest(url: url, quality: quality, attempt: attempt, active: active)) {
            failure = nil
            guard active else {
                image = nil
                return
            }
            do {
                let isDex = chapter.provider == .mangaDex
                let loaded: UIImage
                if attempt > 0 {
                    let refreshed = try await chapter.provider.refreshedPage(chapter, index: page, original: url, quality: quality)
                    loaded = try await Artwork.image(at: refreshed, quality: quality, mangaDexPage: isDex, referer: chapter.provider.pageReferer)
                } else {
                    do {
                        loaded = try await Artwork.image(at: url, quality: quality, mangaDexPage: isDex, referer: chapter.provider.pageReferer)
                    } catch where isDex && !Task.isCancelled && SourceLoadFailure(error) != .offline {
                        let refreshed = try await chapter.provider.refreshedPage(chapter, index: page, original: url, quality: quality)
                        loaded = try await Artwork.image(at: refreshed, quality: quality, mangaDexPage: true)
                    }
                }
                try Task.checkCancellation()
                if aspectRatio == nil { aspectRatio = loaded.size.width / loaded.size.height }
                image = loaded
                didLoad(page)
            } catch {
                if !Task.isCancelled { failure = SourceLoadFailure(error) }
            }
        }
    }

    private struct PageBottom: PreferenceKey {
        static let defaultValue = CGFloat.greatestFiniteMagnitude
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private func art(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Page \(page + 1)")
            .shelfEntrance()
    }
}
