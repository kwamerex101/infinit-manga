import Foundation
import SwiftSoup

enum Mangapill {
    static let website = URL(string: "https://mangapill.com/")!
    private static let provider = ReadingSource.mangapill

    static func coverReferer(for url: URL) -> URL? {
        url.host == "cdn.readdetectiveconan.com" && url.path.hasPrefix("/file/mangapill/i/") ? website : nil
    }

    static func seriesURL(_ id: String) -> URL {
        website.appending(path: "manga").appending(component: id)
    }

    static func seriesLink(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, (2...3).contains(parts.count), parts[0] == "manga",
              parts[1].wholeMatch(of: #/[0-9]{1,10}/#) != nil else { return nil }
        return String(parts[1])
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        guard ReadingSource.match(url) == provider,
              let match = url.path.wholeMatch(of: #//chapters/([0-9]{1,10})-([0-9]{1,10})/([a-z0-9.-]+)/?/#),
              let encoded = Int(match.2), encoded >= 10_000_000 else { return nil }
        let number = NSDecimalNumber(decimal: Decimal(encoded - 10_000_000) / 1000).stringValue
        return Chapter(id: "\(match.1)-\(match.2)", slug: String(match.1), number: number,
                       source: website.appending(path: "chapters/\(match.1)-\(match.2)/\(match.3)"),
                       sourceID: provider)
    }

    static func catalog() async throws -> Catalog {
        let url = website.appending(path: "chapters")
        let document = try await providerMarkup(url, provider: provider)
        var seen = Set<String>()
        let items = try document.select("a[href^=/manga/].text-secondary").array().compactMap { link -> Manga? in
            guard let manga = try title(link), seen.insert(manga.slug).inserted else { return nil }
            let chapter = try link.parent()?.select("a[href^=/chapters/]").first().flatMap {
                try SourceHTTP.url($0.attr("href"), relativeTo: website).flatMap(chapterLink)
            }
            var item = manga
            item.note = chapter.map { "Ch. \($0.number)" }
            return item
        }
        guard !items.isEmpty else { throw SourceFailure.unavailable }
        return Catalog(featured: [], latest: items)
    }

    static func search(_ query: String) async throws -> [Manga] {
        let url = withQuery(website.appending(path: "search"), ["q": query])
        let document = try await providerMarkup(url, provider: provider)
        var seen = Set<String>()
        return try document.select("a[href^=/manga/].mb-2").array().compactMap { link in
            let format = try link.parent()?.select(".bg-purple-500").first()?.text()
            guard !Manga.isNovelFormat(format), let manga = try title(link),
                  seen.insert(manga.slug).inserted else { return nil }
            return manga
        }
    }

    static func series(_ id: String) async throws -> Series {
        guard id.wholeMatch(of: #/[0-9]{1,10}/#) != nil else { throw SourceFailure.invalidLink }
        let document = try await providerMarkup(seriesURL(id), provider: provider)
        guard let name = try document.select("main h1, h1").first()?.text(), !name.isEmpty else {
            throw SourceFailure.unavailable
        }
        let image = try document.select("meta[property=og:image]").first()?.attr("content") ?? ""
        let synopsis = try document.select("meta[name=description]").first()?.attr("content") ?? ""
        let manga = Manga(slug: id, title: name, cover: SourceHTTP.url(image), sourceID: provider)
        var seen = Set<String>()
        let entries = try document.select("a[href^=/chapters/]").array().compactMap { link -> Chapter? in
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  let chapter = chapterLink(url), chapter.slug == id, seen.insert(chapter.id).inserted else { return nil }
            return chapter
        }
        let chapters = entries.sorted { $0.number.compare($1.number, options: .numeric) == .orderedDescending }
        return Series(manga: manga, id: id, synopsis: synopsis, first: chapters.last, listedChapters: chapters)
    }

    static func chapters(_ series: Series, offset: Int, ascending: Bool) -> ChapterList {
        let list = series.listedChapters ?? []
        let ordered = ascending ? Array(list.reversed()) : list
        let page = Array(ordered.dropFirst(offset).prefix(80))
        let next = offset + page.count
        return ChapterList(items: page, nextOffset: next < ordered.count ? next : nil)
    }

    static func pages(_ chapter: Chapter) async throws -> [URL] {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        let document = try await providerMarkup(chapter.source, provider: provider)
        let pages = try document.select("img.js-page[data-src]").array().compactMap {
            try imageURL($0, relativeTo: website)
        }
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        return pages
    }

    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        async let images = pages(chapter)
        let series = try await provider.series(chapter.slug)
        let list = series.listedChapters ?? []
        let index = list.firstIndex { $0.id == chapter.id }
        func adjacent(_ delta: Int) -> Chapter? {
            guard let index, list.indices.contains(index + delta) else { return nil }
            return list[index + delta]
        }
        return try await ChapterContent(chapter: adjacent(0) ?? chapter, manga: series.manga,
                                       pages: images, previous: adjacent(1), next: adjacent(-1))
    }

    private static func title(_ link: Element) throws -> Manga? {
        guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
              let id = seriesLink(url), let label = link.children().first() else { return nil }
        let name = try label.text()
        guard !name.isEmpty else { return nil }
        let image = try link.parent()?.parent()?.select("figure img").first().flatMap {
            try imageURL($0, relativeTo: website)
        }
        return Manga(slug: id, title: name, cover: image, sourceID: provider)
    }
}
