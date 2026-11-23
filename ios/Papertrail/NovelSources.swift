import Foundation
import SwiftSoup

struct Novel: Codable, Hashable, Identifiable, Sendable {
    let provider: NovelSource
    let slug: String
    let title: String
    let cover: URL?
    var synopsis = ""
    var aliases: [String] = []
    var genres: [String] = []

    var id: String { "novel:\(provider.rawValue):\(slug)" }
    var url: URL { provider.seriesURL(slug) }

    var titleKeys: Set<String> { Set(([title] + aliases).map(Self.titleKey).filter { !$0.isEmpty }) }

    static func titleKey(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: #"\s*[\[(](?:web\s*|light\s*)?novel[\])]\s*$"#,
                                               with: "", options: [.regularExpression, .caseInsensitive])
        return clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

struct NovelChapter: Codable, Hashable, Identifiable, Sendable {
    let number: String
    let url: URL
    var title: String? = nil
    var locked = false
    var id: String { "novel:\(url.host ?? ""):\(url.path)" }
    var label: String { "Chapter \(number)" }

    static func earlier(_ first: Self, _ second: Self) -> Bool {
        let order = first.number.compare(second.number, options: .numeric)
        return order == .orderedSame ? first.id < second.id : order == .orderedAscending
    }
}

struct NovelRelease: Identifiable, Sendable {
    let novel: Novel
    let chapter: NovelChapter
    let date: Date?
    var id: Novel.ID { novel.id }
}

struct NovelDetails: Sendable {
    let novel: Novel
    let chapters: [NovelChapter]
    var nextOffset: Int? = nil
    var seriesID: String? = nil
    var firstChapter: NovelChapter? = nil

    var firstReadableChapter: NovelChapter? {
        firstChapter ?? chapters.lazy.filter { !$0.locked }.min(by: NovelChapter.earlier)
    }

    func merging(_ page: Self) -> Self {
        var seen = Set<NovelChapter.ID>()
        return NovelDetails(novel: novel, chapters: (chapters + page.chapters).filter { seen.insert($0.id).inserted },
                            nextOffset: page.nextOffset, seriesID: seriesID, firstChapter: firstChapter)
    }
}

struct NovelText: Sendable {
    let paragraphs: [String]
    let previous: NovelChapter?
    let next: NovelChapter?
}

enum NovelSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case roliaScan, vortexScans, novelFull, standardEbooks

    var id: Self { self }
    var name: String {
        switch self {
        case .roliaScan: ReadingSource.roliaScan.name
        case .vortexScans: ReadingSource.vortexScans.name
        case .novelFull: "NovelFull"
        case .standardEbooks: "Standard Ebooks"
        }
    }

    private var homepage: URL {
        switch self {
        case .roliaScan: ReadingSource.roliaScan.homepage
        case .vortexScans: ReadingSource.vortexScans.homepage
        case .novelFull: NovelFull.website
        case .standardEbooks: StandardEbooks.website
        }
    }

    private var hosts: [String] {
        switch self {
        case .roliaScan: ReadingSource.roliaScan.hosts
        case .vortexScans: ReadingSource.vortexScans.hosts
        case .novelFull, .standardEbooks: homepage.host.map { [$0] } ?? []
        }
    }
    private var path: String { self == .roliaScan ? "manga" : "series" }

    func seriesURL(_ slug: String) -> URL {
        if self == .novelFull { return NovelFull.url(slug) }
        if self == .standardEbooks { return StandardEbooks.url(slug) }
        let url = homepage.appending(component: path).appending(component: slug)
        return self == .roliaScan ? url.appending(path: "/") : url
    }

    func seriesSlug(_ url: URL) -> String? {
        if self == .novelFull { return NovelFull.slug(url) }
        if self == .standardEbooks { return StandardEbooks.slug(url) }
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", hosts.contains(url.host ?? ""),
              parts.count == 2, parts[0] == path, Self.validSlug(String(parts[1])) else { return nil }
        return String(parts[1])
    }

    private static func validSlug(_ slug: String) -> Bool {
        slug.count <= 240 && slug.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_:'-]*/#) != nil
    }

