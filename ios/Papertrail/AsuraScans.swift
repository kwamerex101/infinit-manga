import Foundation
import SwiftSoup

enum AsuraScans {
    static let website = URL(string: "https://asurascans.com/comics")!
    private static let api = URL(string: "https://api.asurascans.com/api")!
    private static let provider = ReadingSource.asuraScans

    static func catalog(page: Int? = nil) async throws -> Catalog {
        let page = page ?? 1
        let size = 20
        let response: Results<Comic> = try await get("series", query: [
            .init(name: "sort", value: "latest"),
            .init(name: "order", value: "desc"),
            .init(name: "limit", value: String(size)),
            .init(name: "offset", value: String((page - 1) * size)),
        ])
        let items = response.data.filter { !Manga.isNovelFormat($0.type) }.compactMap(\.manga)
        return Catalog(featured: [], latest: items,
                       nextPage: response.meta?.hasMore == true && !response.data.isEmpty ? page + 1 : nil)
    }

    static func search(_ query: String) async throws -> [Manga] {
        let response: Results<Comic> = try await get("search", query: [.init(name: "q", value: query)])
        return response.data.filter { !Manga.isNovelFormat($0.type) }.compactMap(\.manga)
    }

    static func series(_ slug: String) async throws -> Series {
        guard validSlug(slug) else { throw SourceFailure.invalidLink }
        async let details: Details = get("series/\(slug)")
        async let list: Results<Release> = get("series/\(slug)/chapters")
        let (info, releases) = try await (details, list)
        guard let manga = info.series.manga, manga.slug == slug else { throw SourceFailure.unavailable }
        let chapters = releases.data.sorted { $0.number > $1.number }.map { release in
            let number = NSDecimalNumber(decimal: release.number).stringValue
            let date = ChapterReleaseDate.parse(release.publishedAt)
            let dateLabel = date?.formatted(.relative(presentation: .named))
            let note = release.isPremium
                ? [dateLabel, "Asura+"].compactMap { $0 }.joined(separator: " · ")
                : dateLabel
            var chapter = chapter(slug: slug, number: number, note: note, date: date)
            chapter.requiresSourceAccess = release.isPremium
            return chapter
        }
        let synopsis = try SwiftSoup.parseBodyFragment(info.series.description ?? "").text()
        return Series(manga: manga, id: slug, synopsis: synopsis, first: chapters.last(where: { $0.requiresSourceAccess == false }), listedChapters: chapters)
    }

    static func chapters(_ series: Series, offset: Int, ascending: Bool) -> ChapterList {
        let chapters = series.listedChapters ?? []
        let ordered = ascending ? Array(chapters.reversed()) : chapters
        let items = Array(ordered.dropFirst(offset).prefix(80))
        let next = offset + items.count
        return ChapterList(items: items, nextOffset: next < ordered.count ? next : nil)
    }

    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        let (series, chapters, index) = try await release(for: chapter)
        let current = chapters[index]
        let pages = try await publicPages(current)
        func adjacent(_ offset: Int) -> Chapter? {
            let target = index + offset
            guard chapters.indices.contains(target), chapters[target].requiresSourceAccess == false else { return nil }
            return chapters[target]
        }
        return ChapterContent(chapter: current, manga: series.manga, pages: pages,
                              previous: adjacent(1), next: adjacent(-1))
    }

    static func pages(_ chapter: Chapter) async throws -> [URL] {
        let (_, chapters, index) = try await release(for: chapter)
        return try await publicPages(chapters[index])
    }

    private static func release(for chapter: Chapter) async throws -> (Series, [Chapter], Int) {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        let series = try await provider.series(chapter.slug)
        guard let chapters = series.listedChapters,
              let index = chapters.firstIndex(where: { $0.id == chapter.id }) else { throw SourceFailure.unavailable }
        guard chapters[index].requiresSourceAccess == false else { throw SourceFailure.restricted }
        return (series, chapters, index)
    }

    private static func publicPages(_ chapter: Chapter) async throws -> [URL] {
        let page = try await SourceWebPage.load(chapter.source, hosts: provider.hosts)
        guard chapterLink(page.url)?.id == chapter.id else { throw SourceFailure.restricted }
        let document = try SwiftSoup.parse(page.html)
        let images = try document.select("div[data-page] > img[alt^=Page ]").array()
        var pages: [URL] = []
        for image in images {
            guard let parent = image.parent(), try Int(parent.attr("data-page")) == pages.count,
                  let url = SourceHTTP.url(try image.attr("src")), url.host == "cdn.asurascans.com",
                  url.path.hasPrefix("/asura-images/chapters/") else { throw SourceFailure.noPages }
            pages.append(url)
        }
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        return pages
    }

    static func seriesSlug(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 2, parts[0] == "comics",
              validSlug(String(parts[1])) else { return nil }
        return String(parts[1])
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 4, parts[0] == "comics",
              validSlug(String(parts[1])), parts[2] == "chapter",
              parts[3].wholeMatch(of: #/[0-9]+(?:\.[0-9]+)?/#) != nil,
              let number = Decimal(string: String(parts[3]), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return chapter(slug: String(parts[1]), number: NSDecimalNumber(decimal: number).stringValue)
    }

    private static func validSlug(_ slug: String) -> Bool {
        slug.count <= 300 && slug.wholeMatch(of: #/[a-z0-9]+(?:-[a-z0-9]+)*/#) != nil
    }

    private static func chapter(slug: String, number: String, note: String? = nil, date: Date? = nil) -> Chapter {
        Chapter(id: slug + "/" + number, slug: slug, number: number,
                source: provider.seriesURL(slug).appending(path: "chapter/\(number)"),
                note: note, sourceID: provider, releasedAt: date)
    }

    private static func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let data = try await SourceHTTP.data(components.url!, allowedHosts: ["api.asurascans.com"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private struct Results<Item: Decodable>: Decodable {
        struct Metadata: Decodable {
            let hasMore: Bool?
        }

        let data: [Item]
        let meta: Metadata?
    }

    private struct Details: Decodable {
        let series: Comic
    }

    private struct Comic: Decodable {
        let title: String
        let type: String?
        let cover: String?
        let description: String?
        let publicUrl: String
        let latestChapters: [Release]?

        var manga: Manga? {
            guard let url = SourceHTTP.url(publicUrl, relativeTo: website), let slug = seriesSlug(url) else { return nil }
            let number = latestChapters?.first.map { NSDecimalNumber(decimal: $0.number).stringValue }
            return Manga(slug: slug, title: title, cover: cover.flatMap { SourceHTTP.url($0) },
                         note: number.map { "Ch. \($0)" }, sourceID: provider)
        }
    }

    private struct Release: Decodable {
        let number: Decimal
        let publishedAt: String?
        let isPremium: Bool
    }
}
