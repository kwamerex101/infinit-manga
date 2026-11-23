import Foundation
import SwiftSoup

func withQuery(_ url: URL, _ items: [String: String]) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = items.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.url!
}

func addingQuery(_ url: URL, _ items: [String: String]) -> URL {
    let existing = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    var merged = items
    for item in existing where merged[item.name] == nil { merged[item.name] = item.value }
    return withQuery(url, merged)
}

func providerMarkup(_ url: URL, provider: ReadingSource, useWebKit: Bool = false) async throws -> Document {
    guard ReadingSource.match(url) == provider else { throw SourceFailure.invalidLink }
    if useWebKit {
        return try SwiftSoup.parse(await SourceWebPage.load(url, hosts: provider.hosts, keepsWebsiteSession: provider == .brainRotComics).html)
    }
    let bytes = try await SourceHTTP.data(url, allowedHosts: provider.hosts)
    return try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))
}

func imageURL(_ image: Element, relativeTo base: URL) throws -> URL? {
    for attribute in ["data-src", "data-url", "src"] {
        let value = try image.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = SourceHTTP.url(value, relativeTo: base) { return url }
    }
    return nil
}

func meta(_ document: Document, _ property: String) throws -> URL? {
    let value = try document.select("meta[property=\(property)]").first()?.attr("content") ?? ""
    return SourceHTTP.url(value)
}

struct MangaWebsite {
    let provider: ReadingSource
    let prefix: String
    let catalogPath: String
    let cardSelector: String
    let chapterSelector: String
    let imageSelector: String

    static let manhuaPlus = Self(provider: .manhuaPlus, prefix: "manga", catalogPath: "home",
                                 cardSelector: "a:has(img[alt])", chapterSelector: "#myUL li.chapter",
                                 imageSelector: "#chapterContent img")
    static let vortexScans = Self(provider: .vortexScans, prefix: "series", catalogPath: "latest-updates",
                                 cardSelector: "a[title]:has(img)", chapterSelector: "a[href*=chapter-]:has(img)",
                                 imageSelector: ".comic-images-wrapper img[data-reader-page-image]")
    static let brainRotComics = Self(provider: .brainRotComics, prefix: "manga", catalogPath: "latest",
                                    cardSelector: ".item-thumb a:has(img), .tab-thumb a:has(img)",
                                    chapterSelector: "li.wp-manga-chapter",
                                    imageSelector: ".reading-content .page-break img")

    private var home: URL { provider.homepage }
    private var origin: URL { URL(string: "https://\(home.host!)")! }

    func seriesURL(_ slug: String) -> URL {
        var url = origin.appending(component: prefix).appending(component: slug)
        if provider == .brainRotComics { url.append(path: "/") }
        return url
    }

    func seriesLink(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 2, parts[0] == prefix, validSlug(parts[1]) else { return nil }
        return String(parts[1])
    }

    func chapterLink(_ url: URL) -> Chapter? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 3, parts[0] == prefix, validSlug(parts[1]),
              let number = parts[2].wholeMatch(of: #/chapter-([0-9]+(?:[.-][0-9]+)*)/#)?.1 else { return nil }
        let slug = String(parts[1])
        let id = slug + "/" + parts[2]
        var source = seriesURL(slug).appending(component: String(parts[2]))
        if provider == .brainRotComics { source.append(path: "/") }
        return Chapter(id: id, slug: slug, number: number.replacingOccurrences(of: "-", with: "."), source: source, sourceID: provider)
    }

    func catalog(page: Int? = nil) async throws -> Catalog {
        if provider == .vortexScans {
            let page = page ?? 1
            let response = try await vortexPosts(["page": String(page), "perPage": "12", "tag": "hot"])
            return Catalog(featured: [], latest: response.posts.compactMap(vortexManga),
                           nextPage: page * 12 < response.totalCount ? page + 1 : nil)
        }
        let url = origin.appending(component: catalogPath)
        let target = page.map { url.appending(path: "page/\($0)/") } ?? (provider == .brainRotComics ? url.appending(path: "/") : url)
        let document = try await html(target)
        let items = try cards(document, selector: provider == .manhuaPlus ? "#home-tab-update " + cardSelector : nil)
        guard !items.isEmpty else { throw SourceFailure.unavailable }
        let hasMore = provider == .brainRotComics && (try? document.select("a.next.page-numbers, .nav-previous a").isEmpty()) == false
        return Catalog(featured: [], latest: items, nextPage: hasMore ? (page ?? 1) + 1 : nil)
    }

