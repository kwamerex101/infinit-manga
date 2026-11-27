import Foundation
import SwiftSoup

struct Manga: Codable, Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let cover: URL?
    var note: String? = nil
    var sourceID: ReadingSource? = nil
    var provider: ReadingSource { sourceID ?? .roliaScan }
    var id: String { provider.localKey(slug) }
    var source: URL { provider.seriesURL(slug) }

    static func isNovelFormat(_ type: String?) -> Bool {
        let normalized = type?.lowercased().filter(\.isLetter)
        return normalized == "novel" || normalized == "webnovel" || normalized == "lightnovel"
    }
}

struct Chapter: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    var number: String
    let source: URL
    var note: String? = nil
    var sourceID: ReadingSource? = nil
    var provider: ReadingSource { sourceID ?? .roliaScan }
    var releasedAt: Date? = nil
    var requiresSourceAccess: Bool? = nil
    var releaseGroup: String? = nil
    var alternateReleases: [Chapter]? = nil
    var localKey: String { provider.localKey(id) }

    var rowKey: String {
        guard provider == .roliaScan, let number = Self.normalizedNumber(number), number != "oneshot" else { return localKey }
        return "roliaScan:\(slug)/\(number)"
    }

    var releases: [Chapter] {
        var primary = self
        primary.alternateReleases = nil
        return [primary] + (alternateReleases ?? [])
    }

    var releaseLabel: String { releaseGroup ?? "Upload \(id)" }

    func opening(_ release: Chapter) -> Chapter {
        var selected = release
        let otherReleases = releases.filter { $0.localKey != release.localKey }
        selected.alternateReleases = otherReleases.isEmpty ? nil : otherReleases
        return selected
    }

    static func coalesced(_ chapters: [Chapter]) -> [Chapter] {
        var order: [String] = []
        var groups: [String: [Chapter]] = [:]
        for chapter in chapters {
            let key = chapter.rowKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(contentsOf: chapter.releases)
        }
        return order.compactMap { key in
            var seen = Set<String>()
            let versions = (groups[key] ?? []).filter { seen.insert($0.localKey).inserted }
            guard var first = versions.first else { return nil }
            guard versions.count > 1 else { return first }
            let ranked = versions.sorted { left, right in
                let leftLow = left.releaseGroup?.localizedCaseInsensitiveContains("low quality") == true
                let rightLow = right.releaseGroup?.localizedCaseInsensitiveContains("low quality") == true
                if leftLow != rightLow { return !leftLow }
                return (Int(left.id) ?? 0) > (Int(right.id) ?? 0)
            }
            first = ranked[0]
            first.alternateReleases = Array(ranked.dropFirst())
            return first
        }
    }
}

struct Catalog: Sendable {
    let featured: [Manga]
    let latest: [Manga]
    var nextPage: Int? = nil
}

struct Series: Sendable {
    let manga: Manga
    let id: String
    let synopsis: String
    let first: Chapter?
    var listedChapters: [Chapter]? = nil
}

struct ChapterList: Sendable {
    let items: [Chapter]
    let nextOffset: Int?
}

struct ChapterContent: Sendable {
    let chapter: Chapter
    let manga: Manga
    let pages: [URL]
    let previous: Chapter?
    let next: Chapter?
    var optimizedPages: [URL]? = nil
    var deferredPages: DeferredChapterPages? = nil

    var pageCount: Int { deferredPages?.count ?? pages.count }

    func pages(for quality: ReaderImageQuality) -> [URL] {
        quality == .optimized ? optimizedPages ?? pages : pages
    }
}

struct DeferredChapterPages: Sendable {
    let count: Int
    let webPage: SourceWebPage
    let resolve: @Sendable (Int) async throws -> URL
}

struct RoliaScan {
    static let origin = URL(string: "https://roliascan.com")!
    static let live = RoliaScan()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    enum Failure: LocalizedError {
        case invalidLink, unavailable, restricted, rateLimited, noPages

        var errorDescription: String? {
            switch self {
            case .invalidLink: "Use a RoliaScan series or chapter link."
            case .unavailable: "RoliaScan could not load this content."
            case .restricted: "RoliaScan has restricted access to this content."
            case .rateLimited: "RoliaScan is limiting requests. Try again shortly."
            case .noPages: "RoliaScan did not provide any readable pages."
            }
        }
    }

