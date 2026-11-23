import Foundation
import SwiftSoup

struct ComicSeries: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let credit: String
    let source: ComicSource
    let cover: URL
    let website: URL

    static let catalog = [
        ComicSeries(id: "batman-wayne-family", title: "Batman: Wayne Family Adventures", credit: "DC · WEBTOON",
                    source: .dc, cover: URL(string: "https://swebtoon-phinf.pstatic.net/20250205_19/1738718670675e8Srk_JPEG/3180.jpg?type=crop540_540")!,
                    website: URL(string: "https://www.webtoons.com/en/slice-of-life/batman-wayne-family-adventures/list?title_no=3180")!),
        ComicSeries(id: "amazing-spider-man-2022", title: "The Amazing Spider-Man (2022)", credit: "Marvel · WEBTOON",
                    source: .marvel, cover: URL(string: "https://swebtoon-phinf.pstatic.net/20250826_127/1756157171812q5Kau_JPEG/TheAmazingSpiderMan_Thumb_Poster.jpg?type=crop540_540")!,
                    website: URL(string: "https://www.webtoons.com/en/graphic-novel/the-amazing-spider-man-2022/list?title_no=8475")!),
        ComicSeries(id: "invincible", title: "Invincible", credit: "Image Comics · Free first issue",
                    source: .imageComics, cover: URL(string: "https://cdn.imagecomics.com/assets/i/series/430180/invincible_7f00e075db.jpg")!,
                    website: URL(string: "https://imagecomics.com/read/invincible")!),
        ComicSeries(id: "zatanna-ripper", title: "Zatanna & the Ripper", credit: "DC · WEBTOON",
                    source: .dc, cover: URL(string: "https://swebtoon-phinf.pstatic.net/20250205_119/17387192512521W5DH_JPEG/4518.jpg?type=crop540_540")!,
                    website: URL(string: "https://www.webtoons.com/en/fantasy/zatanna-and-the-ripper/list?title_no=4518")!),
        ComicSeries(id: "eternals-500-year-war", title: "Eternals: The 500 Year War", credit: "Marvel · WEBTOON",
                    source: .marvel, cover: URL(string: "https://swebtoon-phinf.pstatic.net/20250205_132/1738719202573gRToy_JPEG/3916.jpg?type=crop540_540")!,
                    website: URL(string: "https://www.webtoons.com/en/super-hero/eternals-500-year-war/list?title_no=3916")!),
        ComicSeries(id: "amazing-man", title: "Amazing Man Comics", credit: "Centaur Publications",
                    source: .archive, cover: ComicSource.archiveURL.appending(path: "services/img/AmazingManComics006"),
                    website: ComicSource.archiveURL.appending(path: "details/AmazingManComics006")),
        ComicSeries(id: "daredevil", title: "Daredevil Comics", credit: "Lev Gleason Publications",
                    source: .archive, cover: ComicSource.archiveURL.appending(path: "services/img/DaredevilComics012"),
                    website: ComicSource.archiveURL.appending(path: "details/DaredevilComics012")),
        ComicSeries(id: "silver-streak", title: "Silver Streak Comics", credit: "Lev Gleason Publications",
                    source: .archive, cover: ComicSource.archiveURL.appending(path: "services/img/SilverStreakComics006"),
                    website: ComicSource.archiveURL.appending(path: "details/SilverStreakComics006")),
        ComicSeries(id: "blue-beetle", title: "Blue Beetle", credit: "Fox Feature Syndicate",
                    source: .archive, cover: ComicSource.archiveURL.appending(path: "services/img/BlueBeetle016"),
                    website: ComicSource.archiveURL.appending(path: "details/BlueBeetle016")),
        ComicSeries(id: "therefore-repent", title: "Therefore Repent!", credit: "Jim Munroe and Salgood Sam · CC BY-NC-SA 3.0",
                    source: .archive, cover: ComicSource.archiveURL.appending(path: "services/img/ThereforeRepent"),
                    website: ComicSource.archiveURL.appending(path: "details/ThereforeRepent")),
        ComicSeries(id: "pepper-carrot", title: "Pepper&Carrot", credit: "David Revoy • CC BY 4.0",
                    source: .pepperCarrot,
                    cover: ComicSource.pepperURL.appending(path: "cache/gfx_Pepper-and-Carrot_by-David-Revoy_E01_480x399px_89q_231682.jpg"),
                    website: ComicSource.pepperURL.appending(path: "en/webcomics/peppercarrot.html")),
        ComicSeries(id: "little-nemo", title: "Little Nemo in Slumberland", credit: "Winsor McCay · Public domain",
                    source: .wikimedia, cover: URL(string: "https://upload.wikimedia.org/wikipedia/commons/f/f7/Little_Nemo_1905-11-26.jpg")!,
                    website: ComicSource.commonsURL.appending(path: "wiki/Category:Little_Nemo_in_Slumberland")),
        ComicSeries(id: "xkcd", title: "xkcd", credit: "Randall Munroe · CC BY-NC 2.5",
                    source: .xkcd, cover: URL(string: "https://imgs.xkcd.com/comics/woodpecker.png")!,
                    website: ComicSource.xkcdURL.appending(path: "archive/")),
        ComicSeries(id: "cat-and-girl", title: "Cat and Girl", credit: "Dorothy Gambrell · CC BY-NC-SA 2.5",
                    source: .catAndGirl, cover: URL(string: "https://catandgirl.com/wp-content/uploads/2006/11/2006-11-21-cg0400obsolete.gif")!,
                    website: ComicSource.catURL.appending(path: "archive/"))
    ]

    var catalogEntry: Self { Self.catalog.first { $0.id == id } ?? self }

    var license: URL? {
        if id == "therefore-repent" { return URL(string: "https://creativecommons.org/licenses/by-nc-sa/3.0/") }
        return source.license
    }
}

