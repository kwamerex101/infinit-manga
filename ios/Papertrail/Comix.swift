import Foundation

enum Comix {
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