    func catalog(page: Int? = nil) async throws -> Catalog {
        if let page { return try await latestPage(page) }
        let document = try await html(Self.origin.appending(path: "home/"))
        let featured = try document.select(".carousel-slide").array().compactMap { slide -> Manga? in
            guard let anchor = try slide.select("h2 a").first(),
                  let slug = Self.slug(try anchor.attr("href")) else { return nil }
            let cover = try slide.select("a img").first()?.attr("src")
            return Manga(slug: slug, title: try anchor.text(), cover: cover.flatMap(Self.secureURL))
        }
        let latest = try document.select("#manga-grid > div").array().compactMap { card -> Manga? in
            guard let image = try card.select("img").first(),
                  let link = try card.select("a[href*=/manga/]").first(),
                  let slug = Self.slug(try link.attr("href")) else { return nil }
            return Manga(slug: slug, title: try image.attr("alt"), cover: Self.secureURL(try image.attr("src")),
                         note: try card.select("a[href*=/read/]").first()?.text())
        }
        guard !featured.isEmpty || !latest.isEmpty else { throw Failure.unavailable }
        return Catalog(featured: featured, latest: latest, nextPage: latest.isEmpty ? nil : 2)
    }

    private func latestPage(_ page: Int) async throws -> Catalog {
        struct Response: Decodable {
            struct Item: Decodable {
                let title: String
                let cover: String?
                let manga_permalink: String?
                let permalink: String
                let chapter: String?
            }
            let success: Bool
            let data: [Item]
            let has_more: Bool
        }
        var request = URLRequest(url: endpoint("wp-json/manga/v1/latest-chapters", ["page": String(page)]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response: Response = try await json(request)
        guard response.success else { throw Failure.unavailable }
        let latest = response.data.compactMap { item -> Manga? in
            let chapter = Self.chapterLink(item.permalink)
            guard let slug = item.manga_permalink.flatMap(Self.slug) ?? chapter?.slug else { return nil }
            let number = item.chapter ?? chapter?.number
            return Manga(slug: slug, title: item.title, cover: item.cover.flatMap(Self.secureURL),
                         note: number.map { "Ch. \($0)" })
        }
        guard response.data.isEmpty || !latest.isEmpty else { throw Failure.unavailable }
        return Catalog(featured: [], latest: latest, nextPage: response.has_more && !response.data.isEmpty ? page + 1 : nil)
    }

    struct SearchItem: Decodable {
        let title: String
        let permalink: String
        let thumbnail: String?
        let type: String?
        let description: String?
        let altTitles: [String]?

        enum CodingKeys: String, CodingKey {
            case title, permalink, thumbnail, type, description
            case altTitles = "alt_titles"
        }
    }

    func searchEntries(_ query: String) async throws -> [SearchItem] {
        struct Result: Decodable {
            let success: Bool
            let results: [SearchItem]?
        }
        var request = URLRequest(url: endpoint("auth/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "limit": 24])
        let result: Result = try await json(request)
        guard result.success else { throw Failure.unavailable }
        return result.results ?? []
    }

    func search(_ query: String) async throws -> [Manga] {
        try await searchEntries(query).compactMap {
            guard !Manga.isNovelFormat($0.type), let slug = Self.slug($0.permalink) else { return nil }
            return Manga(slug: slug, title: $0.title, cover: $0.thumbnail.flatMap(Self.secureURL), note: $0.type)
        }
    }

    func series(_ slug: String) async throws -> Series {
        guard Self.validSlug(slug) else { throw Failure.invalidLink }
        let document = try await html(Self.origin.appending(path: "manga/\(slug)/"))
        guard let id = try document.body()?.attr("data-manga-id"), Int(id) != nil else { throw Failure.unavailable }
        let cover = try document.select("meta[property=og:image]").first()?.attr("content")
        let title = try document.select("[data-manga-title]").first()?.attr("data-manga-title")
            ?? document.select("h1").first()?.text() ?? slug
        let first = try document.select("a[href*=/read/\(slug)/]").first()?.attr("href")
        return Series(
            manga: Manga(slug: slug, title: title, cover: cover.flatMap(Self.secureURL)),
            id: id,
            synopsis: try document.select("#description-content-tab").text(),
            first: first.flatMap { Self.chapterLink($0) }
        )
    }

    func chapters(_ id: String, offset: Int, ascending: Bool, textOnly: Bool = false) async throws -> ChapterList {
        struct Result: Decodable {
            struct Item: Decodable {
                let chapter: String
                let date: String?
                let url: String
                let group_name: String?
                let chapter_type: String?
            }
            let success: Bool
            let chapters: [Item]?
            let has_more: Bool?
        }
        let url = endpoint("auth/manga-chapters", [
            "manga_id": id, "offset": String(offset), "limit": "80", "order": ascending ? "asc" : "desc"
        ])
        let result: Result = try await json(URLRequest(url: url))
        guard result.success else { throw Failure.unavailable }
        let chapters = result.chapters ?? []
        let fetchedAt = Date.now
        let items = chapters.map { item -> Chapter? in
            guard !textOnly || item.chapter_type == "text" else { return nil }
            guard var link = Self.chapterLink(item.url, number: item.chapter) else { return nil }
            link.note = item.date
            link.releasedAt = ChapterReleaseDate.parse(item.date, relativeTo: fetchedAt)
            link.releaseGroup = item.group_name
            return link
        }
        var count = items.count
        let hasMore = result.has_more == true && count > 0
        if hasMore, let last = items.last ?? nil, last.rowKey != last.localKey {
            // Keep the final numbered chapter together if its releases straddle two API pages.
            let start = items.lastIndex { $0?.rowKey != last.rowKey }.map { $0 + 1 } ?? 0
            if start > 0 { count = start }
        }
        return ChapterList(items: Chapter.coalesced(items.prefix(count).compactMap { $0 }),
                           nextOffset: hasMore ? offset + count : nil)
    }

    func content(_ chapter: Chapter) async throws -> ChapterContent {
        struct Result: Decodable {
            let success: Bool
            let images: [String]?
        }
        guard Self.chapterLink(chapter.source.absoluteString)?.id == chapter.id else { throw Failure.invalidLink }
        async let markup = html(chapter.source)
        let result: Result = try await json(URLRequest(url: endpoint("auth/chapter-content", ["chapter_id": chapter.id])))
        guard result.success else { throw Failure.unavailable }
        let pages = (result.images ?? []).compactMap(Self.secureURL)
        guard !pages.isEmpty else { throw Failure.noPages }

        let document = try await markup
        guard try document.body()?.attr("data-chapter-id") == chapter.id else { throw Failure.unavailable }
        let number = try document.body()?.attr("data-chapter-number") ?? chapter.number
        let heading = try document.select("#reader-media").first()?.attr("data-chapter-title")
            ?? document.select("h1").first()?.text() ?? chapter.slug
        let suffix = " Chapter " + number
        let title = heading.lowercased().hasSuffix(suffix.lowercased()) ? String(heading.dropLast(suffix.count)) : heading
        let cover = try document.select("[data-manga-cover]").first()?.attr("data-manga-cover")
        let options = try document.select("#chapter-select option").array().compactMap { option in
            Self.chapterLink(try option.attr("value"))
        }.filter { $0.slug == chapter.slug }
        var current = chapter
        current.number = number
        let groups = Chapter.coalesced([current] + options)
        if let matching = groups.first(where: { $0.rowKey == current.rowKey }) {
            current = matching.opening(current)
        }

        let active = options.firstIndex { $0.localKey == current.localKey }
        func adjacent(_ distance: Int, titlePrefix: String) throws -> Chapter? {
            func versions(_ link: Chapter) -> Chapter {
                groups.first(where: { $0.rowKey == link.rowKey }) ?? link
            }
            if let href = try document.select("a[title^=\(titlePrefix):]").first()?.attr("href"),
               let link = Self.chapterLink(href), link.slug == current.slug, link.rowKey != current.rowKey {
                return versions(link)
            }
            guard let active else { return nil }
            var index = active + distance
            while options.indices.contains(index) {
                let option = options[index]
                if option.rowKey != current.rowKey { return versions(option) }
                index += distance
            }
            return nil
        }
        return ChapterContent(
            chapter: current,
            manga: Manga(slug: chapter.slug, title: title, cover: cover.flatMap(Self.secureURL)),
            pages: pages,
            previous: try adjacent(-1, titlePrefix: "Prev"),
            next: try adjacent(1, titlePrefix: "Next")
        )
    }

    static func slug(_ link: String) -> String? {
        guard let url = secureURL(link), url.host == origin.host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "manga", validSlug(String(parts[1])) else { return nil }
        return String(parts[1])
    }

    static func chapterLink(_ link: String, number: String? = nil) -> Chapter? {
        guard let url = secureURL(link), url.host == origin.host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "read", validSlug(String(parts[1])),
              let range = parts[2].range(of: "^ch([0-9a-z-]+)-[0-9]{1,12}$", options: .regularExpression),
              let split = parts[2].lastIndex(of: "-") else { return nil }
        let id = String(parts[2][parts[2].index(after: split)...])
        let label = number ?? parts[2][range.lowerBound..<split].dropFirst(2).replacingOccurrences(of: "-", with: ".")
        return Chapter(id: id, slug: String(parts[1]), number: label, source: url)
    }

    private static func validSlug(_ slug: String) -> Bool {
        slug.range(of: "^[a-z0-9][a-z0-9-]{0,180}$", options: .regularExpression) != nil
    }

    private static func secureURL(_ string: String) -> URL? {
        guard !string.isEmpty, let url = URL(string: string, relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func endpoint(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: Self.origin.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == Self.origin.host else { throw Failure.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw Failure.restricted
        case 429: throw Failure.rateLimited
        default: throw Failure.unavailable
        }
    }

    private func html(_ url: URL) async throws -> Document {
        let bytes = try await data(URLRequest(url: url))
        return try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))
    }

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(request))
    }
}
