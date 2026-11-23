import Foundation
import SwiftSoup

enum XOXOComics {
    static let website = URL(string: "https://xoxocomic.com/")!
    private static let hosts = ["xoxocomic.com", "www.xoxocomic.com"]

    static func browse(_ query: String = "") async throws -> [ComicSeries] {
        let url = query.isEmpty ? website : withQuery(website.appending(path: "search-comic"),
                                                       ["keyword": String(query.prefix(120))])
        let document = try await markup(url)
        var seen = Set<String>()
        return try document.select(".items .item figure").array().compactMap { card in
            guard let link = try card.select("figcaption h3 a[href], figcaption h2 a[href]").first(),
                  let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  let parts = components(url), parts.count == 2, seen.insert(String(parts[1])).inserted,
                  let image = try card.select(".image img").first() else { return nil }
            let cover = try SourceHTTP.url(image.attr("data-original"), relativeTo: website) ?? imageURL(image, relativeTo: website)
            let title = try link.text()
            guard let cover, !title.isEmpty else { return nil }
            return ComicSeries(id: "xoxo:" + parts[1], title: title, credit: "XOXO Comics",
                               source: .xoxo, cover: cover, website: url)
        }
    }

    static func issues(_ series: ComicSeries, page: Int, ascending: Bool) async throws -> ComicIssueBatch {
        guard let parts = components(series.website), parts.count == 2 else { throw SourceFailure.invalidLink }
        let url = page == 1 ? series.website : withQuery(series.website, ["page": String(page)])
        let document = try await markup(url)
        var seen = Set<URL>()
        let issues = try document.select(".list-chapter .chapter a[href]").array().enumerated().compactMap { index, link -> ComicIssue? in
            guard let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  let path = components(url), path.count == 3, path[1] == parts[1],
                  seen.insert(url).inserted else { return nil }
            let title = try link.text()
            let issueNumber = path[2].split(separator: "-").dropFirst().first.flatMap { Int($0) } ?? index + 1
            let date = try link.parent()?.nextElementSibling()?.text()
            return ComicIssue(title: title, number: issueNumber, website: url, scanCount: nil, date: date)
        }
        guard !issues.isEmpty else { throw SourceFailure.unavailable }
        // Pagination follows the source's issue order.
        let next = try document.select(".pagination a[href]").array().contains { link in
            guard let url = try SourceHTTP.url(link.attr("href"), relativeTo: website),
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value
            else { return false }
            return components(url)?.count == 2 && Int(value) == page + 1
        }
        return ComicIssueBatch(issues: ascending ? Array(issues.reversed()) : issues, nextPage: next ? page + 1 : nil)
    }

    static func pages(_ issue: ComicIssue) async throws -> ComicPages {
        guard let parts = components(issue.website), parts.count == 3 else { throw SourceFailure.invalidLink }
        let url = issue.website.appending(component: "all")
        let document = try await markup(url)
        var seen = Set<URL>()
        let pages = try document.select(".reading-detail .page-chapter img[data-original]").array().compactMap { image -> URL? in
            guard let page = SourceHTTP.url(try image.attr("data-original"), relativeTo: website),
                  hosts.contains(page.host ?? ""), page.path.hasPrefix(issue.website.path + "/"),
                  seen.insert(page).inserted else { return nil }
            return page
        }
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        return ComicPages(images: pages)
    }

    static func firstReadablePage(of issue: ComicIssue, pages: [URL], from start: Int) async throws -> Int? {
        let referer = issue.website.appending(component: "all")
        for index in pages.indices.dropFirst(start).prefix(6) {
            do {
                _ = try await Artwork.image(at: pages[index], quality: .highResolution, referer: referer)
                return index
            } catch SourceFailure.noPages {
                continue
            }
        }
        return nil
    }

    private static func components(_ url: URL) -> [Substring]? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", hosts.contains(url.host ?? ""), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, (2...3).contains(parts.count), parts.first == "comic",
              parts.dropFirst().allSatisfy({ $0.wholeMatch(of: #/[a-z0-9][a-z0-9.-]{0,240}/#) != nil }) else {
            return nil
        }
        return parts
    }

    private static func markup(_ url: URL) async throws -> Document {
        try SwiftSoup.parse(String(decoding: await SourceHTTP.data(url, allowedHosts: hosts), as: UTF8.self))
    }
}
