import Foundation

enum ReadingSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case roliaScan, mangaDex, mangaKatana, asuraScans, webtoon, manhuaPlus, vortexScans, brainRotComics, dynastyReader, mangapill

    var id: Self { self }

    var pageReferer: URL? {
        switch self {
        case .webtoon: URL(string: "https://www.webtoons.com/")
        case .mangapill: Mangapill.website
        default: nil
        }
    }

    var name: String {
        switch self {
        case .roliaScan: "RoliaScan"
        case .mangaDex: "MangaDex"
        case .mangaKatana: "MangaKatana"
        case .asuraScans: "Asura Scans"
        case .webtoon: "WEBTOON"
        case .manhuaPlus: "ManhuaPlus"
        case .vortexScans: "Vortex Scans"
        case .brainRotComics: "BrainRotComics"
        case .dynastyReader: "Dynasty Reader"
        case .mangapill: "Mangapill"
        }
    }

    var homepage: URL {
        switch self {
        case .roliaScan: RoliaScan.origin
        case .mangaDex: MangaDex.website
        case .mangaKatana: MangaKatana.website
        case .asuraScans: AsuraScans.website
        case .webtoon: Webtoon.website
        case .manhuaPlus: URL(string: "https://manhuaplus.org/home")!
        case .vortexScans: URL(string: "https://vortexscans.org")!
        case .brainRotComics: URL(string: "https://brainrotcomics.com")!
        case .dynastyReader: DynastyReader.website
        case .mangapill: Mangapill.website
        }
    }

    var hosts: [String] {
        switch self {
        case .roliaScan: ["roliascan.com", "www.roliascan.com"]
        case .mangaDex: ["mangadex.org", "www.mangadex.org"]
        case .mangaKatana: ["mangakatana.com", "www.mangakatana.com"]
        case .asuraScans: ["asurascans.com", "www.asurascans.com"]
        case .webtoon: ["www.webtoons.com", "webtoons.com", "m.webtoons.com"]
        case .manhuaPlus: ["manhuaplus.org", "www.manhuaplus.org"]
        case .vortexScans: ["vortexscans.org", "www.vortexscans.org"]
        case .brainRotComics: ["brainrotcomics.com", "www.brainrotcomics.com"]
        case .dynastyReader: ["dynasty-scans.com", "www.dynasty-scans.com"]
        case .mangapill: ["mangapill.com", "www.mangapill.com"]
        }
    }

    private var mangaWebsite: MangaWebsite {
        switch self {
        case .manhuaPlus: .manhuaPlus
        case .vortexScans: .vortexScans
        case .brainRotComics: .brainRotComics
        default: preconditionFailure("This source has a dedicated adapter")
        }
    }

    func localKey(_ id: String) -> String {
        // Existing RoliaScan records already use the raw source ID.
        self == .roliaScan ? id : rawValue + ":" + id
    }

    static func match(_ url: URL) -> Self? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        return allCases.first { $0.hosts.contains(host) }
    }

    func seriesURL(_ slug: String) -> URL {
        switch self {
        case .roliaScan: homepage.appending(path: "manga/\(slug)/")
        case .mangaDex: homepage.appending(path: "title/\(slug)")
        case .mangaKatana: homepage.appending(path: "manga").appending(component: slug)
        case .asuraScans: homepage.appending(component: slug)
        case .webtoon: Webtoon.seriesURL(slug)
        case .manhuaPlus, .vortexScans, .brainRotComics: mangaWebsite.seriesURL(slug)
        case .dynastyReader: DynastyReader.seriesURL(slug)
        case .mangapill: Mangapill.seriesURL(slug)
        }
    }

    func seriesLink(_ url: URL) -> String? {
        switch self {
        case .roliaScan: RoliaScan.slug(url.absoluteString)
        case .mangaDex: MangaDex.seriesID(url)
        case .mangaKatana: MangaKatana.seriesSlug(url)
        case .asuraScans: AsuraScans.seriesSlug(url)
        case .webtoon: Webtoon.seriesLink(url)
        case .manhuaPlus, .vortexScans, .brainRotComics: mangaWebsite.seriesLink(url)
        case .dynastyReader: DynastyReader.seriesLink(url)
        case .mangapill: Mangapill.seriesLink(url)
        }
    }

    func chapterLink(_ url: URL) -> Chapter? {
        switch self {
        case .roliaScan: RoliaScan.chapterLink(url.absoluteString)
        case .mangaDex: MangaDex.chapterLink(url)
        case .mangaKatana: MangaKatana.chapterLink(url)
        case .asuraScans: AsuraScans.chapterLink(url)
        case .webtoon: Webtoon.chapterLink(url)
        case .manhuaPlus, .vortexScans, .brainRotComics: mangaWebsite.chapterLink(url)
        case .dynastyReader: DynastyReader.chapterLink(url)
        case .mangapill: Mangapill.chapterLink(url)
        }
    }

    func catalog(page: Int? = nil, refresh: Bool = false) async throws -> Catalog {
        let key = SourceMemory.Item(source: self, id: page.map(String.init) ?? "first")
        return try await SourceMemory.catalogs.value(for: key, refresh: refresh) {
            switch self {
            case .roliaScan: try await RoliaScan.live.catalog(page: page)
            case .mangaDex: try await MangaDex.catalog(page: page)
            case .mangaKatana: try await MangaKatana.catalog(page: page)
            case .asuraScans: try await AsuraScans.catalog(page: page)
            case .webtoon: try await Webtoon.catalog()
            case .manhuaPlus, .vortexScans, .brainRotComics: try await mangaWebsite.catalog(page: page)
            case .dynastyReader: try await DynastyReader.catalog(page: page)
            case .mangapill: try await Mangapill.catalog()
            }
        }
    }

    func search(_ query: String) async throws -> [Manga] {
        try await SourceMemory.searches.value(for: .init(source: self, id: query)) {
            switch self {
            case .roliaScan: try await RoliaScan.live.search(query)
            case .mangaDex: try await MangaDex.search(query)
            case .mangaKatana: try await MangaKatana.search(query)
            case .asuraScans: try await AsuraScans.search(query)
            case .webtoon: try await Webtoon.search(query)
            case .manhuaPlus, .vortexScans, .brainRotComics: try await mangaWebsite.search(query)
            case .dynastyReader: try await DynastyReader.search(query)
            case .mangapill: try await Mangapill.search(query)
            }
        }
    }

    func series(_ slug: String, refresh: Bool = false) async throws -> Series {
        try await SourceMemory.series.value(for: .init(source: self, id: slug), refresh: refresh) {
            switch self {
            case .roliaScan: try await RoliaScan.live.series(slug)
            case .mangaDex: try await MangaDex.series(slug)
            case .mangaKatana: try await MangaKatana.series(slug)
            case .asuraScans: try await AsuraScans.series(slug)
            case .webtoon: try await Webtoon.series(slug)
            case .manhuaPlus, .vortexScans, .brainRotComics: try await mangaWebsite.series(slug)
            case .dynastyReader: try await DynastyReader.series(slug)
            case .mangapill: try await Mangapill.series(slug)
            }
        }
    }

    func chapters(_ series: Series, offset: Int, ascending: Bool, refresh: Bool = false) async throws -> ChapterList {
        if self == .mangaKatana { return MangaKatana.chapters(series, offset: offset, ascending: ascending) }
        if self == .asuraScans { return AsuraScans.chapters(series, offset: offset, ascending: ascending) }
        let key = SourceMemory.ChapterPage(series: .init(source: self, id: series.id), offset: offset, ascending: ascending)
        return try await SourceMemory.chapterLists.value(for: key, refresh: refresh) {
            switch self {
            case .roliaScan: try await RoliaScan.live.chapters(series.id, offset: offset, ascending: ascending)
            case .mangaDex: try await MangaDex.chapters(series.id, offset: offset, ascending: ascending)
            case .mangaKatana: MangaKatana.chapters(series, offset: offset, ascending: ascending)
            case .asuraScans: AsuraScans.chapters(series, offset: offset, ascending: ascending)
            case .webtoon: try await Webtoon.chapters(series.id, offset: offset, ascending: ascending)
            case .manhuaPlus, .vortexScans, .brainRotComics: mangaWebsite.chapters(series, offset: offset, ascending: ascending)
            case .dynastyReader: DynastyReader.chapters(series, offset: offset, ascending: ascending)
            case .mangapill: Mangapill.chapters(series, offset: offset, ascending: ascending)
            }
        }
    }

    func content(_ chapter: Chapter) async throws -> ChapterContent {
        try await SourceMemory.chapters.value(for: .init(source: self, id: chapter.source.absoluteString)) {
            switch self {
            case .roliaScan: try await RoliaScan.live.content(chapter)
            case .mangaDex: try await MangaDex.content(chapter)
            case .mangaKatana: try await MangaKatana.content(chapter)
            case .asuraScans: try await AsuraScans.content(chapter)
            case .webtoon: try await Webtoon.content(chapter)
            case .manhuaPlus, .vortexScans, .brainRotComics: try await mangaWebsite.content(chapter)
            case .dynastyReader: try await DynastyReader.content(chapter)
            case .mangapill: try await Mangapill.content(chapter)
            }
        }
    }

    func chaptersForAlerts(_ manga: Manga) async throws -> ChapterList {
        // Background expiration should cancel these requests directly.
        switch self {
        case .roliaScan:
            let series = try await RoliaScan.live.series(manga.slug)
            return try await RoliaScan.live.chapters(series.id, offset: 0, ascending: false)
        case .mangaDex:
            return try await MangaDex.chapters(manga.slug, offset: 0, ascending: false)
        case .mangaKatana:
            let series = try await MangaKatana.series(manga.slug)
            return MangaKatana.chapters(series, offset: 0, ascending: false)
        case .asuraScans:
            let series = try await AsuraScans.series(manga.slug)
            return AsuraScans.chapters(series, offset: 0, ascending: false)
        case .webtoon:
            return try await Webtoon.chapters(manga.slug, offset: 0, ascending: false)
        case .manhuaPlus, .vortexScans, .brainRotComics:
            let series = try await mangaWebsite.series(manga.slug)
            return mangaWebsite.chapters(series, offset: 0, ascending: false)
        case .mangapill:
            let series = try await Mangapill.series(manga.slug)
            return Mangapill.chapters(series, offset: 0, ascending: false)
        case .dynastyReader:
            let series = try await DynastyReader.series(manga.slug)
            return DynastyReader.chapters(series, offset: 0, ascending: false)
        }
    }

    func refreshedPage(_ chapter: Chapter, index: Int, original: URL, quality: ReaderImageQuality) async throws -> URL {
        let pages: [URL]
        switch self {
        case .roliaScan: return original
        case .mangaDex: pages = try await MangaDex.pages(chapter.id, quality: quality)
        case .mangaKatana: pages = try await MangaKatana.pages(chapter)
        case .asuraScans: pages = try await AsuraScans.pages(chapter)
        case .webtoon: pages = try await Webtoon.pages(chapter)
        case .manhuaPlus, .vortexScans, .brainRotComics: pages = try await mangaWebsite.pages(chapter)
        case .dynastyReader: pages = try await DynastyReader.pages(chapter)
        case .mangapill: pages = try await Mangapill.pages(chapter)
        }
        guard pages.indices.contains(index) else { throw SourceFailure.noPages }
        return pages[index]
    }
}

