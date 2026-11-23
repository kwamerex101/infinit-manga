import Foundation

struct AgentTitle: Identifiable {
    let manga: Manga
    let synopsis: String
    let status: String?
    let language: String?
    let year: Int?
    let tags: [String]
    let alternateTitles: [String]
    let recommendationTags: [String]

    var id: String { manga.id }

    var metadata: [String] {
        var items = [status?.capitalized].compactMap { $0 }
        if tags.contains("Full Color") {
            items.append("Full color")
        } else if tags.contains("Official Colored") {
            items.append("Officially colored")
        }
        if tags.contains("Martial Arts") { items.append("Martial arts") }
        switch language {
        case "ja": items.append("Japanese")
        case "ko": items.append("Korean")
        case "zh", "zh-hk": items.append("Chinese")
        default: break
        }
        if let year { items.append(String(year)) }
        return items
    }
}

struct AgentMessage: Encodable {
    enum Role: String, Encodable { case user, assistant }

    let role: Role
    let content: String
}

struct AgentReply {
    let answer: String
    var titles: [AgentTitle] = []
    var query: AgentCatalogQuery?
}

struct AgentCatalogQuery {
    var title: String?
    var status: String?
    var language: String?
    var tags: [String] = []
    var excludedTags: [String] = []

    var parameters: [URLQueryItem] {
        var items = tags.map { URLQueryItem(name: "includedTags[]", value: $0) }
        items += excludedTags.map { URLQueryItem(name: "excludedTags[]", value: $0) }
        if !tags.isEmpty { items.append(.init(name: "includedTagsMode", value: "AND")) }
        if let title { items.append(.init(name: "title", value: title)) }
        if let status { items.append(.init(name: "status[]", value: status)) }
        if let language { items.append(.init(name: "originalLanguage[]", value: language)) }
        items.append(.init(name: title == nil ? "order[followedCount]" : "order[relevance]", value: "desc"))
        return items
    }
}