struct ComicIssue: Codable, Hashable, Identifiable {
    let title: String
    let number: Int
    let website: URL
    let scanCount: Int?
    var date: String? = nil
    var downloadID: UUID? = nil

    var id: String { website.absoluteString }

    static func archive(_ identifier: String, number: Int, pages: Int, title: String? = nil) -> Self {
        Self(title: title ?? "Issue \(number)", number: number,
             website: ComicSource.archiveURL.appending(path: "details/\(identifier)"), scanCount: pages)
    }
}

struct ComicReadingRoute: Hashable {
    let series: ComicSeries
    let issue: ComicIssue
}

struct ComicPages {
    let images: [URL]
    var note: String? = nil
}

struct ComicIssueBatch {
    let issues: [ComicIssue]
    var nextPage: Int? = nil
}

enum ComicSource: String, Codable, CaseIterable, Sendable {
    case dc, marvel, imageComics, archive, pepperCarrot, wikimedia, xkcd, catAndGirl, getComics, xoxo

    static let archiveURL = URL(string: "https://archive.org")!
    static let pepperURL = URL(string: "https://www.peppercarrot.com")!

    static let commonsURL = URL(string: "https://commons.wikimedia.org")!
    static let xkcdURL = URL(string: "https://xkcd.com")!
    static let catURL = URL(string: "https://catandgirl.com")!

    var isWebtoon: Bool { self == .dc || self == .marvel }
    var opensInBrowser: Bool { self == .imageComics }
    var referer: URL? { isWebtoon ? ReadingSource.webtoon.pageReferer : nil }

    var website: URL {
        switch self {
        case .dc: URL(string: "https://www.dc.com/webtoon")!
        case .marvel: URL(string: "https://www.webtoons.com/en/super-hero/eternals-500-year-war/list?title_no=3916")!
        case .imageComics: URL(string: "https://imagecomics.com/comics/read-first-issues")!
        case .archive: Self.archiveURL
        case .pepperCarrot: Self.pepperURL.appending(path: "en/webcomics/peppercarrot.html")
        case .wikimedia: Self.commonsURL
        case .xkcd: Self.xkcdURL
        case .catAndGirl: Self.catURL
        case .getComics: GetComics.website
        case .xoxo: XOXOComics.website
        }
    }

    var license: URL? {
        switch self {
        case .dc, .marvel, .imageComics, .archive, .wikimedia, .getComics, .xoxo: nil
        case .pepperCarrot: URL(string: "https://creativecommons.org/licenses/by/4.0/")
        case .xkcd: URL(string: "https://xkcd.com/license.html")
        case .catAndGirl: URL(string: "https://creativecommons.org/licenses/by-nc-sa/2.5/")
        }
    }