    private func chapter(_ url: URL, for novel: Novel) -> NovelChapter? {
        guard url.scheme == "https", hosts.contains(url.host ?? "") else { return nil }
        if self == .roliaScan, let chapter = RoliaScan.chapterLink(url.absoluteString), chapter.slug == novel.slug {
            return NovelChapter(number: chapter.number, url: chapter.source)
        }
        let parts = url.path.split(separator: "/")
        guard self == .vortexScans, parts.count == 3, parts[0] == "series", parts[1] == novel.slug,
              let number = parts[2].wholeMatch(of: #/chapter-([0-9]+(?:[.-][0-9]+)*)/#)?.1 else { return nil }
        return NovelChapter(number: number.replacingOccurrences(of: "-", with: "."),
                            url: novel.url.appending(component: String(parts[2])))
    }

    func latest() async throws -> [NovelRelease] {
        switch self {
        case .novelFull: return try await NovelFull.latest()
        case .standardEbooks: return []
        case .roliaScan:
            let home = homepage.appending(path: "home/")
            let (_, document) = try await webpage(home)
            return try document.select("#novels-slider-container .slider > div").array().compactMap { card in
                guard let image = try card.select("img").first(),
                      let link = try card.select("a[href*=/manga/]").first(),
                      let url = SourceHTTP.url(try link.attr("href"), relativeTo: home),
                      let slug = seriesSlug(url),
                      let release = try card.select("a[href*=/read/]").first(),
                      let releaseURL = SourceHTTP.url(try release.attr("href"), relativeTo: home) else { return nil }
                let novel = Novel(provider: self, slug: slug, title: try image.attr("alt"),
                                  cover: SourceHTTP.url(try image.attr("src"), relativeTo: home))
                guard let chapter = chapter(releaseURL, for: novel) else { return nil }
                let date = ChapterReleaseDate.parse(try card.select("a[href*=/read/] + span").first()?.text())
                return NovelRelease(novel: novel, chapter: chapter, date: date)
            }
        case .vortexScans:
            return try await vortexEntries().compactMap { post in
                guard let novel = post.novel, let release = post.chapters.first(where: { $0.isAccessible }),
                      let chapter = chapter(novel.url.appending(component: release.slug), for: novel) else { return nil }
                return NovelRelease(novel: novel, chapter: chapter,
                                    date: ChapterReleaseDate.parse(release.becameFreeAt ?? post.lastChapterAddedAt))
            }
        }
    }

    func search(_ query: String) async throws -> [Novel] {
        switch self {
        case .novelFull: return try await NovelFull.search(query)
        case .standardEbooks: return try await StandardEbooks.books(query)
        case .roliaScan:
            do {
                return try await RoliaScan.live.searchEntries(query).compactMap {
                    guard Manga.isNovelFormat($0.type), let url = SourceHTTP.url($0.permalink, relativeTo: homepage),
                          let slug = seriesSlug(url) else { return nil }
                    return Novel(provider: self, slug: slug, title: $0.title,
                                 cover: $0.thumbnail.flatMap { SourceHTTP.url($0, relativeTo: homepage) },
                                 synopsis: $0.description ?? "", aliases: $0.altTitles ?? [])
                }
            } catch {
                try Task.checkCancellation()
                // The public home page can still be reachable when RoliaScan's search API stalls.
                let key = Novel.titleKey(query)
                guard !key.isEmpty else { throw error }
                let matches = try await latest().map(\.novel).filter {
                    $0.titleKeys.contains(where: { $0.contains(key) })
                }
                guard !matches.isEmpty else { throw error }
                return matches
            }
        case .vortexScans:
            return try await vortexEntries(query: query).compactMap(\.novel)
        }
    }

    func discover(genres: [String]) async throws -> [Novel] {
        switch self {
        case .novelFull: return try await NovelFull.latest().map(\.novel)
        case .standardEbooks: return []
        case .roliaScan:
            struct Entry: Decodable {
                let title: String
                let url: String
                let cover: String?
                let type: String?
                let description: String?
            }

            let url = homepage.appending(path: "wp-json/manga/v1/load")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let filters = String(decoding: try JSONEncoder().encode(genres), as: UTF8.self)
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "page": 1, "search": "", "years": "[]", "genres": filters, "types": "[\"Novel\"]",
                "statuses": "[]", "sort": "post_desc", "genreMatchMode": "or"
            ])
            let (data, response) = try await SourceHTTP.session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url, http.statusCode == 200 else {
                throw SourceFailure.unavailable
            }
            return try JSONDecoder().decode([Entry].self, from: data).compactMap { entry in
                guard Manga.isNovelFormat(entry.type), let link = SourceHTTP.url(entry.url, relativeTo: homepage),
                      let slug = seriesSlug(link) else { return nil }
                return Novel(provider: self, slug: slug, title: entry.title,
                             cover: entry.cover.flatMap { SourceHTTP.url($0, relativeTo: homepage) },
                             synopsis: entry.description ?? "")
            }
        case .vortexScans:
            return try await vortexEntries().compactMap(\.novel)
        }
    }

    func details(_ novel: Novel, ascending: Bool = true) async throws -> NovelDetails {
        guard novel.provider == self, seriesSlug(novel.url) == novel.slug else { throw SourceFailure.invalidLink }
        if self == .novelFull { return try await NovelFull.details(novel, ascending: ascending) }
        if self == .standardEbooks { return try await StandardEbooks.details(novel) }
        let (html, document) = try await webpage(novel.url)
        var enriched = novel
        switch self {
        case .roliaScan:
            guard let id = try document.body()?.attr("data-manga-id"), Int(id) != nil else {
                throw SourceFailure.unavailable
            }
            let synopsis = try document.select("#description-content-tab").text()
            if !synopsis.isEmpty { enriched.synopsis = synopsis }
            if let first = try firstRoliaChapter(document, novel: novel),
               let chapters = try? await roliaReaderChapters(first, novel: novel),
               !chapters.isEmpty {
                return NovelDetails(novel: enriched, chapters: chapters)
            }
            let firstPage = try await roliaChapters(enriched, seriesID: id, offset: 0, ascending: true)
            guard !ascending, firstPage.nextOffset != nil else { return firstPage }
            var latest = try await roliaChapters(enriched, seriesID: id, offset: 0, ascending: false)
            latest.firstChapter = firstPage.firstReadableChapter
            return latest
        case .vortexScans:
            if enriched.synopsis.isEmpty {
                enriched.synopsis = try document.select("meta[property=og:description]").first()?.attr("content") ?? ""
            }
            let chapters = try vortexChapters(html, document: document, novel: novel)
            return NovelDetails(novel: enriched, chapters: chapters)
        case .novelFull, .standardEbooks:
            throw SourceFailure.invalidLink
        }
    }

    func nextChapters(_ details: NovelDetails, offset: Int, ascending: Bool = true) async throws -> NovelDetails {
        if self == .novelFull { return try await NovelFull.nextChapters(details, offset: offset, ascending: ascending) }
        guard self == .roliaScan, let id = details.seriesID else { throw SourceFailure.unavailable }
        return try await roliaChapters(details.novel, seriesID: id, offset: offset, ascending: ascending)
    }

    private func firstRoliaChapter(_ document: Document, novel: Novel) throws -> NovelChapter? {
        let links = try document.select("a[href*=/read/]").array()
        return try links.compactMap { link in
            SourceHTTP.url(try link.attr("href"), relativeTo: novel.url).flatMap { chapter($0, for: novel) }
        }.first
    }

    private func roliaReaderChapters(_ first: NovelChapter, novel: Novel) async throws -> [NovelChapter] {
        let (_, document) = try await webpage(first.url)
        guard try document.select(".reader-text").first() != nil else { return [] }
        // The public text reader ships its full chapter picker in the HTML.
        let options = try document.select("#chapter-select option").array().compactMap { option in
            SourceHTTP.url(try option.attr("value"), relativeTo: novel.url).flatMap { chapter($0, for: novel) }
        }
        guard !options.isEmpty else { return [] }
        return Self.unique(options)
    }

    private func roliaChapters(_ novel: Novel, seriesID: String, offset: Int, ascending: Bool) async throws -> NovelDetails {
        let page = try await RoliaScan.live.chapters(seriesID, offset: offset, ascending: ascending, textOnly: true)
        let chapters = page.items.compactMap { chapter($0.source, for: novel) }
        return NovelDetails(novel: novel, chapters: chapters, nextOffset: page.nextOffset, seriesID: seriesID)
    }

    private func vortexChapters(_ html: String, document: Document, novel: Novel) throws -> [NovelChapter] {
        // Vortex includes the entire list in its public page data. The rendered list starts with a subset.
        let serialized = html.matches(of: #/slug:"(chapter-[0-9.\-]+)",number:[0-9.]+,title:"((?:\\.|[^"\\])*)",chapterStatus:"PUBLIC",[^{}]{0,1000}?isLocked:(![01])/#
        ).compactMap { match -> NovelChapter? in
            guard var result = chapter(novel.url.appending(component: String(match.1)), for: novel) else { return nil }
            let quoted = Data(("\"" + match.2 + "\"").utf8)
            result.title = try? JSONDecoder().decode(String.self, from: quoted)
            result.locked = match.3 == "!0"
            return result
        }
        let links = try document.select("a[href*=/chapter-]").array().compactMap { anchor in
            SourceHTTP.url(try anchor.attr("href"), relativeTo: novel.url).flatMap { chapter($0, for: novel) }
        }
        return Self.unique(serialized + links).sorted {
            $0.number.compare($1.number, options: .numeric) == .orderedAscending
        }
    }

    func text(_ chapter: NovelChapter, of novel: Novel) async throws -> NovelText {
        guard !chapter.locked else { throw SourceFailure.restricted }
        guard novel.provider == self, seriesSlug(novel.url) == novel.slug else { throw SourceFailure.invalidLink }
        if self == .novelFull { return try await NovelFull.text(chapter, of: novel) }
        if self == .standardEbooks { return try await StandardEbooks.text(chapter, of: novel) }
        guard self.chapter(chapter.url, for: novel)?.id == chapter.id else { throw SourceFailure.invalidLink }
        let (_, document) = try await webpage(chapter.url)
        let container = self == .roliaScan ? ".reader-text" : ".novel-reader-content"
        let paragraphs = try Self.paragraphs(in: document, container: container)
        let links = try document.select("a[href][title], a[href][aria-label], a[href*=chapter-]").array()
        func adjacent(_ prefix: String) throws -> NovelChapter? {
            for link in links {
                let names = try [link.attr("title"), link.attr("aria-label"), link.text()]
                guard names.contains(where: { $0.lowercased().hasPrefix(prefix) }),
                      let url = SourceHTTP.url(try link.attr("href"), relativeTo: chapter.url),
                      let adjacent = self.chapter(url, for: novel), adjacent.id != chapter.id else { continue }
                return adjacent
            }
            return nil
        }
        return try NovelText(paragraphs: paragraphs, previous: adjacent("prev"), next: adjacent("next"))
    }

    static func paragraphs(in document: Document, container: String,
                           blocks selector: String = "p, h1, h2, h3, blockquote, li") throws -> [String] {
        guard let content = try document.select(container).first() else { throw SourceFailure.noPages }
        let blocks = try content.select(selector).array()
        let paragraphs = try blocks.filter {
            try $0.select(selector).array().count == 1
        }.compactMap { block -> String? in
            let text = try block.text(trimAndNormaliseWhitespace: false).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !paragraphs.isEmpty else { throw SourceFailure.noPages }
        return paragraphs
    }

    func webpage(_ url: URL) async throws -> (String, Document) {
        let data = try await SourceHTTP.data(url, allowedHosts: hosts)
        let html = String(decoding: data, as: UTF8.self)
        return (html, try SwiftSoup.parse(html))
    }

    private static func unique(_ chapters: [NovelChapter]) -> [NovelChapter] {
        var ids = Set<NovelChapter.ID>()
        return chapters.filter { ids.insert($0.id).inserted }
    }

    private struct VortexCatalog: Decodable {
        struct Post: Decodable {
            struct Release: Decodable {
                let slug: String
                let isAccessible: Bool
                let becameFreeAt: String?
            }
            struct Genre: Decodable { let name: String }
            struct Count: Decodable { let chapters: Int }

            let slug: String
            let postTitle: String
            let featuredImage: String?
            let postContent: String?
            let isNovel: Bool
            let alternativeTitles: String?
            let lastChapterAddedAt: String?
            let genres: [Genre]
            let chapters: [Release]
            let _count: Count?

            var novel: Novel? {
                guard isNovel, NovelSource.validSlug(slug), (_count?.chapters ?? chapters.count) > 0 else { return nil }
                return Novel(provider: .vortexScans, slug: slug, title: postTitle,
                             cover: featuredImage.flatMap { SourceHTTP.url($0) }, synopsis: postContent ?? "",
                             aliases: alternativeTitles?.components(separatedBy: ", ") ?? [], genres: genres.map(\.name))
            }
        }

        let novelPosts: [Post]
        let novelTotalCount: Int
    }

    private func vortexEntries(query: String? = nil) async throws -> [VortexCatalog.Post] {
        let endpoint = URL(string: "https://api.vortexscans.org/api/posts")!
        let size = 24
        var page = 1
        var posts: [VortexCatalog.Post] = []
        while true {
            var parameters = ["page": String(page), "perPage": String(size), "isNovel": "true"]
            parameters["searchTerm"] = query
            let data = try await SourceHTTP.data(withQuery(endpoint, parameters), allowedHosts: ["api.vortexscans.org"])
            let response = try JSONDecoder().decode(VortexCatalog.self, from: data)
            posts.append(contentsOf: response.novelPosts)
            if response.novelPosts.isEmpty || page * size >= response.novelTotalCount || page >= 4 { return posts }
            page += 1
        }
    }
}
