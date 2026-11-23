import Foundation
import SwiftSoup

enum MangaKatana {
    static let website = URL(string: "https://mangakatana.com")!
    private static let provider = ReadingSource.mangaKatana

    static func catalog(page: Int? = nil) async throws -> Catalog {
        let document = try await html(page.map { website.appending(path: "page/\($0)") } ?? website)
        let items = try cards(document, limit: .max)
        guard !items.isEmpty else { throw SourceFailure.unavailable }
        let hasMore = try document.select("a.next.page-numbers").first() != nil
        return Catalog(featured: page == nil ? Array(items.prefix(1)) : [], latest: items,
                       nextPage: hasMore ? (page ?? 1) + 1 : nil)
    }

    static func search(_ query: String) async throws -> [Manga] {
        var components = URLComponents(url: website, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "search", value: query), .init(name: "search_by", value: "m_name")]
        let document = try await html(components.url!)
        if let canonical = try metadata(document, property: "og:url"),
           let slug = seriesSlug(canonical), let manga = try seriesManga(document, slug: slug) {
            return [manga]
        }
        return try cards(document)
    }

    private static func cards(_ document: Document, limit: Int = 24) throws -> [Manga] {
        try document.select("#book_list .item").array().prefix(limit).compactMap { card in
            guard let anchor = try card.select("h3.title a").first(),
                  let link = SourceHTTP.url(try anchor.attr("href"), relativeTo: website),
                  let slug = seriesSlug(link) else { return nil }
            let image = try card.select(".media img").first()
            let cover = try image.map { try $0.hasAttr("lazy-src") ? $0.attr("lazy-src") : $0.attr("src") }
            let note = try card.select("h3.title span").first()?.text().replacingOccurrences(of: " - Update chapter ", with: "Ch. ")
                .replacingOccurrences(of: "- Update chapter ", with: "Ch. ")
            return Manga(slug: slug, title: try anchor.text(), cover: cover.flatMap { SourceHTTP.url($0, relativeTo: website) },
                         note: note, sourceID: provider)
        }
    }

    static func series(_ slug: String) async throws -> Series {
        let url = provider.seriesURL(slug)
        guard seriesSlug(url) == slug else { throw SourceFailure.invalidLink }
        let document = try await html(url)
        guard let manga = try seriesManga(document, slug: slug) else { throw SourceFailure.unavailable }
        let items = try document.select(".chapters tr").array().compactMap { row -> Chapter? in
            guard let anchor = try row.select(".chapter a").first(),
                  let link = SourceHTTP.url(try anchor.attr("href"), relativeTo: website),
                  var chapter = chapterLink(link), chapter.slug == slug else { return nil }
            chapter.note = try row.select(".update_time").text()
            chapter.releasedAt = ChapterReleaseDate.parse(chapter.note)
            return chapter
        }
        return Series(manga: manga, id: slug, synopsis: try document.select(".summary").first()?.text() ?? "",
                      first: items.last, listedChapters: items)
    }

    static func chapters(_ series: Series, offset: Int, ascending: Bool) -> ChapterList {
        let source = series.listedChapters ?? []
        let items = ascending ? Array(source.reversed()) : source
        let page = Array(items.dropFirst(offset).prefix(80))
        return ChapterList(items: page, nextOffset: offset + page.count < items.count ? offset + page.count : nil)
    }

    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        let html = try await chapterHTML(chapter)
        let pages = try imageURLs(html)
        let document = try SwiftSoup.parse(html)
        let title = try document.select(".uk-breadcrumb a[href*=/manga/]").first()?.text() ?? chapter.slug
        let items = try document.select("#nav_chapters select.chapter_select option").array().compactMap { option in
            chapterLink(try provider.seriesURL(chapter.slug).appending(component: option.attr("value")))
        }
        let current = items.firstIndex { $0.id == chapter.id }
        func adjacent(_ index: Int) -> Chapter? {
            guard let current, items.indices.contains(current + index) else { return nil }
            return items[current + index]
        }

        return ChapterContent(chapter: chapter, manga: Manga(slug: chapter.slug, title: title, cover: nil, sourceID: provider),
                              pages: pages, previous: adjacent(1), next: adjacent(-1))
    }

    static func pages(_ chapter: Chapter) async throws -> [URL] {
        try imageURLs(try await chapterHTML(chapter))
    }

    static func seriesSlug(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 2, parts[0] == "manga",
              validSlug(parts[1]) else { return nil }
        return String(parts[1])
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 3, parts[0] == "manga", validSlug(parts[1]),
              parts[2].range(of: "^c[0-9]+(?:[.][0-9]+)*$", options: .regularExpression) != nil else { return nil }
        let slug = String(parts[1])
        let label = String(parts[2].dropFirst())
        return Chapter(id: slug + "/" + label, slug: slug, number: label,
                       source: provider.seriesURL(slug).appending(component: String(parts[2])), sourceID: provider)
    }

    private static func validSlug(_ slug: Substring) -> Bool {
        slug.count < 350 && slug.range(of: "^.+[.][0-9]+$", options: .regularExpression) != nil
    }

    private static func seriesManga(_ document: Document, slug: String) throws -> Manga? {
        guard let title = try document.select("h1.heading").first()?.text(), !title.isEmpty else { return nil }
        return Manga(slug: slug, title: title, cover: try metadata(document, property: "og:image"), sourceID: provider)
    }

    private static func metadata(_ document: Document, property: String) throws -> URL? {
        guard let value = try document.select("meta[property=\(property)]").first()?.attr("content") else { return nil }
        return SourceHTTP.url(value, relativeTo: website)
    }

    private static func chapterHTML(_ chapter: Chapter) async throws -> String {
        guard let link = chapterLink(chapter.source), link.id == chapter.id else { throw SourceFailure.invalidLink }
        return String(decoding: try await SourceHTTP.data(link.source, allowedHosts: provider.hosts), as: UTF8.self)
    }

    private static func html(_ url: URL) async throws -> Document {
        try SwiftSoup.parse(String(decoding: try await SourceHTTP.data(url, allowedHosts: provider.hosts), as: UTF8.self))
    }

    private static func imageURLs(_ markup: String) throws -> [URL] {
        // The public reader lists its original image URLs in this array.
        let arrayPattern = #/var\s+thzq\s*=\s*\[([^\]]+)\]/#
        let imagePattern = #/['"](https:\/\/[^'"]+)['"]/#
        let pages = markup.firstMatch(of: arrayPattern)?.1.matches(of: imagePattern).compactMap { match in
            SourceHTTP.url(String(match.1))
        } ?? []
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        return pages
    }
}