enum SourceFailure: LocalizedError {
    case invalidLink, restricted, rateLimited, unavailable, noPages, externalChapter

    var errorDescription: String? {
        switch self {
        case .invalidLink: "Enter a valid series or chapter link."
        case .restricted: "This source has restricted access to this content."
        case .rateLimited: "This source is limiting requests. Try again shortly."
        case .unavailable: "The source couldn’t load this content."
        case .noPages: "The source didn’t return readable pages."
        case .externalChapter: "This chapter is hosted on a separate publisher site."
        }
    }
}

enum SourceLoadFailure: Error, Equatable, Sendable {
    case offline
    case source(String? = nil)

    init(_ error: Error) {
        if let failure = error as? Self {
            self = failure
        } else if let error = error as? URLError,
                  error.code == .notConnectedToInternet || error.code == .dataNotAllowed {
            self = .offline
        } else if let error = error as? SourceFailure {
            self = .source(error.errorDescription)
        } else if let error = error as? RoliaScan.Failure {
            self = .source(error.errorDescription)
        } else {
            self = .source()
        }
    }

    static func combined(_ failures: [Self]) -> Self? {
        guard let first = failures.first else { return nil }
        return failures.allSatisfy { $0 == first } ? first : .source()
    }
}

enum SourceHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 18
        return URLSession(configuration: configuration)
    }()

    static func url(_ text: String, relativeTo base: URL? = nil) -> URL? {
        guard !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func data(_ url: URL, allowedHosts: [String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Papertrail/0.2 (iOS manga reader)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https",
              let host = http.url?.host, allowedHosts.contains(host) else { throw SourceFailure.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw SourceFailure.restricted
        case 429: throw SourceFailure.rateLimited
        default: throw SourceFailure.unavailable
        }
    }
}

extension Catalog {
    static func merged(_ catalogs: [Catalog], excluding existing: [Manga] = []) -> Catalog {
        let rows = catalogs.map(\.latest)
        var keys = Set(existing.map(titleKey))
        var ids = Set(existing.map(\.id))
        var latest: [Manga] = []
        for position in 0..<(rows.map(\.count).max() ?? 0) {
            for row in rows where row.indices.contains(position) {
                let item = row[position]
                guard !ids.contains(item.id), keys.insert(titleKey(for: item)).inserted else { continue }
                ids.insert(item.id)
                latest.append(item)
            }
        }
        return Catalog(featured: catalogs.flatMap(\.featured), latest: latest)
    }

    private static func titleKey(for item: Manga) -> String {
        let title = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                       locale: Locale(identifier: "en_US_POSIX"))
        let key = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return key.isEmpty ? item.id : key
    }

}
