import Foundation

enum MangaDex {
    static let website = URL(string: "https://mangadex.org")!
    private static let api = URL(string: "https://api.mangadex.org")!
    private static let uploads = URL(string: "https://uploads.mangadex.org")!
    private static let provider = ReadingSource.mangaDex
    private static let english = URLQueryItem(name: "translatedLanguage[]", value: "en")
    private static let cover = URLQueryItem(name: "includes[]", value: "cover_art")

    private struct EntityList<T: Decodable>: Decodable {
        let data: [T]
        let total: Int
    }

    private struct Entity<T: Decodable>: Decodable {
        let data: T
    }

    private struct Relationship: Decodable {
        struct Attributes: Decodable {
            let fileName: String?
        }
        let id: String
        let type: String
        let attributes: Attributes?
    }

    private struct MangaEntry: Decodable {
        struct Tag: Decodable {
            struct Attributes: Decodable {
                let name: [String: String]
                let group: String?
            }
            let id: String
            let attributes: Attributes
        }

        struct Attributes: Decodable {
            let title: [String: String]
            let altTitles: [[String: String]]
            let description: [String: String]
            let status: String?
            let originalLanguage: String?
            let year: Int?
            let tags: [Tag]?
        }
        let id: String
        let attributes: Attributes
        let relationships: [Relationship]

        var manga: Manga {
            let title = attributes.title["en"] ?? attributes.altTitles.lazy.compactMap { $0["en"] }.first
                ?? attributes.title["ja-ro"] ?? attributes.title.sorted { $0.key < $1.key }.first?.value ?? "Untitled manga"
            let file = relationships.first { $0.type == "cover_art" }?.attributes?.fileName
            let art = file.map { uploads.appending(path: "covers/\(id)").appending(component: $0 + ".512.jpg") }
            return Manga(slug: id, title: title, cover: art, sourceID: provider)
        }
    }

    private struct ChapterEntry: Decodable {
        struct Attributes: Decodable {
            let chapter: String?
            let title: String?
            let pages: Int
            let externalUrl: String?
            let readableAt: String?
            let publishAt: String?
        }
        let id: String
        let attributes: Attributes
        let relationships: [Relationship]

        var chapter: Chapter? {
            guard attributes.pages > 0, attributes.externalUrl == nil,
                  let mangaID = relationships.first(where: { $0.type == "manga" })?.id else { return nil }
            return makeChapter(id, mangaID: mangaID, number: attributes.chapter ?? "Oneshot", note: attributes.title,
                               releasedAt: ChapterReleaseDate.parse(attributes.readableAt ?? attributes.publishAt))
        }
    }

    static func catalog(page offset: Int? = nil) async throws -> Catalog {
        let offset = offset ?? 0
        let result = try await mangaList([.init(name: "order[latestUploadedChapter]", value: "desc"),
                                          .init(name: "offset", value: String(offset))],
                                         limit: min(24, 10_000 - offset))
        let list = result.data.map(\.manga)
        let next = offset + result.data.count
        return Catalog(featured: offset == 0 ? Array(list.prefix(1)) : [], latest: list,
                       nextPage: !list.isEmpty && next < min(10_000, result.total) ? next : nil)
    }

    static func search(_ title: String) async throws -> [Manga] {
        let result = try await mangaList([.init(name: "title", value: title), .init(name: "order[relevance]", value: "desc")])
        return result.data.map(\.manga)
    }

    static func agentTags() async throws -> [String: String] {
        struct Tags: Decodable { let data: [MangaEntry.Tag] }
        let response: Tags = try await get("manga/tag")
        return response.data.reduce(into: [:]) { tags, tag in
            if let name = tag.attributes.name["en"] { tags[name] = tag.id }
        }
    }