    var issueLabel: String {
        switch self {
        case .archive, .imageComics, .getComics, .xoxo: "Issues"
        case .dc, .marvel, .pepperCarrot: "Episodes"
        case .wikimedia: "Volumes"
        case .xkcd, .catAndGirl: "Strips"
        }
    }

    var name: String {
        switch self {
        case .dc: "DC"
        case .marvel: "Marvel"
        case .imageComics: "Image Comics"
        case .archive: "Internet Archive"
        case .pepperCarrot: "Pepper&Carrot"
        case .wikimedia: "Wikimedia Commons"
        case .xkcd: "xkcd"
        case .catAndGirl: "Cat and Girl"
        case .getComics: "GetComics"
        case .xoxo: "XOXO Comics"
        }
    }

    func issues(for series: ComicSeries, page: Int = 1, ascending: Bool = false) async throws -> ComicIssueBatch {
        if self == .xoxo { return try await XOXOComics.issues(series, page: page, ascending: ascending) }
        if isWebtoon {
            guard let key = Webtoon.seriesLink(series.website) else { throw SourceFailure.invalidLink }
            let result = try await Webtoon.chapters(key, offset: page, ascending: ascending)
            let issues = result.items.compactMap { chapter -> ComicIssue? in
                guard let episode = chapter.id.split(separator: "/").last.flatMap({ Int($0) }) else { return nil }
                return ComicIssue(title: "Episode \(chapter.number)", number: episode,
                                  website: chapter.source, scanCount: nil, date: chapter.note)
            }
            return ComicIssueBatch(issues: issues, nextPage: result.nextOffset)
        }
        return ComicIssueBatch(issues: try await allIssues(for: series))
    }

    private func allIssues(for series: ComicSeries) async throws -> [ComicIssue] {
        switch self {
        case .dc, .marvel, .getComics, .xoxo:
            throw SourceFailure.invalidLink
        case .imageComics:
            return [ComicIssue(title: "Invincible #1 · Free", number: 1, website: series.website, scanCount: nil)]
        case .archive:
            // The Archive's issue titles and scan counts can differ from the catalog.
            // Each entry names a checked scan of the corresponding Comic Book Plus issue.
            switch series.id {
            case "amazing-man":
                return [
                    .archive("AmazingManComics006", number: 6, pages: 69),
                    .archive("AmazingManComics009", number: 9, pages: 71),
                    .archive("AmazingManComics017", number: 17, pages: 71)
                ]
            case "daredevil":
                return [.archive("DaredevilComics012", number: 12, pages: 70)]
            case "silver-streak":
                return [.archive("SilverStreakComics006", number: 6, pages: 70)]
            case "blue-beetle":
                return [.archive("BlueBeetle016", number: 16, pages: 69)]
            case "therefore-repent":
                return [.archive("ThereforeRepent", number: 1, pages: 163, title: "Complete graphic novel")]
            default:
                throw URLError(.resourceUnavailable)
            }
        case .pepperCarrot:
            let document = try await Self.document(at: Self.pepperLink(series.website.absoluteString, pathPrefix: "/en/webcomics/peppercarrot.html"), host: Self.pepperURL.host)
            let links = try document.select("figure figcaption a[href]").array()
            var seen = Set<URL>()
            let issues = try links.compactMap { link -> ComicIssue? in
                guard let url = Self.pepperLink(try link.attr("abs:href"), pathPrefix: "/en/webcomic/ep"),
                      let number = Int(url.lastPathComponent.dropFirst(2).prefix(while: \.isNumber)),
                      seen.insert(url).inserted else { return nil }
                return ComicIssue(title: try link.text(), number: number, website: url, scanCount: nil)
            }
            guard !issues.isEmpty else { throw URLError(.cannotParseResponse) }
            return issues.sorted { $0.number < $1.number }
        case .wikimedia:
            return (1905...1911).map { year in
                ComicIssue(title: "Little Nemo · \(year)", number: year,
                           website: Self.commonsURL.appending(path: "wiki/Category:Little_Nemo_in_Slumberland,_\(year)"),
                           scanCount: nil)
            }
        case .xkcd:
            let document = try await Self.document(at: Self.xkcdURL.appending(path: "archive/"), host: Self.xkcdURL.host)
            let links = try document.select("#middleContainer a[title][href]").array()
            let issues = try links.compactMap { link -> ComicIssue? in
                let path = try link.attr("href")
                guard let number = Self.stripNumber(path), number != 404 else { return nil }
                return ComicIssue(title: "#\(number) · \(try link.text())", number: number,
                                  website: Self.xkcdURL.appending(path: "\(number)/"), scanCount: nil,
                                  date: Self.publicationDate(try link.attr("title"), separator: "-", yearFirst: true))
            }
            guard !issues.isEmpty else { throw URLError(.cannotParseResponse) }
            return issues
        case .catAndGirl:
            let document = try await Self.document(at: Self.catURL.appending(path: "archive/"), host: Self.catURL.host)
            var seen = Set<URL>()
            let issues = try document.select(".sya_postcontent").array().compactMap { row -> ComicIssue? in
                guard let link = try row.select("a.sya_postlink[rel=bookmark]").first(),
                      let url = Self.checkedURL(try link.attr("abs:href"), hosts: ["catandgirl.com"]),
                      let postID = try link.classNames().first(where: { $0.hasPrefix("post-") }),
                      let number = Int(postID.dropFirst(5)),
                      seen.insert(url).inserted else { return nil }
                let date = try row.select(".sya_date").first()?.ownText() ?? ""
                return ComicIssue(title: try link.text(), number: number, website: url, scanCount: nil,
                                  date: Self.publicationDate(date, separator: ".", yearFirst: false))
            }
            guard !issues.isEmpty else { throw URLError(.cannotParseResponse) }
            return issues
        }
    }