    func search(_ query: String) async throws -> [Manga] {
        switch provider {
        case .manhuaPlus:
            let url = withQuery(origin.appending(component: "search"), ["keyword": query])
            return try cards(await html(url))
        case .brainRotComics:
            let url = withQuery(origin, ["s": query, "post_type": "wp-manga"])
            return try cards(await html(url))
        case .vortexScans:
            let response = try await vortexPosts(["page": "1", "perPage": "24", "searchTerm": query])
            return response.posts.compactMap(vortexManga)
        default: throw SourceFailure.invalidLink
        }
    }

    func series(_ slug: String) async throws -> Series {
        let url = seriesURL(slug)
        guard seriesLink(url) == slug else { throw SourceFailure.invalidLink }
        let document: Document
        if provider == .vortexScans, let expanded = try? await SourceWebPage.load(
            url, hosts: provider.hosts, documentScript: Self.expandedVortexChapters
        ) {
            document = try SwiftSoup.parse(expanded.html)
        } else {
            document = try await html(url)
        }
        guard let title = try document.select("h1").first()?.text(), !title.isEmpty else { throw SourceFailure.unavailable }
        let synopsis = try document.select("meta[name=description]").first()?.attr("content") ?? ""
        let cover = try meta(document, "og:image")
        let manga = Manga(slug: slug, title: title, cover: cover, sourceID: provider)
        let chapters = try list(document, slug: slug)
        let start = try document.select("a[href*=chapter-]").array().first { link in
            try link.text().hasPrefix(provider == .vortexScans ? "Start Reading" : "Read First")
        }.flatMap { link in
            SourceHTTP.url(try link.attr("href"), relativeTo: origin).flatMap(chapterLink)
        }
        return Series(manga: manga, id: slug, synopsis: synopsis, first: start ?? chapters.last, listedChapters: chapters)
    }

    func chapters(_ series: Series, offset: Int, ascending: Bool) -> ChapterList {
        let list = series.listedChapters ?? []
        let ordered = ascending ? Array(list.reversed()) : list
        let items = Array(ordered.dropFirst(offset).prefix(80))
        let next = offset + items.count
        return ChapterList(items: items, nextOffset: next < ordered.count ? next : nil)
    }

    func content(_ chapter: Chapter) async throws -> ChapterContent {
        let document = try await readerDocument(chapter)
        let urls = try pageImages(document)
        let series = try await provider.series(chapter.slug)
        let list = series.listedChapters ?? []
        let index = list.firstIndex { $0.id == chapter.id }
        let linked = try document.select("a[href*=chapter-]").array().compactMap { link -> Chapter? in
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: origin),
                  let match = chapterLink(url), match.slug == chapter.slug else { return nil }
            return match
        }

        func adjacent(_ offset: Int) -> Chapter? {
            if let index, list.indices.contains(index + offset) { return list[index + offset] }
            guard let current = Double(chapter.number) else { return nil }
            return linked.compactMap { item -> (Chapter, Double)? in
                guard let number = Double(item.number), (number - current) * Double(offset) < 0 else { return nil }
                return (item, abs(number - current))
            }.min(by: { $0.1 < $1.1 })?.0
        }