    static func agentResults(_ filters: [URLQueryItem]) async throws -> [AgentTitle] {
        let result: EntityList<MangaEntry> = try await get("manga", [
            .init(name: "limit", value: "20"),
            .init(name: "contentRating[]", value: "safe"),
            .init(name: "contentRating[]", value: "suggestive"),
            cover
        ] + filters)
        return result.data.map { entry in
            AgentTitle(manga: entry.manga, synopsis: entry.attributes.description["en"] ?? "",
                       status: entry.attributes.status, language: entry.attributes.originalLanguage,
                       year: entry.attributes.year,
                       tags: entry.attributes.tags?.compactMap { $0.attributes.name["en"] } ?? [],
                       alternateTitles: entry.attributes.title.values.sorted()
                           + entry.attributes.altTitles.flatMap { $0.values },
                       recommendationTags: entry.attributes.tags?.compactMap {
                           let group = $0.attributes.group
                           return group == "genre" || group == "theme" ? $0.id : nil
                       } ?? [])
        }
    }

    private static func mangaList(_ extras: [URLQueryItem], limit: Int = 24) async throws -> EntityList<MangaEntry> {
        try await get("manga", [
            .init(name: "limit", value: String(limit)),
            .init(name: "availableTranslatedLanguage[]", value: "en"),
            .init(name: "hasAvailableChapters", value: "true"),
            cover
        ] + extras)
    }

    static func series(_ id: String) async throws -> Series {
        guard UUID(uuidString: id) != nil else { throw SourceFailure.invalidLink }
        async let entry: Entity<MangaEntry> = get("manga/\(id)", [cover])
        async let first = try? chapterFeed(id, offset: 0, ascending: true, limit: 12)
        let manga = try await entry.data
        return Series(manga: manga.manga, id: id, synopsis: manga.attributes.description["en"] ?? "",
                      first: await first?.data.compactMap(\.chapter).first)
    }

    static func chapters(_ id: String, offset: Int, ascending: Bool) async throws -> ChapterList {
        // Publisher links are skipped. Advance by the upstream count to keep paging aligned.
        var start = offset
        while true {
            let result = try await chapterFeed(id, offset: start, ascending: ascending, limit: 80)
            let chapters = result.data.compactMap(\.chapter)
            let next = start + result.data.count
            let hasMore = !result.data.isEmpty && next < min(10_000, result.total)
            if !chapters.isEmpty || !hasMore {
                return ChapterList(items: chapters, nextOffset: hasMore ? next : nil)
            }
            start = next
        }
    }