    func pages(for issue: ComicIssue) async throws -> ComicPages {
        switch self {
        case .dc, .marvel:
            guard let chapter = Webtoon.chapterLink(issue.website) else { throw SourceFailure.invalidLink }
            return ComicPages(images: try await Webtoon.pages(chapter))
        case .imageComics, .getComics:
            throw SourceFailure.externalChapter
        case .xoxo:
            return try await XOXOComics.pages(issue)
        case .archive:
            guard issue.website.host == Self.archiveURL.host,
                  let count = issue.scanCount, (1...400).contains(count) else {
                throw URLError(.cannotParseResponse)
            }
            return ComicPages(images: (0..<count).map { page in
                Self.archiveURL.appending(path: "download/\(issue.website.lastPathComponent)/page/n\(page)_w1600.jpg")
            })
        case .pepperCarrot:
            let link = Self.pepperLink(issue.website.absoluteString, pathPrefix: "/en/webcomic/ep")
            let document = try await Self.document(at: link, host: Self.pepperURL.host)
            let images = try document.select(".webcomic-page img[src]").array()
            let pages = try images.compactMap {
                Self.pepperLink(try $0.attr("abs:src"), pathPrefix: "/0_sources/")
            }
            guard !pages.isEmpty else { throw URLError(.cannotParseResponse) }
            return ComicPages(images: pages)
        case .wikimedia:
            return ComicPages(images: try await Self.nemoPages(year: issue.number))
        case .xkcd:
            guard let number = Self.stripNumber(issue.website.path), number == issue.number,
                  issue.website.host == Self.xkcdURL.host else { throw URLError(.badURL) }
            let api = Self.xkcdURL.appending(path: "\(number)/info.0.json")
            let entry = try JSONDecoder().decode(XKCD.self, from: await Self.data(at: api, host: api.host))
            guard let image = Self.checkedURL(entry.img, hosts: ["imgs.xkcd.com"]) else { throw SourceFailure.noPages }
            return ComicPages(images: [image], note: entry.alt.isEmpty ? nil : entry.alt)
        case .catAndGirl:
            let document = try await Self.document(at: issue.website, host: Self.catURL.host)
            let images = try document.select(".comic--container img.comic--image[src]").array().compactMap {
                Self.checkedURL(try $0.attr("abs:src"), hosts: ["catandgirl.com"])
            }
            guard !images.isEmpty else { throw SourceFailure.noPages }
            return ComicPages(images: images)
        }
    }

    private struct XKCD: Decodable {
        let img: String
        let alt: String
    }

