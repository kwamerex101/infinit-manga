import Foundation
import SwiftSoup

struct AnimeWebsiteTitle: Identifiable, Sendable {
    let id: String
    let title: String
    let artwork: URL?
    let detail: String
    let url: URL
}

extension AnimeWebsiteTitle {
    init(_ title: FlixMovieTitle) {
        self.init(id: title.id, title: title.title, artwork: title.artwork, detail: title.format, url: title.url)
    }
}

struct AniZoneEpisode: Identifiable, Sendable {
    let id: String
    var title: String = ""

    var label: String { "Episode \(id)" }
}

enum AniZoneCatalog {
    static let website = URL(string: "https://anizone.to")!
    static let browseURL = website.appending(path: "anime")

    static func selection(_ url: URL) -> (series: URL, episode: AniZoneEpisode?)? {
        let parts = url.path.split(separator: "/")
        guard AnimeWebsite.aniZone.contains(url), (2...3).contains(parts.count), parts.first == "anime",
              validComponent(String(parts[1])) else { return nil }
        let series = browseURL.appending(component: String(parts[1]))
        guard parts.count == 3 else { return (series, nil) }
        let id = String(parts[2])
        guard validComponent(id) else { return nil }
        return (series, AniZoneEpisode(id: id))
    }

    static func episodes(_ url: URL) async throws -> [AniZoneEpisode] {
        guard let route = selection(url) else { throw SourceFailure.invalidLink }
        let records: [SeriesEpisode] = try await catalog(route.series, key: "items")
        var seen = Set<String>()
        return records.compactMap { episode in
            guard episode.isUnsafe != true, episode.videosCount != 0, validComponent(episode.slug),
                  seen.insert(episode.slug).inserted else { return nil }
            return AniZoneEpisode(id: episode.slug, title: episode.titleList?["1"] ?? episode.titleList?["5"] ?? "")
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        value.wholeMatch(of: #/[a-zA-Z0-9][a-zA-Z0-9.-]{0,50}/#) != nil
    }

    private struct SeriesEpisode: Decodable {
        let slug: String
        let titleList: [String: String]?
        let isUnsafe: Bool?
        let videosCount: Int?

        private enum CodingKeys: String, CodingKey { case slug, titleList, isUnsafe, videosCount }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try container.decode(String.self, forKey: .slug)
            titleList = try? container.decode([String: String].self, forKey: .titleList)
            isUnsafe = try container.decodeIfPresent(Bool.self, forKey: .isUnsafe)
            videosCount = try container.decodeIfPresent(Int.self, forKey: .videosCount)
        }
    }

    private struct Title: Decodable {
        let slug: String
        let cover: String?
        let mainTitle: String
        let titleList: [String: String]?
        let type: String?
        let isUnsafe: Bool?

        func entry(episode: String? = nil) -> AnimeWebsiteTitle? {
            guard isUnsafe != true, validComponent(slug), episode.map(validComponent) ?? true else { return nil }
            let series = AniZoneCatalog.browseURL.appending(component: slug)
            return AnimeWebsiteTitle(id: episode.map { slug + "-" + $0 } ?? slug,
                                title: titleList?["1"] ?? mainTitle, artwork: cover.flatMap { SourceHTTP.url($0) },
                                detail: episode.map { "Episode " + $0 } ?? type ?? "Anime",
                                url: episode.map { series.appending(component: $0) } ?? series)
        }
    }

    private struct Episode: Decodable {
        let slug: String
        let anime: Title
        let isUnsafe: Bool?
    }

    static func search(_ query: String) async throws -> [AnimeWebsiteTitle] {
        let url = withQuery(browseURL, ["search": query])
        let records: [Title] = try await catalog(url, key: "items")
        return records.compactMap { $0.entry() }
    }

    static func latest() async throws -> [AnimeWebsiteTitle] {
        let records: [Episode] = try await catalog(website, key: "latestEpisodes")
        return records.filter { $0.isUnsafe != true }.compactMap { $0.anime.entry(episode: $0.slug) }
    }

    private static func catalog<Value: Decodable>(_ url: URL, key: String) async throws -> Value {
        let response = try await SourceHTTP.data(url, allowedHosts: ["anizone.to"])
        let document = try SwiftSoup.parse(String(decoding: response, as: UTF8.self))
        let prefix = key + ": JSON.parse('"
        for field in try document.select("[x-data]").array() {
            let value = try field.attr("x-data")
            guard let beginning = value.range(of: prefix),
                  let end = value[beginning.upperBound...].range(of: "'),") else { continue }
            // The catalog stores JSON as an escaped string inside its HTML template.
            let literal = String(value[beginning.upperBound..<end.lowerBound])
            let json = try JSONDecoder().decode(String.self, from: Data(("\"" + literal + "\"").utf8))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Value.self, from: Data(json.utf8))
        }
        throw SourceFailure.unavailable
    }
}
