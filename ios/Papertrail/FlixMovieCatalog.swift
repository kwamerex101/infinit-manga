import Foundation
import SwiftSoup

struct FlixMovieTitle: Identifiable, Sendable {
    let title: String
    let artwork: URL?
    let url: URL
    let format: String

    var id: String { url.lastPathComponent }
}

enum FlixMovieCatalog {
    struct Matches: Sendable {
        let titles: [FlixMovieTitle]
        let catalogOnly: Bool
    }

    private static let host = "flixmovie.st"
    static let browseURL = URL(string: "https://flixmovie.st/browser?genre%5B%5D=animation&sort=popularity")!

    static func popular() async throws -> [FlixMovieTitle] {
        let titles = try await titles(at: browseURL)
        guard !titles.isEmpty else { throw SourceFailure.unavailable }
        return titles
    }

    static func searchURL(_ query: String) -> URL {
        browseURL.appending(queryItems: [URLQueryItem(name: "keyword", value: String(query.prefix(120)))])
    }

    static func search(_ query: String) async throws -> Matches {
        do {
            return Matches(titles: try await titles(at: searchURL(query)), catalogOnly: false)
        } catch SourceFailure.restricted {
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let matches = try await popular().filter { entry in
                words.allSatisfy { entry.title.localizedStandardContains($0) }
            }
            return Matches(titles: matches, catalogOnly: true)
        }
    }

    private static func titles(at url: URL) async throws -> [FlixMovieTitle] {
        let data = try await SourceHTTP.data(url, allowedHosts: [host])
        guard let html = String(data: data, encoding: .utf8) else { throw SourceFailure.unavailable }
        let document = try SwiftSoup.parse(html, url.absoluteString)
        if try document.title() == "Quick check" { throw SourceFailure.restricted }

        var seen = Set<String>()
        return try document.select("a.bf-card[href]").array().compactMap { card in
            let genres = try card.select(".bf-card__genre").text().split(separator: ",")
            guard genres.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Animation" }),
                  let link = SourceHTTP.url(try card.attr("href"), relativeTo: browseURL),
                  link.host == host, link.port == nil, link.query == nil, link.fragment == nil,
                  let route = link.path.wholeMatch(of: #//watch/(tv|movie)-[a-z0-9-]+/#),
                  seen.insert(link.lastPathComponent).inserted else { return nil }
            let title = try card.attr("title")
            guard !title.isEmpty else { return nil }
            let artwork = try card.select("img.bf-card__img[src]").first().flatMap {
                SourceHTTP.url(try $0.attr("src"), relativeTo: browseURL)
            }.flatMap { ($0.host == "image.tmdb.org" || $0.host == host) && $0.port == nil ? $0 : nil }
            return FlixMovieTitle(title: title, artwork: artwork, url: link,
                                  format: route.1 == "movie" ? "Movie" : "TV")
        }
    }
}