@MainActor
@Observable
final class MangaAgent {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let recentReads: [Manga]?
        var reply: AgentReply?
        var failed = false
    }

    private(set) var turns: [Turn] = []
    private var request: Task<Void, Never>?
    private var tagIDs: [String: String]?

    var waiting: Bool { request != nil }

    func ask(_ question: String, readingHistory: [Manga]) {
        guard request == nil else { return }
        let recentReads = Self.requestsReadingSuggestions(question) ? Self.recentSeries(readingHistory) : nil
        turns.append(Turn(question: question, recentReads: recentReads))
        loadLastTurn()
    }

    func retry() {
        guard request == nil, turns.last?.failed == true else { return }
        loadLastTurn()
    }

    func cancelPendingReply() {
        guard let request else { return }
        request.cancel()
        self.request = nil
        if let index = turns.indices.last { turns[index].failed = true }
    }

    func reset() {
        cancelPendingReply()
        turns.removeAll()
    }

    private func loadLastTurn() {
        guard let turn = turns.last else { return }
        let index = turns.count - 1
        turns[index].failed = false
        let history = Array(turns.prefix(index).filter { $0.reply != nil && $0.recentReads == nil }.suffix(5))
        request = Task {
            do {
                let reply: AgentReply
                if let recentReads = turn.recentReads {
                    reply = try await suggestions(basedOn: recentReads)
                } else {
                    reply = try await answer(turn.question, history: history)
                }
                guard !Task.isCancelled, turns.last?.id == turn.id else { return }
                turns[index].reply = reply
            } catch {
                guard !Task.isCancelled, turns.last?.id == turn.id else { return }
                turns[index].failed = true
            }
            request = nil
        }
    }

    private func answer(_ question: String, history: [Turn]) async throws -> AgentReply {
        let endpoint = (Bundle.main.object(forInfoDictionaryKey: "MangaAgentEndpoint") as? String)
            .flatMap { SourceHTTP.url($0) }
        var messages = history.flatMap { turn in
            [AgentMessage(role: .user, content: turn.question),
             AgentMessage(role: .assistant, content: turn.reply?.answer ?? "")]
        }
        messages.append(AgentMessage(role: .user, content: question))
        if let endpoint {
            do {
                return try await serverAnswer(endpoint, messages: messages)
            } catch {
                try Task.checkCancellation()
            }
        }

        let availableTags: [String: String]
        if let tagIDs {
            availableTags = tagIDs
        } else {
            availableTags = try await MangaDex.agentTags()
            tagIDs = availableTags
        }

        // Relay replies have no local query, so replay user turns when switching to MangaDex.
        let previous = history.reduce(nil as AgentCatalogQuery?) { previous, turn in
            turn.reply?.query ?? Self.catalogQuery(turn.question, tags: availableTags, previous: previous)
        }
        guard let query = Self.catalogQuery(question, tags: availableTags, previous: previous) else {
            return AgentReply(answer: "Try a series title, or ask for a genre, publication status, and whether you want full color.")
        }
        let matches = try await MangaDex.agentResults(query.parameters)
        let exact = matches.filter {
            guard let title = query.title else { return false }
            return $0.manga.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let titles = exact.isEmpty ? matches : exact
        let answer: String
        if titles.isEmpty {
            answer = "MangaDex has no matches for that search. Try changing a filter or checking the title spelling."
        } else if query.title != nil {
            answer = "Here’s what I found for that title."
        } else {
            answer = "Here are some matches. Tap a title for details."
        }
        return AgentReply(answer: answer, titles: titles, query: query)
    }

    private func serverAnswer(_ endpoint: URL, messages: [AgentMessage]) async throws -> AgentReply {
        struct Payload: Encodable { let messages: [AgentMessage] }
        struct Response: Decodable { let answer: String; let mangaDexIDs: [String] }

        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Payload(messages: messages))
        let (data, response) = try await SourceHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url == endpoint else {
            throw SourceFailure.unavailable
        }
        let reply = try JSONDecoder().decode(Response.self, from: data)
        guard !reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SourceFailure.unavailable
        }
        guard !reply.mangaDexIDs.isEmpty else { return AgentReply(answer: reply.answer) }
        var seen: Set<String> = []
        let ids = reply.mangaDexIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            .filter { seen.insert($0).inserted }.prefix(5)
        guard !ids.isEmpty else { throw SourceFailure.unavailable }
        let titles = try await MangaDex.agentResults(ids.map { .init(name: "ids[]", value: $0) })
        let byID = Dictionary(titles.map { ($0.manga.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let hydrated = ids.compactMap { byID[$0] }
        guard !hydrated.isEmpty else { throw SourceFailure.unavailable }
        return AgentReply(answer: reply.answer, titles: hydrated)
    }

    static func requestsReadingSuggestions(_ question: String) -> Bool {
        let pattern = #"\b(?:recent (?:reads|reading)|reading history|what i(?:’ve|'ve| have)? read|manga i(?:’ve|'ve| have)? read|recommendations for me)\b"#
        return question.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
    }

    static func recentSeries(_ history: [Manga]) -> [Manga] {
        var titles = Set<String>()
        var result: [Manga] = []
        for manga in history where titles.insert(titleKey(manga.title)).inserted {
            result.append(manga)
            if result.count == 5 { break }
        }
        return result
    }

    private static func titleKey(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func titles(for manga: AgentTitle) -> Set<String> {
        Set(([manga.manga.title] + manga.alternateTitles).map(titleKey).filter { !$0.isEmpty })
    }

    private func suggestions(basedOn recent: [Manga]) async throws -> AgentReply {
        guard !recent.isEmpty else {
            return AgentReply(answer: "Read a chapter first, then I can suggest manga based on your recent reads.")
        }

        let ids = recent.filter { $0.provider == .mangaDex }
            .compactMap { UUID(uuidString: $0.slug)?.uuidString.lowercased() }
        var seeds: [AgentTitle] = []
        if !ids.isEmpty {
            seeds = try await MangaDex.agentResults(ids.map { .init(name: "ids[]", value: $0) })
        }
        for manga in recent where manga.provider != .mangaDex {
            try await Task.sleep(for: .milliseconds(250))
            let matches = try await MangaDex.agentResults([
                .init(name: "title", value: manga.title),
                .init(name: "order[relevance]", value: "desc")
            ])
            if let exact = matches.first(where: { Self.titles(for: $0).contains(Self.titleKey(manga.title)) }) {
                seeds.append(exact)
            }
        }

        var seedIDs = Set<String>()
        var readTitles = Set(recent.map { Self.titleKey($0.title) })
        var tagCounts: [String: Int] = [:]
        for seed in seeds where seedIDs.insert(seed.manga.slug).inserted {
            readTitles.formUnion(Self.titles(for: seed))
            for tag in Set(seed.recommendationTags) {
                tagCounts[tag, default: 0] += 1
            }
        }
        guard !tagCounts.isEmpty else {
            return AgentReply(answer: "I couldn’t match your recent reads to MangaDex genres yet. Try asking for a genre you enjoy.")
        }

        let preferredTags = tagCounts.keys.sorted {
            let left = tagCounts[$0, default: 0]
            let right = tagCounts[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.prefix(4)
        var filters = preferredTags.map { URLQueryItem(name: "includedTags[]", value: $0) }
        filters += [
            .init(name: "includedTagsMode", value: "OR"),
            .init(name: "hasAvailableChapters", value: "true"),
            .init(name: "order[followedCount]", value: "desc")
        ]
        let candidates = try await MangaDex.agentResults(filters)
        var ranked: [(index: Int, title: AgentTitle, score: Int)] = []
        for (index, title) in candidates.enumerated() {
            var score = 0
            for tag in Set(title.recommendationTags) {
                score += tagCounts[tag, default: 0]
            }
            ranked.append((index, title, score))
        }
        ranked.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }

        var suggestions: [AgentTitle] = []
        for entry in ranked where entry.score > 0 && !seedIDs.contains(entry.title.manga.slug) {
            let names = Self.titles(for: entry.title)
            guard names.isDisjoint(with: readTitles) else { continue }
            readTitles.formUnion(names)
            suggestions.append(entry.title)
            if suggestions.count == 5 { break }
        }
        guard !suggestions.isEmpty else {
            return AgentReply(answer: "MangaDex didn’t return any new matches for your recent reads.")
        }
        return AgentReply(answer: "These MangaDex titles share genres or themes with your recent reads.",
                          titles: suggestions)
    }

    static func catalogQuery(_ question: String, tags: [String: String], previous: AgentCatalogQuery?) -> AgentCatalogQuery? {
        let followUp = question.range(of: #"^\s*(only\b|what about\b|how about\b|and\b|also\b|but\b|same\b|instead\b|make (it|them)\b)"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
        let quotedTitle = question.firstCapture(#"["“]([^"”]+)["”]"#)
        if let quotedTitle {
            var query = AgentCatalogQuery()
            query.title = quotedTitle
            return query
        }

        var query = followUp ? previous ?? AgentCatalogQuery() : AgentCatalogQuery()
        var remaining = question
        let statuses = [
            ("completed", #"\b(completed|complete|finished|ended)\b"#),
            ("ongoing", #"\b(ongoing|still running|still publishing)\b"#),
            ("hiatus", #"\b(on hiatus|hiatus)\b"#),
            ("cancelled", #"\b(cancelled|canceled)\b"#)
        ]
        for (status, pattern) in statuses where remaining.consume(pattern) {
            query.status = status
        }
        let languages = [
            ("ja", #"\b(japanese|from japan)\b"#),
            ("ko", #"\b(korean|manhwa|from korea)\b"#),
            ("zh", #"\b(chinese|manhua|from china)\b"#)
        ]
        for (language, pattern) in languages where remaining.consume(pattern) {
            query.language = language
        }

        if let title = question.firstCapture(#"^\s*(?:tell me about|what is|what's the status of)\s+(.+?)[?!.]*\s*$"#)
            ?? question.firstCapture(#"^\s*is\s+(.+?)\s+(?:completed|finished|ongoing|in (?:full )?colou?r)[?!.]*\s*$"#) {
            query.title = title
            query.status = nil
            query.language = nil
            return query
        }

        var patterns = tags.keys.sorted { $0.count > $1.count }.map {
            ($0, "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b")
        }
        patterns.insert(contentsOf: [
            ("Full Color", #"\b(full[- ]colou?r(?:ed)?|colou?red|in colou?r)\b"#),
            ("Martial Arts", #"\b(martial[- ]arts?|kung fu)\b"#)
        ], at: 0)
        for (name, pattern) in patterns {
            guard let id = tags[name] else { continue }
            if remaining.consume(#"\b(?:without|exclude|no)\s+"# + pattern) {
                query.tags.removeAll { $0 == id }
                if !query.excludedTags.contains(id) { query.excludedTags.append(id) }
            } else if remaining.consume(pattern) {
                query.excludedTags.removeAll { $0 == id }
                if !query.tags.contains(id) { query.tags.append(id) }
            }
        }

        if query.status != nil || query.language != nil || !query.tags.isEmpty || !query.excludedTags.isEmpty {
            return query
        }

        let title = question.replacingOccurrences(
            of: #"^\s*(?:find|search for|look up|show me|what about|how about)\s+"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.")))
        guard !title.isEmpty,
              question.range(of: #"^(how|why|when|where|who|can|what|recommend|give me|i want)\b"#,
                             options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        query.title = title
        return query
    }
}

private extension String {
    func firstCapture(_ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)),
              let group = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[group])
    }

    @discardableResult
    mutating func consume(_ pattern: String) -> Bool {
        guard let range = range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return false }
        replaceSubrange(range, with: " ")
        return true
    }
}
