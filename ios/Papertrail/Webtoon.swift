import Foundation
import SwiftSoup

enum Webtoon {
    static let website = URL(string: "https://www.webtoons.com/en/")!
    private static let provider = ReadingSource.webtoon

    static func catalog() async throws -> Catalog {
        let document = try await html(website.appending(component: "originals"))
        let releases = try cards(document, selector: "a._originals_title_a:has(.badge_up2)")
        let items = releases.isEmpty ? try cards(document, selector: "a._originals_title_a") : releases
        guard !items.isEmpty else { throw SourceFailure.unavailable }
        return Catalog(featured: [], latest: items)
    }

    static func search(_ query: String) async throws -> [Manga] {
        let url = withQuery(website.appending(component: "search"), ["keyword": query])
        return try cards(await html(url), selector: "a._card_item")
    }

    static func seriesLink(_ url: URL) -> String? {
        seriesKey(url, isEpisode: false)
    }

    static func seriesURL(_ key: String) -> URL {
        let parts = key.split(separator: "/")
        guard parts.count == 3, parts[0..<2].allSatisfy(validPart), positive(parts[2]) else { return website }
        let url = website.appending(component: String(parts[0])).appending(component: String(parts[1])).appending(component: "list")
        return withQuery(url, ["title_no": String(parts[2])])
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        guard let slug = seriesKey(url, isEpisode: true),
              let titleID = slug.split(separator: "/").last,
              let episode = query(url, "episode_no"), positive(episode[...]) else { return nil }
        let parts = url.path.split(separator: "/")
        let episodeSlug = parts[parts.count - 2]
        let number = episodeSlug.firstMatch(of: #/^episode-([0-9]+)(?:-|$)/#).map { String($0.1) } ?? episode
        var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        canonical.host = website.host
        canonical.queryItems = [URLQueryItem(name: "title_no", value: String(titleID)), URLQueryItem(name: "episode_no", value: episode)]
        canonical.fragment = nil
        guard let source = canonical.url else { return nil }
        return Chapter(id: "\(titleID)/\(episode)", slug: slug, number: number, source: source, sourceID: provider)
    }

    static func series(_ slug: String) async throws -> Series {
        let url = seriesURL(slug)
        guard seriesLink(url) == slug else { throw SourceFailure.invalidLink }
        let document = try await html(url)
        guard let title = try document.select("h1.subj").first()?.text(), !title.isEmpty else { throw SourceFailure.unavailable }
        let manga = Manga(slug: slug, title: title, cover: try meta(document, "og:image"), sourceID: provider)
        let first = try document.select("a#_btnEpisode").first().flatMap { try chapter($0, slug: slug) }
        return Series(manga: manga, id: slug, synopsis: try document.select(".summary").first()?.text() ?? "", first: first)
    }

    static func chapters(_ slug: String, offset: Int, ascending: Bool) async throws -> ChapterList {
        let page = max(offset, 1)
        let url = addingQuery(seriesURL(slug), ["page": String(page), "sort": ascending ? "oldest" : "newest"])
        let document = try await html(url)
        let rows = try document.select("#_listUl li").array()
        let items = try rows.compactMap { row -> Chapter? in
            guard let anchor = try row.select("a.detail_list_link").first(),
                  var chapter = try chapter(anchor, slug: slug) else { return nil }
            chapter.note = try row.select(".date").first()?.text()
            chapter.releasedAt = ChapterReleaseDate.parse(chapter.note)
            return chapter
        }
        let next = try document.select(".paginate a[href]").array().contains { anchor in
            guard let url = SourceHTTP.url(try anchor.attr("href"), relativeTo: website),
                  let target = query(url, "page").flatMap(Int.init) else { return false }
            return target > page
        }
        return ChapterList(items: items, nextOffset: next && !items.isEmpty ? page + 1 : nil)
    }

    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        let document = try await html(chapter.source)
        let images = try pages(in: document)
        let series = try await provider.series(chapter.slug)
        let previous = try document.select("a._prevEpisode").first().flatMap { try self.chapter($0, slug: chapter.slug) }
        let next = try document.select("a._nextEpisode").first().flatMap { try self.chapter($0, slug: chapter.slug) }
        return ChapterContent(chapter: chapter, manga: series.manga, pages: images, previous: previous, next: next)
    }

    static func pages(_ chapter: Chapter) async throws -> [URL] {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        return try pages(in: await html(chapter.source))
    }

    private static func pages(in document: Document) throws -> [URL] {
        let pages = try document.select("#_imageList img._images[data-url]").array().compactMap { image -> URL? in
            guard let url = SourceHTTP.url(try image.attr("data-url")), let host = url.host,
                  ["webtoon-phinf.pstatic.net", "swebtoon-phinf.pstatic.net"].contains(host) else { return nil }
            return url
        }
        guard !pages.isEmpty else { throw SourceFailure.externalChapter }
        return pages
    }

    private static func cards(_ document: Document, selector: String) throws -> [Manga] {
        var seen = Set<String>()
        return try document.select(selector).array().compactMap { anchor in
            guard let url = SourceHTTP.url(try anchor.attr("href"), relativeTo: website),
                  let slug = seriesLink(url), seen.insert(slug).inserted, let image = try anchor.select("img").first() else { return nil }
            let imageTitle = try image.attr("alt")
            let title = try anchor.select(".title, .subj").first()?.text() ?? imageTitle
            guard !title.isEmpty else { return nil }
            let cover = try imageURL(image, relativeTo: website)
            return Manga(slug: slug, title: title, cover: cover, sourceID: provider)
        }
    }

    private static func chapter(_ anchor: Element, slug: String) throws -> Chapter? {
        guard let url = SourceHTTP.url(try anchor.attr("href"), relativeTo: website),
              let chapter = chapterLink(url), chapter.slug.split(separator: "/").last == slug.split(separator: "/").last else { return nil }
        // A WEBTOON series can move genres while its numeric title and episode IDs stay stable.
        return Chapter(id: chapter.id, slug: slug, number: chapter.number, source: chapter.source, sourceID: provider)
    }

    private static func seriesKey(_ url: URL, isEpisode: Bool) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == (isEpisode ? 5 : 4), parts[0] == "en",
              parts.last == (isEpisode ? "viewer" : "list"), parts[1..<3].allSatisfy(validPart),
              isEpisode == false || validPart(parts[3]),
              let title = query(url, "title_no"), positive(title[...]) else { return nil }
        return "\(parts[1])/\(parts[2])/\(title)"
    }

    private static func validPart(_ value: Substring) -> Bool {
        value.count < 220 && value.wholeMatch(of: #/[a-zA-Z0-9][a-zA-Z0-9_-]*/#) != nil
    }

    private static func positive(_ value: Substring) -> Bool {
        value.count < 12 && value.wholeMatch(of: #/[1-9][0-9]*/#) != nil
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func html(_ url: URL) async throws -> Document {
        try await providerMarkup(url, provider: provider)
    }
}
