import Foundation
import Observation

@MainActor
@Observable
final class ReadingStore {
    struct Progress: Codable {
        var page = 0
        var read = false
    }

    struct Recent: Codable, Identifiable {
        let manga: Manga
        let chapter: Chapter
        let date: Date
        var id: String { manga.id }
    }

    private struct State: Codable {
        var bookmarks: [Manga] = []
        var readLater: [Manga]?
        var chapterAlertCheckpoints: [String: ChapterAlertCheckpoint]?
        var progress: [String: Progress] = [:]
        var recent: [String: Recent] = [:]
        var sourceURLs: [URL]? = []
    }

    enum SourceAddition {
        case added, alreadyAdded, saveFailed
    }

    private var state = State()
    private let file: URL
    let hadLibraryFile: Bool
    private(set) var saveError = false

    init() {
        file = URL.applicationSupportDirectory.appending(path: "Papertrail/library.json")
        hadLibraryFile = FileManager.default.fileExists(atPath: file.path)
        if hadLibraryFile {
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                if state.sourceURLs == nil {
                    let legacySources: [ReadingSource] = [.roliaScan, .mangaDex, .mangaKatana]
                    state.sourceURLs = legacySources.map(\.homepage)
                }
            } catch {
                saveError = true
            }
        }
    }

    var bookmarks: [Manga] { state.bookmarks }
    var readLater: [Manga] { state.readLater ?? [] }
    var recent: [Recent] { state.recent.values.sorted { $0.date > $1.date } }

    func bookmarked(_ manga: Manga) -> Bool {
        state.bookmarks.contains { $0.id == manga.id }
    }

    func toggleBookmark(_ manga: Manga) {
        if bookmarked(manga) {
            state.bookmarks.removeAll { $0.id == manga.id }
            state.chapterAlertCheckpoints?.removeValue(forKey: manga.id)
        } else {
            state.bookmarks.insert(manga, at: 0)
        }
        save()
    }

    func chapterAlertCheckpoint(_ manga: Manga) -> ChapterAlertCheckpoint? {
        state.chapterAlertCheckpoints?[manga.id]
    }

    func setChapterAlertCheckpoint(_ checkpoint: ChapterAlertCheckpoint, for manga: Manga) {
        if state.chapterAlertCheckpoints == nil { state.chapterAlertCheckpoints = [:] }
        state.chapterAlertCheckpoints?[manga.id] = checkpoint
        save()
    }

    func resetChapterAlerts() {
        guard state.chapterAlertCheckpoints != nil else { return }
        state.chapterAlertCheckpoints = nil
        save()
    }

    func isInReadLater(_ manga: Manga) -> Bool {
        readLater.contains { $0.id == manga.id }
    }

    func toggleReadLater(_ manga: Manga) {
        var items = readLater
        if let index = items.firstIndex(where: { $0.id == manga.id }) {
            items.remove(at: index)
        } else {
            items.insert(manga, at: 0)
        }
        state.readLater = items
        save()
    }

    func isChapterRead(_ key: String) -> Bool { state.progress[key]?.read == true }

    func progress(_ chapter: Chapter) -> Progress {
        var result = state.progress[chapter.localKey] ?? Progress()
        result.read = result.read || chapter.alternateReleases?.contains { isChapterRead($0.localKey) } == true
        return result
    }

    func readingRelease(_ chapter: Chapter) -> Chapter {
        guard chapter.alternateReleases != nil else { return chapter }
        let releases = chapter.releases
        if let recent = state.recent[chapter.slug]?.chapter,
           let release = releases.first(where: { $0.localKey == recent.localKey }) {
            return chapter.opening(release)
        }
        if let release = releases.first(where: { (state.progress[$0.localKey]?.page ?? 0) > 0 }) {
            return chapter.opening(release)
        }
        return chapter
    }

    func record(_ chapter: Chapter, manga: Manga, page: Int) {
        state.progress[chapter.localKey, default: Progress()].page = page
        state.recent[manga.id] = Recent(manga: manga, chapter: chapter, date: .now)
        save()
    }

    func setRead(_ read: Bool, chapter: Chapter) {
        setRead(read, chapters: [chapter])
    }

    func setRead(_ read: Bool, chapters: [Chapter]) {
        var changed = false
        let keys = Set(chapters.flatMap { $0.releases.map(\.localKey) })
        for key in keys where isChapterRead(key) != read {
            state.progress[key, default: Progress()].read = read
            changed = true
        }
        if changed { save() }
    }

    var sourceURLs: [URL] { state.sourceURLs ?? [] }

    var catalogSources: [ReadingSource] {
        let addedSources = Set(sourceURLs.compactMap(ReadingSource.match))
        return ReadingSource.allCases.filter { addedSources.contains($0) }
    }

    var enabledSources: [ReadingSource] { catalogSources.filter { $0 != .comix } }

    var hasComix: Bool { catalogSources.contains(.comix) }

    @discardableResult
    func addSource(_ source: ReadingSource) -> SourceAddition {
        guard !sourceURLs.contains(where: { ReadingSource.match($0) == source }) else { return .alreadyAdded }
        let previous = state.sourceURLs
        state.sourceURLs = sourceURLs + [source.homepage]
        save()
        if saveError {
            state.sourceURLs = previous
            return .saveFailed
        }
        return .added
    }

    func removeSource(_ url: URL) {
        state.sourceURLs = sourceURLs.filter { $0 != url }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            saveError = false
        } catch {
            saveError = true
        }
    }
}
