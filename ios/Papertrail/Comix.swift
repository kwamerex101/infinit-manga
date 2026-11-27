import Foundation
import SwiftSoup

enum Comix {
    static func catalog() async throws -> Catalog {
        let home = InAppWebsite.comixURL
        let bytes = try await SourceHTTP.data(home, allowedHosts: ReadingSource.comix.hosts)
        let document = try SwiftSoup.parse(String(decoding: bytes, as: UTF8.self))
        guard let payload = try document.select("script#initial-data").first()?.data() else {
            throw SourceFailure.unavailable
        }
        return try decodeCatalog(payload, relativeTo: home)
    }

    private static func decodeCatalog(_ payload: String, relativeTo home: URL) throws -> Catalog {
        let homepage = try JSONDecoder().decode(Homepage.self, from: Data(payload.utf8))
        guard homepage.page == "home",
              let updates = homepage.updates else {
            throw SourceFailure.unavailable
        }
        let latest = updates.items.compactMap { item -> Manga? in
            guard let url = SourceHTTP.url(item.url, relativeTo: home),
                  let slug = seriesSlug(url) else { return nil }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let cover = [item.poster?.medium, item.poster?.large].compactMap { path -> URL? in
                guard let path, let url = SourceHTTP.url(path, relativeTo: home),
                      InAppWebsite.comix.contains(url), url.path.hasPrefix("/images/covers/") else { return nil }
                return url
            }.first
            return Manga(slug: slug, title: title, cover: cover, sourceID: .comix)
        }
        return Catalog(featured: [], latest: latest)
    }

    private struct Homepage: Decodable {
        let page: String
        let updates: Updates?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            page = try container.decode(String.self, forKey: .page)
            let entries = try container.nestedContainer(keyedBy: QueryKey.self, forKey: .queries)
            let key = entries.allKeys.first {
                $0.stringValue.hasPrefix(#"["manga","list","#)
                    && $0.stringValue.contains(#""chapter_updated_at":"desc""#)
            }
            updates = try key.map { try entries.decode(Updates.self, forKey: $0) }
        }

        private enum CodingKeys: String, CodingKey { case page, queries }
    }

    private struct QueryKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Updates: Decodable {
        struct Item: Decodable {
            struct Poster: Decodable {
                let medium: String?
                let large: String?
            }

            let url: String
            let title: String
            let poster: Poster?
        }

        let items: [Item]
    }

    static func seriesURL(_ slug: String) -> URL {
        InAppWebsite.comixURL.appending(component: "title").appending(component: slug)
    }

    static func seriesSlug(_ url: URL) -> String? {
        guard InAppWebsite.comix.contains(url) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "title", validSlug(parts[1]) else { return nil }
        return String(parts[1])
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        guard InAppWebsite.comix.contains(url) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "title", validSlug(parts[1]),
              let match = parts[2].wholeMatch(of: #/([0-9]+)-chapter-([0-9]+(?:[.-][0-9]+)?)/#) else { return nil }
        let slug = String(parts[1])
        return Chapter(id: String(match.1), slug: slug, number: match.2.replacingOccurrences(of: "-", with: "."),
                       source: seriesURL(slug).appending(component: String(parts[2])), sourceID: .comix)
    }

    @MainActor
    static func content(_ chapter: Chapter) async throws -> ChapterContent {
        guard chapterLink(chapter.source)?.id == chapter.id else { throw SourceFailure.invalidLink }
        let (page, document) = try await SourceWebPage.openComixChapter(chapter.source, documentScript: """
        for (let attempt = 0; attempt < 40; attempt++) {
            const pages = [...document.querySelectorAll('.rpage-page[data-page]')];
            if (pages.length && pages.every((node, index) => Number(node.dataset.page) === index + 1)) {
                const title = document.title.replace(/ · Ch\\..*$/, '').trim();
                return JSON.stringify({ title, pageCount: pages.length });
            }
            await new Promise(resolve => setTimeout(resolve, 200));
        }
        return '';
        """)
        guard chapterLink(document.url)?.id == chapter.id else { throw SourceFailure.restricted }
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(document.html.utf8)),
              !metadata.title.isEmpty, (1...500).contains(metadata.pageCount) else { throw SourceFailure.noPages }
        let manga = Manga(slug: chapter.slug, title: metadata.title, cover: nil, sourceID: .comix)
        let images = ComixChapterImages(page: page)
        return ChapterContent(chapter: chapter, manga: manga, pages: [], previous: nil, next: nil,
                              deferredPages: DeferredChapterPages(count: metadata.pageCount, webPage: page) { index in
                                  try await images.url(at: index)
                              })
    }

    private struct Metadata: Decodable {
        let title: String
        let pageCount: Int
    }

    private static func validSlug(_ slug: Substring) -> Bool {
        slug.count <= 250 && slug.wholeMatch(of: #/[a-zA-Z0-9][a-zA-Z0-9-]*/#) != nil
    }
}

@MainActor
private final class ComixChapterImages {
    private let page: SourceWebPage
    private var urls: [Int: URL] = [:]
    private var pending: Task<URL, Error>?

    init(page: SourceWebPage) {
        self.page = page
    }

    func url(at index: Int) async throws -> URL {
        try Task.checkCancellation()
        if let url = urls[index] { return url }
        let previous = pending
        let request = Task {
            _ = await previous?.result
            if let url = urls[index] { return url }
            for _ in 0..<20 {
                if page.webView.window != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let value = try await page.evaluate("""
            const node = document.querySelector(`.rpage-page[data-page="${number}"]`);
            if (!node) return '';
            for (let attempt = 0; attempt < 40; attempt++) {
                const img = node.querySelector('img.rpage-page__img');
                if (img?.complete && img.naturalWidth > 0) return img.currentSrc || img.src;
                const bounds = node.getBoundingClientRect();
                if (bounds.top >= innerHeight || bounds.bottom <= 0) {
                    node.scrollIntoView({ behavior: 'instant', block: 'center' });
                }
                await new Promise(resolve => setTimeout(resolve, 200));
            }
            return '';
            """, arguments: ["number": index + 1])
            // Only hand public HTTPS images to the native reader, with no website credentials.
            guard let url = SourceHTTP.url(value), url.query == nil, url.fragment == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host, host.contains("."),
                  host.split(separator: ".").last?.contains(where: \.isLetter) == true else {
                throw SourceFailure.noPages
            }
            urls[index] = url
            return url
        }
        pending = request
        let url = try await request.value
        try Task.checkCancellation()
        return url
    }
}
