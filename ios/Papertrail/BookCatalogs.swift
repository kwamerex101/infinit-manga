import Foundation
import SwiftSoup

enum StandardEbooks {
    static let website = URL(string: "https://standardebooks.org")!
    private static let catalog = website.appending(path: "ebooks")

    static func url(_ slug: String) -> URL { catalog.appending(path: slug) }

    static func slug(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == website.host, parts.first == "ebooks",
              (3...6).contains(parts.count), valid(String(parts.dropFirst().joined(separator: "/"))) else { return nil }
        return parts.dropFirst().joined(separator: "/")
    }

    static func valid(_ slug: String) -> Bool {
        slug.count < 250 && slug.wholeMatch(of: #/[a-z0-9-]+(?:\/[a-z0-9-]+){1,4}/#) != nil
    }

    static func books(_ query: String? = nil) async throws -> [Novel] {
        let url = query.map { withQuery(catalog, ["query": $0]) } ?? catalog
        let document = try await NovelSource.standardEbooks.webpage(url).1
        let books = try document.select("li[typeof=schema:Book]").array().compactMap { item -> Novel? in
            guard let link = SourceHTTP.url(try item.attr("about"), relativeTo: website), let id = slug(link),
                  let title = try item.select("p > a > span[property=schema:name]").first()?.text(),
                  !title.isEmpty else { return nil }
            let cover = try item.select("img[property=schema:image]").first().flatMap {
                try imageURL($0, relativeTo: website)
            }
            return Novel(provider: .standardEbooks, slug: id, title: title, cover: cover)
        }
        if query == nil && books.isEmpty { throw SourceFailure.unavailable }
        return books
    }

    static func details(_ novel: Novel) async throws -> NovelDetails {
        guard valid(novel.slug) else { throw SourceFailure.invalidLink }
        let document = try await NovelSource.standardEbooks.webpage(novel.url).1
        let metadata = try document.select("#description [property=schema:description]").first()?.text() ?? ""
        var book = novel
        if !metadata.isEmpty { book.synopsis = metadata }
        let toc = try await NovelSource.standardEbooks.webpage(novel.url.appending(path: "text")).1
        let links = try toc.select("#toc a[href]").array()
        var chapters: [NovelChapter] = []
        var seen = Set<URL>()
        for link in links {
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: novel.url.appending(path: "text")),
                  let chapterURL = chapterURL(url, of: novel), seen.insert(chapterURL).inserted else { continue }
            let title = try link.text()
            chapters.append(NovelChapter(number: String(chapters.count + 1), url: chapterURL, title: title))
        }
        guard !chapters.isEmpty else { throw SourceFailure.noPages }
        return NovelDetails(novel: book, chapters: chapters)
    }

    static func chapterURL(_ url: URL, of novel: Novel) -> URL? {
        let prefix = novel.url.path + "/text/"
        guard url.scheme == "https", url.host == website.host, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.path.hasPrefix(prefix) else { return nil }
        let section = String(url.path.dropFirst(prefix.count))
        guard section.wholeMatch(of: #/[a-z0-9-]+/#) != nil,
              !["titlepage", "imprint", "colophon", "uncopyright", "halftitlepage", "frontispiece", "epigraph", "list-of-illustrations"].contains(section) else { return nil }
        return novel.url.appending(path: "text").appending(component: section)
    }

    static func text(_ chapter: NovelChapter, of novel: Novel) async throws -> NovelText {
        guard chapterURL(chapter.url, of: novel) == chapter.url else { throw SourceFailure.invalidLink }
        let document = try await NovelSource.standardEbooks.webpage(chapter.url).1
        let paragraphs = try NovelSource.paragraphs(in: document, container: "main", blocks: "p, h1, h2, h3, h4, blockquote, li, dt, dd")
        func adjacent(_ relation: String, delta: Int) throws -> NovelChapter? {
            guard let link = try document.select("footer a[rel=\(relation)]").first(),
                  let raw = SourceHTTP.url(try link.attr("href"), relativeTo: chapter.url),
                  let url = chapterURL(raw, of: novel), url != chapter.url,
                  let index = Int(chapter.number), index + delta > 0 else { return nil }
            return NovelChapter(number: String(index + delta), url: url, title: try link.text())
        }
        return try NovelText(paragraphs: paragraphs, previous: adjacent("prev", delta: -1),
                             next: adjacent("next", delta: 1))
    }
}

enum NovelFull {
    static let website = URL(string: "https://novelfull.com")!
    private static let provider = NovelSource.novelFull

    static func url(_ slug: String) -> URL { website.appending(component: slug + ".html") }

