import Foundation
import SwiftSoup

enum DynastyReader {
    static let website = URL(string: "https://dynasty-scans.com")!
    private static let provider = ReadingSource.dynastyReader

    static func catalog(page: Int?) async throws -> Catalog {
        let document = try await html(page.map { withQuery(website, ["page": String($0)]) } ?? website)
        var seen = Set<String>()
        let items = try document.select("a.chapter.media.thumbnail").array().compactMap { card -> Manga? in
            guard let url = SourceHTTP.url(try card.attr("href"), relativeTo: website),
                  let chapter = chapterLink(url), seen.insert(chapter.slug).inserted,
                  let title = try card.select(".title").first()?.text(), !title.isEmpty else { return nil }
            let cover = try card.select("img").first().flatMap { try imageURL($0, relativeTo: website) }
            return Manga(slug: chapter.slug, title: title, cover: cover, sourceID: provider)
        }
        guard !items.isEmpty else { throw SourceFailure.unavailable }
        let next = try document.select("a[rel=next]").first() != nil
        return Catalog(featured: [], latest: items, nextPage: next ? (page ?? 1) + 1 : nil)
    }

    static func search(_ query: String) async throws -> [Manga] {
        let url = withQuery(website.appending(component: "search"), ["q": query])
        let document = try await html(url)
        var seen = Set<String>()
        return try document.select("a.name[href]").array().compactMap { link in
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  let slug = seriesLink(url) ?? chapterLink(url)?.slug,
                  seen.insert(slug).inserted else { return nil }
            return Manga(slug: slug, title: try link.text(), cover: nil, sourceID: provider)
        }
    }

    static func seriesURL(_ slug: String) -> URL {
        if slug.hasPrefix("release/") {
            return website.appending(component: "chapters").appending(component: String(slug.dropFirst("release/".count)))
        }
        return website.appending(component: "series").appending(component: slug)
    }

    static func seriesLink(_ url: URL) -> String? {
        resource(url, under: "series")
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        guard let id = resource(url, under: "chapters") else { return nil }
        let numbered = id.wholeMatch(of: #/(.+)_ch([0-9]+(?:[._][0-9]+)?)/#)
        let number = numbered.map { normalize(String($0.2)) } ?? "Oneshot"
        let slug = numbered.map { String($0.1) } ?? "release/" + id
        return Chapter(id: id, slug: slug, number: number,
                       source: website.appending(component: "chapters").appending(component: id), sourceID: provider)
    }

    static func series(_ slug: String) async throws -> Series {
        let url = seriesURL(slug)
        if slug.hasPrefix("release/"), let release = chapterLink(url) {
            let document = try await html(url)
            let title = try document.select("#chapter-title b").first()?.text() ?? release.number
            let manga = Manga(slug: slug, title: title, cover: nil, sourceID: provider)
            let chapter = Chapter(id: release.id, slug: slug, number: release.number, source: release.source, sourceID: provider)
            return Series(manga: manga, id: slug, synopsis: "", first: chapter, listedChapters: [chapter])
        }
        guard seriesLink(url) == slug else { throw SourceFailure.invalidLink }
        let document = try await html(url)
        guard let title = try document.select("h2.tag-title b").first()?.text(), !title.isEmpty else { throw SourceFailure.unavailable }
        let cover = try document.select(".cover img.thumbnail").first().flatMap { try imageURL($0, relativeTo: website) }
        let manga = Manga(slug: slug, title: title, cover: cover, sourceID: provider)
        let chapters = try document.select("dl.chapter-list dd").array().compactMap { row -> Chapter? in
            guard let link = try row.select("a.name[href]").first(),
                  let url = SourceHTTP.url(try link.attr("href"), relativeTo: website), let release = chapterLink(url) else { return nil }
            let raw = try link.text()
            let number = raw.firstMatch(of: #/(?:Chapter|ch)\s+([0-9]+(?:\.[0-9]+)?)/#).map { normalize(String($0.1)) } ?? release.number
            let note = try row.select("small").first()?.text()
            let date = note.flatMap { value in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "MMM d ''yy"
                return formatter.date(from: String(value.dropFirst("released ".count)))
            }
            return Chapter(id: release.id, slug: slug, number: number, source: release.source,
                           note: note, sourceID: provider, releasedAt: date)
        }
        return Series(manga: manga, id: slug, synopsis: try document.select(".description").first()?.text() ?? "",
                      first: chapters.first, listedChapters: Array(chapters.reversed()))
    }

    static func chapters(_ series: Series, offset: Int, ascending: Bool) -> ChapterList {
        let list = series.listedChapters ?? []
        let ordered = ascending ? Array(list.reversed()) : list
        let items = Array(ordered.dropFirst(offset).prefix(80))
        let next = offset + items.count
        return ChapterList(items: items, nextOffset: next < ordered.count ? next : nil)
    }

    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        let document = try await readerDocument(chapter)
        let pages = try images(document)
        let title = try document.select("#chapter-title b").first()?.text() ?? chapter.number
        let seriesKey = try document.select("#chapter-title b a[href]").first().flatMap {
            SourceHTTP.url(try $0.attr("href"), relativeTo: website).flatMap(seriesLink)
        }
        let key = seriesKey ?? "release/" + chapter.id
        guard let series = try? await provider.series(key) else {
            return ChapterContent(chapter: chapter, manga: Manga(slug: key, title: title, cover: nil, sourceID: provider),
                                  pages: pages, previous: nil, next: nil)
        }
        let list = series.listedChapters ?? []
        let index = list.firstIndex { $0.id == chapter.id }
        func item(_ offset: Int) -> Chapter? {
            guard let index, list.indices.contains(index + offset) else { return nil }
            return list[index + offset]
        }
        return ChapterContent(chapter: item(0) ?? chapter, manga: series.manga, pages: pages, previous: item(1), next: item(-1))
    }

    static func pages(_ chapter: Chapter) async throws -> [URL] {
        try images(await readerDocument(chapter))
    }

    private static func normalize(_ number: String) -> String {
        let text = number.replacingOccurrences(of: "_", with: ".")
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            .map { NSDecimalNumber(decimal: $0).stringValue } ?? text
    }

    private static func resource(_ url: URL, under directory: String) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 2, parts[0] == directory,
              parts[1].count < 250, parts[1].wholeMatch(of: #/[a-zA-Z0-9_-]+/#) != nil else { return nil }
        return String(parts[1])
    }

    private static func html(_ url: URL) async throws -> Document {
        try await providerMarkup(url, provider: provider)
    }

    private static func readerDocument(_ chapter: Chapter) async throws -> Document {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        return try await html(chapter.source)
    }

    private static func images(_ document: Document) throws -> [URL] {
        struct Page: Decodable { let image: String }
        for script in try document.select("script:not([src])").array() {
            guard let json = script.data().firstMatch(of: #/var\s+pages\s*=\s*(\[[^\r\n]*\])\s*;/#)?.1 else { continue }
            let items = try JSONDecoder().decode([Page].self, from: Data(json.utf8))
            let pages = items.compactMap { SourceHTTP.url($0.image, relativeTo: website) }.filter {
                $0.host == website.host && $0.path.hasPrefix("/system/releases/")
            }
            if !pages.isEmpty && pages.count == items.count { return pages }
        }
        throw SourceFailure.noPages
    }
}
