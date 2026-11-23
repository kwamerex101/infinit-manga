import Foundation

@MainActor
final class SourceMemoryCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let value: Value
        let expires: ContinuousClock.Instant
        var accessed: ContinuousClock.Instant
    }

    private let limit: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [Key: Entry] = [:]
    private var requests: [Key: Task<Value, Error>] = [:]
    private var generation = 0

    init(limit: Int, lifetime: Duration) {
        self.limit = limit
        self.lifetime = lifetime
    }

    func value(for key: Key, refresh: Bool = false, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let now = clock.now
        if !refresh, var entry = entries[key], entry.expires > now {
            entry.accessed = now
            entries[key] = entry
            return entry.value
        }

        let request: Task<Value, Error>
        if let pending = requests[key] {
            request = pending
        } else {
            let requestGeneration = generation
            request = Task {
                defer {
                    if generation == requestGeneration { requests[key] = nil }
                }
                let value = try await load()
                guard generation == requestGeneration else { return value }
                let received = clock.now
                entries = entries.filter { $0.value.expires > received }
                entries[key] = Entry(value: value, expires: received + lifetime, accessed: received)
                if entries.count > limit, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed }) {
                    entries.removeValue(forKey: oldest.key)
                }
                return value
            }
            requests[key] = request
        }

        let value = try await request.value
        try Task.checkCancellation()
        return value
    }

    func removeAll() {
        generation += 1
        entries.removeAll()
        requests.removeAll()
    }
}

@MainActor
enum SourceMemory {
    struct Item: Hashable, Sendable {
        let source: ReadingSource
        let id: String
    }

    struct ChapterPage: Hashable, Sendable {
        let series: Item
        let offset: Int
        let ascending: Bool
    }

    static let catalogs = SourceMemoryCache<Item, Catalog>(limit: 24, lifetime: .seconds(45))
    static let searches = SourceMemoryCache<Item, [Manga]>(limit: 24, lifetime: .seconds(60))
    static let series = SourceMemoryCache<Item, Series>(limit: 24, lifetime: .seconds(150))
    static let chapterLists = SourceMemoryCache<ChapterPage, ChapterList>(limit: 64, lifetime: .seconds(150))
    static let chapters = SourceMemoryCache<Item, ChapterContent>(limit: 18, lifetime: .seconds(45))

    static func removeAll() {
        catalogs.removeAll()
        searches.removeAll()
        series.removeAll()
        chapterLists.removeAll()
        chapters.removeAll()
    }
}
