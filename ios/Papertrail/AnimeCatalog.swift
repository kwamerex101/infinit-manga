import Foundation
import SwiftSoup

enum AnimeProvider: String, CaseIterable {
    case archive, aniWatch, flixMovie, aniZone

    var name: String {
        switch self {
        case .archive: "Internet Archive"
        case .aniWatch: "AniWatch"
        case .flixMovie: "FlixMovie"
        case .aniZone: "AniZone"
        }
    }

    var website: URL {
        switch self {
        case .archive: URL(string: "https://archive.org/details/animationandcartoons")!
        case .aniWatch: AniWatchCatalog.website
        case .flixMovie: FlixMovieCatalog.browseURL
        case .aniZone: AniZoneCatalog.browseURL
        }
    }
}

struct AnimeSource: Hashable, Identifiable {
    let id: String
    let title: String
    let url: URL
    var provider: AnimeProvider { .archive }
}

struct AnimeEpisode: Hashable, Identifiable {
    let id: String
    let title: String
    let number: Int?
    let sources: [AnimeSource]
    var credits: URL? = nil

    var displayNumber: String { number.map { "Episode \($0)" } ?? "Special" }
}

struct AnimeSeason: Identifiable {
    let id: String
    let title: String
    let episodes: [AnimeEpisode]
}

struct AnimeShow: Identifiable {
    let id: String
    let title: String
    let studio: String
    let synopsis: String
    let artwork: URL
    let officialPage: URL
    let seasons: [AnimeSeason]

    var episodes: [AnimeEpisode] { seasons.flatMap(\.episodes) }
}

enum AnimeCatalog {
    private static let morevna = AnimeShow(
        id: "morevna", title: "Morevna", studio: "Morevna Project",
        synopsis: "A cyberpunk anime inspired by Russian folklore. Marya Morevna and Ivan Tsarevich cross paths with biker gangs and ruthless machines.",
        artwork: URL(string: "https://morevnaproject.org/wp-content/uploads/2018/02/poster-youtube-alt2-en.jpg")!,
        officialPage: URL(string: "https://morevnaproject.org/anime/")!,
        seasons: [
            AnimeSeason(id: "morevna-specials", title: "Specials", episodes: [
                AnimeEpisode(id: "morevna-demo", title: "The Beautiful Queen Marya Morevna", number: nil, sources: [
                    AnimeSource(id: "archive-org", title: "Internet Archive · In-app player",
                                url: URL(string: "https://archive.org/download/TheBeautifulQueenMaryaMorevnaDemo/demo-20121110-final-1920x1080.mp4")!),
                ], credits: URL(string: "https://morevnaproject.org/anime/demo/"))
            ])
        ]
    )

    static let shows = [morevna]
    static let featured = morevna

    static func show(_ id: AnimeShow.ID) -> AnimeShow? { shows.first { $0.id == id } }

    static func search(_ query: String) -> [AnimeShow] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return shows }
        return shows.filter { show in
            let searchable = [show.title, show.studio, show.synopsis]
                + show.seasons.map(\.title)
                + show.episodes.map(\.title)
            return words.allSatisfy { word in
                searchable.contains { $0.localizedStandardContains(String(word)) }
            }
        }
    }
}

struct AniWatchTitle: Codable, Identifiable {
    let id: String
    let title: String
    let artwork: URL?
    let url: URL
    let format: String

    var libraryID: String { "aniwatch-\(id)" }

    func watchURL(episode: AniWatchEpisode?) -> URL? {
        guard url.scheme == "https", url.host == AniWatchCatalog.siteHost, url.port == nil,
              url.user == nil, url.password == nil,
              let idMatch = url.path.wholeMatch(of: #//watch/[a-zA-Z0-9-]+-([0-9]+)/?/#),
              idMatch.1 == id, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = nil
        let id = episode?.id ?? components.queryItems?.first(where: { $0.name == "ep" })?.value
        if let id, id.wholeMatch(of: #/[0-9]{1,12}/#) != nil {
            components.queryItems = [URLQueryItem(name: "ep", value: id)]
        } else {
            components.queryItems = nil
        }
        return components.url
    }
}

struct AniWatchEpisode: Codable, Identifiable {
    let id: String
    let number: String
    let title: String

    var historyID: String { "aniwatch-\(id)" }
    var label: String { "Episode \(number)" }
}

struct AniWatchSelection: Codable {
    let show: AniWatchTitle
    let episode: AniWatchEpisode
}

struct AniWatchServer: Identifiable {
    let name: String
    let track: String
    let url: URL
    var id: URL { url }

    static let hosts: Set<String> = ["zokoanime.video", "megaplay.buzz"]

    var trackLabel: String {
        switch track {
        case "sub": "Sub"
        case "hsub": "Hard sub"
        case "dub": "Dub"
        default: track.uppercased()
        }
    }

    func playbackURL(start: Int) -> URL? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let generated = ["time", "autostart", "autonext", "color"]
        var query = parts?.queryItems?.filter { !generated.contains($0.name) } ?? []
        if start > 0 { query.append(URLQueryItem(name: "time", value: String(start))) }
        query.append(URLQueryItem(name: "autostart", value: "true"))
        query.append(URLQueryItem(name: "autonext", value: "0"))
        if url.host == "zokoanime.video" { query.append(URLQueryItem(name: "color", value: "BCA3FF")) }
        parts?.queryItems = query
        return parts?.url
    }
}

