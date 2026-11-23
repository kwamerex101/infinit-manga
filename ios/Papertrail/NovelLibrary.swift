import Foundation
import Observation

@MainActor
@Observable
final class NovelLibrary {
    enum Shelf: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks", later = "Read Later", recent = "Recent"
        var id: Self { self }
    }

    struct Progress: Codable {
        var paragraph = 0
        var character: Int?
        var read = false
    }

    struct Recent: Codable, Identifiable {
        let novel: Novel
        let chapter: NovelChapter
        let date: Date
        var id: Novel.ID { novel.id }
    }

    private struct State: Codable {
        var bookmarks: [Novel] = []
        var later: [Novel] = []
        var progress: [String: Progress] = [:]
        var recent: [String: Recent] = [:]
        var sources: [NovelSource] = NovelSource.allCases
        var addedBookSources: Bool? = true
    }

    private let file: URL
    private var state = State()
    private var canSave = true
    private(set) var saveError = false

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Papertrail/novels.json")) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                if state.addedBookSources == nil {
                    let newSources: [NovelSource] = [.novelFull, .standardEbooks]
                    state.sources.append(contentsOf: newSources.filter { !state.sources.contains($0) })
                    state.addedBookSources = true
                }
            } catch {
                canSave = false
                saveError = true
            }
        }
    }

    var recent: [Recent] { state.recent.values.sorted { $0.date > $1.date } }
    var enabledSources: [NovelSource] { NovelSource.allCases.filter(state.sources.contains) }

    func titles(in shelf: Shelf) -> [Novel] {
        switch shelf {
        case .bookmarks: state.bookmarks
        case .later: state.later
        case .recent: recent.map(\.novel)
        }
    }

    func contains(_ novel: Novel, in shelf: Shelf) -> Bool {
        titles(in: shelf).contains { $0.id == novel.id }
    }

    func toggle(_ novel: Novel, in shelf: Shelf) {
        switch shelf {
        case .bookmarks: toggle(novel, in: &state.bookmarks)
        case .later: toggle(novel, in: &state.later)
        case .recent: return
        }
        save()
    }

    private func toggle(_ novel: Novel, in titles: inout [Novel]) {
        if let index = titles.firstIndex(where: { $0.id == novel.id }) {
            titles.remove(at: index)
        } else {
            titles.insert(novel, at: 0)
        }
    }

    func setEnabled(_ enabled: Bool, source: NovelSource) {
        state.sources.removeAll { $0 == source }
        if enabled { state.sources.append(source) }
        save()
    }

    func lastRead(_ novel: Novel) -> Recent? { state.recent[novel.id] }

    func progress(_ chapter: NovelChapter) -> Progress {
        state.progress[chapter.id] ?? Progress()
    }

    func record(_ chapter: NovelChapter, of novel: Novel, paragraph: Int, character: Int? = nil) {
        let previous = state.recent[novel.id]
        let saved = progress(chapter)
        if previous?.chapter.id == chapter.id, saved.paragraph == paragraph, saved.character == character { return }
        state.progress[chapter.id] = Progress(paragraph: paragraph, character: character, read: saved.read)
        state.recent[novel.id] = Recent(novel: novel, chapter: chapter, date: .now)
        save()
    }

    func setRead(_ read: Bool, chapter: NovelChapter) {
        setRead(read, chapters: [chapter])
    }

    func setRead(_ read: Bool, chapters: [NovelChapter]) {
        let changed = chapters.filter { !$0.locked && progress($0).read != read }
        guard !changed.isEmpty else { return }
        for chapter in changed { state.progress[chapter.id, default: Progress()].read = read }
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            saveError = false
        } catch {
            saveError = true
        }
    }
}