        return ChapterContent(chapter: chapter, manga: series.manga, pages: urls, previous: adjacent(1), next: adjacent(-1))
    }

    func pages(_ chapter: Chapter) async throws -> [URL] {
        try pageImages(await readerDocument(chapter))
    }

    private func validSlug(_ value: Substring) -> Bool {
        value.count < 250 && value.wholeMatch(of: #/[a-zA-Z0-9][a-zA-Z0-9_'-]*/#) != nil
    }

    private static let expandedVortexChapters = """
    const button = [...document.querySelectorAll('button')].find(node => node.textContent.trim() === 'Show All');
    if (button) {
        const selector = 'a[href*="/chapter-"] img';
        const before = document.querySelectorAll(selector).length;
        button.click();
        for (let attempt = 0; attempt < 20; attempt++) {
            if (document.querySelectorAll(selector).length > before) break;
            await new Promise(resolve => setTimeout(resolve, 180));
        }
    }
    return document.documentElement.outerHTML;
    """

    private struct VortexPosts: Decodable {
        struct Post: Decodable {
            let slug: String
            let postTitle: String
            let featuredImage: String?
            let isNovel: Bool?
        }

        let posts: [Post]
        let totalCount: Int
    }

    private func vortexManga(_ post: VortexPosts.Post) -> Manga? {
        guard post.isNovel != true, validSlug(post.slug[...]) else { return nil }
        return Manga(slug: post.slug, title: post.postTitle, cover: post.featuredImage.flatMap { SourceHTTP.url($0) }, sourceID: provider)
    }

    private func vortexPosts(_ query: [String: String]) async throws -> VortexPosts {
        let endpoint = URL(string: "https://api.vortexscans.org/api/posts")!
        let bytes = try await SourceHTTP.data(withQuery(endpoint, query), allowedHosts: ["api.vortexscans.org"])
        return try JSONDecoder().decode(VortexPosts.self, from: bytes)
    }

    private func html(_ url: URL) async throws -> Document {
        try await providerMarkup(url, provider: provider, useWebKit: provider == .brainRotComics)
    }

    private func readerDocument(_ chapter: Chapter) async throws -> Document {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        if provider == .manhuaPlus {
            return try await providerMarkup(chapter.source, provider: provider, useWebKit: true)
        }
        return try await html(chapter.source)
    }

    private func pageImages(_ document: Document) throws -> [URL] {
        var unique = Set<URL>()
        let urls = try document.select(imageSelector).array().compactMap { image -> URL? in
            let reference = provider == .manhuaPlus ? try image.attr("src") : nil
            let url = try reference.flatMap { SourceHTTP.url($0, relativeTo: origin) } ?? imageURL(image, relativeTo: origin)
            guard let url, !url.path.lowercased().contains("/loading/"), unique.insert(url).inserted else { return nil }
            return url
        }
        guard !urls.isEmpty else { throw SourceFailure.noPages }
        return urls
    }

    private func list(_ document: Document, slug: String) throws -> [Chapter] {
        var known = Set<String>()
        return try document.select(chapterSelector).array().compactMap { row -> Chapter? in
            let anchor = row.tagName() == "a" ? row : try row.select("a[href]").first()
            guard let anchor, let url = SourceHTTP.url(try anchor.attr("href"), relativeTo: origin),
                  var chapter = chapterLink(url), chapter.slug == slug, known.insert(chapter.id).inserted else { return nil }
            if let time = try row.select("time").first() {
                let raw = try time.attr("datetime")
                chapter.releasedAt = Double(raw).map(Date.init(timeIntervalSince1970:)) ?? ChapterReleaseDate.parse(raw)
                chapter.note = try time.text()
            } else if provider == .brainRotComics {
                chapter.note = try row.select(".chapter-release-date").first()?.text()
                chapter.releasedAt = ChapterReleaseDate.parse(chapter.note)
            }
            return chapter
        }
    }

    private func cards(_ document: Document, selector: String? = nil) throws -> [Manga] {
        var known = Set<String>()
        return try document.select(selector ?? cardSelector).array().compactMap { anchor -> Manga? in
            guard let url = SourceHTTP.url(try anchor.attr("href"), relativeTo: origin), let slug = seriesLink(url),
                  let image = try anchor.select("img").first() else { return nil }
            let title = try anchor.attr("title")
            let label = title.isEmpty ? try image.attr("alt") : title
            guard !label.isEmpty, known.insert(slug).inserted else { return nil }
            return Manga(slug: slug, title: label, cover: try imageURL(image, relativeTo: origin), sourceID: provider)
        }
    }
}