    static func slug(_ url: URL) -> String? {
        guard url.scheme == "https", url.host == website.host,
              let match = url.path.wholeMatch(of: #//([a-z0-9-]{1,240})\.html/#) else { return nil }
        return String(match.1)
    }

    static func latest() async throws -> [NovelRelease] {
        let document = try await provider.webpage(website).1
        let results = try document.select(".list-new .index-intro > .row").array().compactMap { row -> NovelRelease? in
            guard let link = try row.select(".col-title h3 a[href]").first(),
                  var novel = try title(link),
                  let release = try row.select(".col-chap a[href]").first(),
                  let url = SourceHTTP.url(try release.attr("href"), relativeTo: website),
                  let chapter = chapter(url, title: try release.attr("title"), of: novel) else { return nil }
            novel.genres = try row.select(".col-cat a").array().map { try $0.text() }
            let date = ChapterReleaseDate.parse(try row.select(".col-time").first()?.text())
            return NovelRelease(novel: novel, chapter: chapter, date: date)
        }
        guard !results.isEmpty else { throw SourceFailure.unavailable }
        return results
    }

    static func search(_ query: String) async throws -> [Novel] {
        let url = withQuery(website.appending(path: "search"), ["keyword": query])
        let document = try await provider.webpage(url).1
        return try document.select(".list-truyen .row .truyen-title a[href]").array().compactMap { link in
            let row = link.parents().first { $0.hasClass("row") }
            let cover = try row?.select("img.cover").first().flatMap { try imageURL($0, relativeTo: website) }
            return try title(link, cover: cover)
        }
    }

    static func details(_ novel: Novel, ascending: Bool) async throws -> NovelDetails {
        let document = try await provider.webpage(novel.url).1
        var book = novel
        let description = try document.select(".desc-text").first()?.text() ?? ""
        if !description.isEmpty { book.synopsis = description }
        if book.cover == nil, let cover = try document.select(".book img, meta[property=og:image]").first() {
            book = Novel(provider: book.provider, slug: book.slug, title: book.title,
                         cover: try imageURL(cover, relativeTo: website) ?? SourceHTTP.url(cover.attr("content"), relativeTo: website),
                         synopsis: book.synopsis, aliases: book.aliases, genres: book.genres)
        }
        let last = try pageNumber(in: document, selector: "#list-chapter li.last a", novel: novel) ?? 1
        let initial = try chapterPage(book, document: document, offset: 0, last: last, ascending: true)
        guard !ascending, last > 1 else { return initial }
        let page = try await provider.webpage(withQuery(novel.url, ["page": String(last)])).1
        var newest = try chapterPage(book, document: page, offset: 0, last: last, ascending: false)
        newest.firstChapter = initial.firstReadableChapter
        return newest
    }

    static func nextChapters(_ details: NovelDetails, offset: Int, ascending: Bool) async throws -> NovelDetails {
        guard let seriesID = details.seriesID, let last = Int(seriesID), (1..<last).contains(offset) else {
            throw SourceFailure.invalidLink
        }
        let page = ascending ? offset + 1 : last - offset
        let document = try await provider.webpage(withQuery(details.novel.url, ["page": String(page)])).1
        return try chapterPage(details.novel, document: document, offset: offset, last: last, ascending: ascending)
    }

    static func text(_ entry: NovelChapter, of novel: Novel) async throws -> NovelText {
        guard chapter(entry.url, of: novel)?.id == entry.id else { throw SourceFailure.invalidLink }
        let document = try await provider.webpage(entry.url).1
        let paragraphs = try NovelSource.paragraphs(in: document, container: "#chapter-content")
        func adjacent(_ id: String) throws -> NovelChapter? {
            guard let link = try document.select("#\(id)[href]").first(),
                  let url = SourceHTTP.url(try link.attr("href"), relativeTo: website), url != entry.url else { return nil }
            return try chapter(url, title: link.attr("title"), of: novel)
        }
        return try NovelText(paragraphs: paragraphs, previous: adjacent("prev_chap"), next: adjacent("next_chap"))
    }

    private static func chapter(_ url: URL, title: String = "", of novel: Novel) -> NovelChapter? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == website.host, parts.count == 2, parts[0] == novel.slug,
              let match = parts[1].wholeMatch(of: #/chapter-([0-9]+(?:\.[0-9]+)?)(?:-[a-z0-9-]+)?\.html/#) else { return nil }
        return NovelChapter(number: String(match.1), url: website.appending(path: parts.joined(separator: "/")),
                            title: title.isEmpty ? nil : title)
    }

    private static func chapterPage(_ novel: Novel, document: Document, offset: Int, last: Int,
                                    ascending: Bool) throws -> NovelDetails {
        let links = try document.select("#list-chapter .list-chapter a[href]").array()
        var seen = Set<NovelChapter.ID>()
        let chapters = try links.compactMap { link -> NovelChapter? in
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  let entry = try chapter(url, title: link.attr("title"), of: novel),
                  seen.insert(entry.id).inserted else { return nil }
            return entry
        }
        guard !chapters.isEmpty else { throw SourceFailure.noPages }
        return NovelDetails(novel: novel, chapters: ascending ? chapters : Array(chapters.reversed()),
                            nextOffset: offset + 1 < last ? offset + 1 : nil, seriesID: String(last))
    }

    private static func pageNumber(in document: Document, selector: String, novel: Novel) throws -> Int? {
        guard let link = try document.select(selector).first(),
              let url = SourceHTTP.url(try link.attr("href"), relativeTo: website), slug(url) == novel.slug,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value,
              let page = Int(value), (1...10_000).contains(page) else { return nil }
        return page
    }

    private static func title(_ link: Element, cover: URL? = nil) throws -> Novel? {
        let name = try link.text()
        guard !name.isEmpty, let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
              let slug = slug(url) else { return nil }
        return Novel(provider: provider, slug: slug, title: name, cover: cover)
    }
}
