import Foundation
import Observation

@MainActor
@Observable
final class SavedChapterUpdates {
    enum TitleState {
        case unread, caughtUp, unknown

        var sortOrder: Int {
            switch self {
            case .unread: 0
            case .caughtUp: 1
            case .unknown: 2
            }
        }
    }

    struct Snapshot: Codable, Sendable {
        let chapterKeys: [String]
        let latestRelease: Date?
        let checkedAt: Date
        var alternateKeys: [String: [String]]? = nil
    }

    private let cacheFile = CacheStorage.locations.savedChapters
    private(set) var entries: [String: Snapshot] = [:]
    private var restored = false
    private var revision = 0

    func refresh(_ bookmarks: [Manga], force: Bool = false) async {
        if !restored {
            restored = true
            if let data = try? Data(contentsOf: cacheFile),
               let cached = try? JSONDecoder().decode([String: Snapshot].self, from: data) {
                entries = cached
            }
        }

        let currentRevision = revision
        let cachedCount = entries.count
        let ids = Set(bookmarks.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        let deadline = Date.now.addingTimeInterval(-10 * 60)
        let due = bookmarks.filter { force || (entries[$0.id]?.checkedAt ?? .distantPast) < deadline }
        var changed = cachedCount != entries.count
        defer { if changed && revision == currentRevision { save() } }

        for start in stride(from: 0, to: due.count, by: 3) {
            if Task.isCancelled || revision != currentRevision { break }
            await withTaskGroup(of: (String, Snapshot?).self) { group in
                for manga in due[start..<min(start + 3, due.count)] {
                    group.addTask {
                        (manga.id, try? await Self.fetch(manga, force: force))
                    }
                }
                for await (id, snapshot) in group {
                    guard !Task.isCancelled, revision == currentRevision, let snapshot,
                          (entries[id]?.checkedAt ?? .distantPast) <= snapshot.checkedAt else { continue }
                    entries[id] = snapshot
                    changed = true
                }
            }
            if start + 3 < due.count { try? await Task.sleep(for: .milliseconds(350)) }
        }
    }

    func clear() {
        revision += 1
        restored = true
        entries.removeAll()
        CacheStorage.clearSavedChapters()
    }

    private nonisolated static func fetch(_ manga: Manga, force: Bool) async throws -> Snapshot {
        let checkedAt = Date.now
        let series = try await manga.provider.series(manga.slug, refresh: force)
        var keysByChapter: [String: Set<String>] = [:]
        var latest: Date?
        var offset: Int? = 0

        while let current = offset {
            let page = try await manga.provider.chapters(series, offset: current, ascending: false, refresh: force)
            try Task.checkCancellation()
            if let next = page.nextOffset, next <= current { throw SourceFailure.unavailable }
            let matching = page.items.filter { $0.slug == manga.slug }
            guard page.items.isEmpty || !matching.isEmpty else { throw SourceFailure.unavailable }
            for chapter in matching {
                let releases = chapter.releases
                keysByChapter[chapter.rowKey, default: []].formUnion(releases.map(\.localKey))
                if let releasedAt = releases.compactMap(\.releasedAt).max(), releasedAt > (latest ?? .distantPast) {
                    latest = releasedAt
                }
            }
            offset = page.nextOffset
            if offset != nil { try await Task.sleep(for: .milliseconds(225)) }
        }
        var keys: [String] = []
        var alternates: [String: [String]] = [:]
        for group in keysByChapter.values {
            let releases = group.sorted()
            guard let key = releases.first else { continue }
            keys.append(key)
            if releases.count > 1 { alternates[key] = Array(releases.dropFirst()) }
        }
        return Snapshot(chapterKeys: keys.sorted(), latestRelease: latest, checkedAt: checkedAt,
                        alternateKeys: alternates.isEmpty ? nil : alternates)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: cacheFile, options: .atomic)
        } catch {
            // The shelf can still use the in-memory chapter index.
        }
    }
}

enum ChapterReleaseDate {
    private static let formats: [DateFormatter] = [
        "MMM-dd-yyyy", "MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    static func parse(_ value: String?, relativeTo now: Date = .now) -> Date? {
        guard let value else { return nil }
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = try? Date(label, strategy: .iso8601) { return date }
        if let date = try? Date(label, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }

        let words = label.lowercased().split(separator: " ")
        if words.count == 3, words[2] == "ago", let count = Int(words[0]), count >= 0 {
            let component: Calendar.Component?
            switch words[1] {
            case "second", "seconds": component = .second
            case "minute", "minutes": component = .minute
            case "hour", "hours": component = .hour
            case "day", "days": component = .day
            case "week", "weeks": component = .weekOfYear
            case "month", "months": component = .month
            case "year", "years": component = .year
            default: component = nil
            }
            if let component {
                return Calendar(identifier: .gregorian).date(byAdding: component, value: -count, to: now)
            }
        }
        if label.caseInsensitiveCompare("just now") == .orderedSame { return now }
        return formats.lazy.compactMap { $0.date(from: label) }.first
    }
}