    private struct CommonsResponse: Decodable {
        struct Query: Decodable {
            struct File: Decodable {
                struct ImageInfo: Decodable { let url: String }
                let title: String
                let imageinfo: [ImageInfo]?
            }
            let pages: [File]?
        }
        let query: Query?
    }

    private static func nemoPages(year: Int) async throws -> [URL] {
        guard (1905...1911).contains(year) else { throw URLError(.badURL) }
        let endpoint = commonsURL.appending(path: "w/api.php").appending(queryItems: [
            .init(name: "action", value: "query"),
            .init(name: "generator", value: "categorymembers"),
            .init(name: "gcmtitle", value: "Category:Little Nemo in Slumberland, \(year)"),
            .init(name: "gcmtype", value: "file"),
            .init(name: "gcmlimit", value: "100"),
            .init(name: "prop", value: "imageinfo"),
            .init(name: "iiprop", value: "url"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2")
        ])
        let response = try JSONDecoder().decode(CommonsResponse.self, from: await data(at: endpoint, host: endpoint.host))
        // Full dated scans only. The categories also contain cropped panels, illustrations and duplicates.
        let scans = (response.query?.pages ?? []).compactMap { file -> (String, URL)? in
            guard let match = file.title.wholeMatch(of: #/File:Little Nemo(?: in Slumberland)? \(?(\d{4}-\d{2}-\d{2})\)?\.(?i:jpe?g|png|webp)/#),
                  match.1.hasPrefix(String(year)),
                  let value = file.imageinfo?.first?.url,
                  let url = checkedURL(value, hosts: ["upload.wikimedia.org"]) else { return nil }
            return (String(match.1), url)
        }.sorted { $0.0 == $1.0 ? $0.1.absoluteString < $1.1.absoluteString : $0.0 < $1.0 }
        var seen = Set<String>()
        let pages = scans.compactMap { date, url in seen.insert(date).inserted ? url : nil }
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        return pages
    }

    private static func stripNumber(_ path: String) -> Int? {
        guard let match = path.wholeMatch(of: #//(\d+)/?/#), let value = Int(match.1), value > 0 else { return nil }
        return value
    }

    private static func publicationDate(_ value: String, separator: Character, yearFirst: Bool) -> String? {
        let values = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: separator).compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        let unqualifiedYear = yearFirst ? values[0] : values[2]
        let year = unqualifiedYear >= 100 ? unqualifiedYear : unqualifiedYear == 99 ? 1999 : 2000 + unqualifiedYear
        let month = values[yearFirst ? 1 : 0]
        let day = values[yearFirst ? 2 : 1]
        guard let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func data(at url: URL, host: String?) async throws -> Data {
        guard url.scheme == "https", let host, url.host == host else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("InfinitManga/0.1 (iOS comics reader)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.host == host,
              response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        return data
    }

    private static func document(at url: URL?, host: String?) async throws -> Document {
        guard let url else { throw URLError(.badURL) }
        let payload = try await data(at: url, host: host)
        guard let html = String(data: payload, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try SwiftSoup.parse(html, url.absoluteString)
    }

    private static func checkedURL(_ value: String, hosts: Set<String>) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              hosts.contains(host) else { return nil }
        return url
    }

    private static func pepperLink(_ value: String, pathPrefix: String) -> URL? {
        guard let url = URL(string: value), url.host == pepperURL.host,
              url.scheme == "https", url.path.hasPrefix(pathPrefix) else { return nil }
        return url
    }
}


enum ComicDiscovery {
    static let sources: [ComicSource] = [.xoxo, .getComics]

    static func load(_ sources: [ComicSource], query: String = "") async
        -> (feeds: [ComicSource: [ComicSeries]], failures: Set<ComicSource>) {
        await withTaskGroup(of: (ComicSource, [ComicSeries]?).self) { group in
            for source in sources {
                group.addTask {
                    switch source {
                    case .xoxo: return (source, try? await XOXOComics.browse(query))
                    case .getComics: return (source, try? await GetComics.browse(query))
                    default: return (source, nil)
                    }
                }
            }
            var feeds: [ComicSource: [ComicSeries]] = [:]
            var failures = Set<ComicSource>()
            for await (source, titles) in group {
                if let titles, !titles.isEmpty || !query.isEmpty { feeds[source] = titles }
                else { failures.insert(source) }
            }
            return (feeds, failures)
        }
    }
}