enum AniWatchCatalog {
    static let website = URL(string: "https://aniwatchtv.ws/")!
    static let browseURL = website.appending(path: "recently-updated")
    static let siteHost = "aniwatchtv.ws"
    private static let imageHosts = [siteHost, "cdn.anipixcdn.co"]

    static func latest() async throws -> [AniWatchTitle] {
        let document = try await document(at: website.appending(path: "home"))
        guard let section = try document.select("section.block_area_home").first(where: { section in
            try section.select(".cat-heading").text() == "Latest Episode"
        }) else { throw SourceFailure.unavailable }
        let titles = try cards(in: section, limit: 14)
        guard !titles.isEmpty else { throw SourceFailure.unavailable }
        return titles
    }

    static func search(_ title: String) async throws -> [AniWatchTitle] {
        let url = website.appending(path: "search").appending(queryItems: [
            URLQueryItem(name: "keyword", value: String(title.prefix(120)))
        ])
        let page = try await document(at: url)
        return try cards(in: page, limit: 30)
    }

    static func episodes(of show: AniWatchTitle) async throws -> [AniWatchEpisode] {
        guard let showURL = show.watchURL(episode: nil) else { throw SourceFailure.invalidLink }
        let page = try await episodeFragment(path: "list/\(show.id)")
        var seen = Set<String>()
        let episodes: [AniWatchEpisode] = try page.select(".ep-item[href]").array().compactMap { item in
            let id = try item.attr("data-id")
            let number = try item.attr("data-number")
            guard id.wholeMatch(of: #/[0-9]{1,12}/#) != nil, !number.isEmpty, number.count <= 24,
                  let url = SourceHTTP.url(try item.attr("href"), relativeTo: showURL),
                  url.host == siteHost, url.port == nil, url.path == showURL.path,
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                    URLQueryItem(name: "ep", value: id)) == true, seen.insert(id).inserted else { return nil }
            let title = try item.select(".ep-name").first()?.text() ?? item.attr("title")
            return AniWatchEpisode(id: id, number: number, title: String(title.prefix(180)))
        }
        guard !episodes.isEmpty else { throw SourceFailure.unavailable }
        return episodes
    }

    static func servers(for episode: AniWatchEpisode) async throws -> [AniWatchServer] {
        guard episode.id.wholeMatch(of: #/[0-9]{1,12}/#) != nil else { throw SourceFailure.invalidLink }
        let page = try await episodeFragment(path: "servers", query: [URLQueryItem(name: "episodeId", value: episode.id)])
        var seen = Set<URL>()
        let servers: [AniWatchServer] = try page.select(".server-item[data-hash]").array().compactMap { item in
            let track = try item.attr("data-type")
            guard ["sub", "hsub", "dub"].contains(track),
                  let data = Data(base64Encoded: try item.attr("data-hash")),
                  let link = String(data: data, encoding: .utf8), let url = SourceHTTP.url(link),
                  url.port == nil, let host = url.host, AniWatchServer.hosts.contains(host),
                  (host != "zokoanime.video" || url.path.hasPrefix("/stream/")),
                  seen.insert(url).inserted else { return nil }
            return AniWatchServer(name: try item.attr("data-server-name"), track: track, url: url)
        }
        guard !servers.isEmpty else { throw SourceFailure.unavailable }
        return servers
    }

    private struct EpisodeFragment: Decodable {
        let status: Bool
        let html: String?
    }

    private static func episodeFragment(path: String, query: [URLQueryItem] = []) async throws -> Document {
        let route = website.appending(path: "api/theme/episode/\(path)")
        let url = query.isEmpty ? route : route.appending(queryItems: query)
        let payload = try await SourceHTTP.data(url, allowedHosts: [siteHost])
        let fragment = try JSONDecoder().decode(EpisodeFragment.self, from: payload)
        guard fragment.status, let html = fragment.html else { throw SourceFailure.unavailable }
        return try SwiftSoup.parseBodyFragment(html, website.absoluteString)
    }

    private static func document(at url: URL) async throws -> Document {
        let payload = try await SourceHTTP.data(url, allowedHosts: [siteHost])
        guard let html = String(data: payload, encoding: .utf8) else { throw SourceFailure.unavailable }
        return try SwiftSoup.parse(html, url.absoluteString)
    }

    private static func cards(in root: Element, limit: Int) throws -> [AniWatchTitle] {
        var seen = Set<String>()
        var results: [AniWatchTitle] = []
        for card in try root.select(".flw-item") {
            guard let link = try card.select("a.film-poster-ahref[href]").first(),
                  let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  url.host == siteHost, url.port == nil,
                  let match = url.path.wholeMatch(of: #//watch/[a-zA-Z0-9-]+-(\d+)/?/#) else { continue }
            let id = String(match.1)
            let title = try card.select(".film-name a").text()
            guard !title.isEmpty, seen.insert(id).inserted else { continue }
            let artwork = try card.select("img.film-poster-img[src]").first().flatMap {
                SourceHTTP.url(try $0.attr("src"), relativeTo: website)
            }.flatMap { imageHosts.contains($0.host ?? "") && $0.port == nil ? $0 : nil }
            let format = try card.select(".fd-infor .fdi-item").first()?.text() ?? ""
            results.append(AniWatchTitle(id: id, title: title, artwork: artwork, url: url, format: format))
            if results.count == limit { break }
        }
        return results
    }
}