    private static func chapterFeed(_ id: String, offset: Int, ascending: Bool, limit: Int) async throws -> EntityList<ChapterEntry> {
        try await get("manga/\(id)/feed", [
            english, .init(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset)),
            .init(name: "order[chapter]", value: ascending ? "asc" : "desc")
        ])
    }

    static func content(_ requested: Chapter) async throws -> ChapterContent {
        guard UUID(uuidString: requested.id) != nil else { throw SourceFailure.invalidLink }
        let response: Entity<ChapterEntry> = try await get("chapter/\(requested.id)")
        if response.data.attributes.externalUrl != nil { throw SourceFailure.externalChapter }
        guard let chapter = response.data.chapter else { throw SourceFailure.noPages }

        async let manga: Entity<MangaEntry> = get("manga/\(chapter.slug)", [cover])
        async let images = pageVariants(chapter.id)
        async let adjacent = neighbors(chapter)
        let (previous, next) = await adjacent
        let variants = try await images
        return try await ChapterContent(chapter: chapter, manga: manga.data.manga, pages: variants.original,
                                        previous: previous, next: next, optimizedPages: variants.optimized)
    }

    static func pages(_ id: String, quality: ReaderImageQuality) async throws -> [URL] {
        let variants = try await pageVariants(id)
        return quality == .optimized ? variants.optimized ?? variants.original : variants.original
    }

    private static func pageVariants(_ id: String) async throws -> (original: [URL], optimized: [URL]?) {
        struct Manifest: Decodable {
            struct Files: Decodable {
                let hash: String
                let data: [String]
                let dataSaver: [String]?
            }
            let baseUrl: String
            let chapter: Files
        }
        let result: Manifest = try await get("at-home/server/\(id)", [.init(name: "forcePort443", value: "true")])
        guard let base = SourceHTTP.url(result.baseUrl), !result.chapter.data.isEmpty else { throw SourceFailure.noPages }
        func urls(_ files: [String], directory: String) -> [URL] {
            files.map { file in
                base.appending(path: directory).appending(component: result.chapter.hash).appending(component: file)
            }
        }
        let original = urls(result.chapter.data, directory: "data")
        let optimized = result.chapter.dataSaver.flatMap { files in
            files.count == original.count ? urls(files, directory: "data-saver") : nil
        }
        return (original, optimized)
    }

    private static func neighbors(_ chapter: Chapter) async -> (Chapter?, Chapter?) {
        struct Aggregate: Decodable {
            struct Volume: Decodable {
                struct Row: Decodable {
                    let id: String
                    let chapter: String
                    let others: [String]
                    let isUnavailable: Bool?
                }
                let chapters: [String: Row]

                init(from decoder: Decoder) throws {
                    enum Key: String, CodingKey { case chapters }
                    let container = try decoder.container(keyedBy: Key.self)
                    if let rows = try? container.decode([String: Row].self, forKey: .chapters) {
                        chapters = rows
                    } else {
                        let rows = try container.decode([Row].self, forKey: .chapters)
                        chapters = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    }
                }
            }
            let volumes: [String: Volume]
        }
        guard let aggregate: Aggregate = try? await get("manga/\(chapter.slug)/aggregate", [english]) else { return (nil, nil) }
        guard let number = Double(chapter.number) else { return (nil, nil) }
        var previous: Aggregate.Volume.Row?
        var next: Aggregate.Volume.Row?
        for volume in aggregate.volumes.values {
            for entry in volume.chapters.values {
                guard entry.isUnavailable != true, let value = Double(entry.chapter) else { continue }
                if value < number && value > (previous.flatMap { Double($0.chapter) } ?? -.infinity) { previous = entry }
                if value > number && value < (next.flatMap { Double($0.chapter) } ?? .infinity) { next = entry }
            }
        }
        return (previous.map { makeChapter($0.id, mangaID: chapter.slug, number: $0.chapter) },
                next.map { makeChapter($0.id, mangaID: chapter.slug, number: $0.chapter) })
    }

    static func seriesID(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count >= 2, parts[0] == "title",
              UUID(uuidString: String(parts[1])) != nil else { return nil }
        return String(parts[1]).lowercased()
    }

    static func chapterLink(_ url: URL) -> Chapter? {
        let parts = url.path.split(separator: "/")
        guard ReadingSource.match(url) == provider, parts.count == 2, parts[0] == "chapter",
              UUID(uuidString: String(parts[1])) != nil else { return nil }
        return makeChapter(String(parts[1]).lowercased(), mangaID: "", number: "")
    }

    private static func makeChapter(_ id: String, mangaID: String, number: String, note: String? = nil, releasedAt: Date? = nil) -> Chapter {
        Chapter(id: id, slug: mangaID, number: number, source: website.appending(path: "chapter/\(id)"),
                note: note, sourceID: provider, releasedAt: releasedAt)
    }

    private static func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { components.queryItems = items }
        return try JSONDecoder().decode(T.self, from: try await SourceHTTP.data(components.url!, allowedHosts: ["api.mangadex.org"]))
    }

    static func report(url: URL, success: Bool, response: HTTPURLResponse?, bytes: Int, started: Date) {
        guard let host = url.host, host != "mangadex.org", !host.hasSuffix(".mangadex.org") else { return }
        let duration = max(0, Int(Date().timeIntervalSince(started) * 1000))
        let body: [String: Any] = [
            "url": url.absoluteString, "success": success, "bytes": bytes, "duration": duration,
            "cached": response?.value(forHTTPHeaderField: "X-Cache")?.hasPrefix("HIT") == true
        ]
        var request = URLRequest(url: URL(string: "https://api.mangadex.network/report")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Task.detached(priority: .utility) { [request] in
            _ = try? await SourceHTTP.session.data(for: request)
        }
    }
}
