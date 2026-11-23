import Foundation
import Observation

@MainActor
@Observable
final class AnimeLibrary {
    enum Shelf: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks", later = "Watch Later", recent = "Recent"
        var id: Self { self }
    }

    struct Recent: Codable, Identifiable {
        let showID: String
        let episodeID: String
        let sourceID: String
        let date: Date
        var duration: Double? = nil
        var aniWatch: AniWatchSelection? = nil
        var id: String { episodeID }
    }

    enum SavedShow: Identifiable {
        case collection(AnimeShow)
        case aniWatch(AniWatchTitle)

        var id: String {
            switch self {
            case .collection(let show): show.id
            case .aniWatch(let show): show.libraryID
            }
        }
    }

    private struct State: Codable {
        var bookmarks: [String] = []
        var later: [String] = []
        var recent: [String: Recent] = [:]
        var positions: [String: Double] = [:]
        var disabledSources: [String]? = nil
        var aniWatchTitles: [String: AniWatchTitle]? = nil
    }

    private let file: URL
    private var state = State()
    private var canSave = true
    private(set) var saveError = false

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Papertrail/anime.json")) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            } catch {
                canSave = false
                saveError = true
            }
        }
    }

    var recent: [Recent] { state.recent.values.sorted { $0.date > $1.date } }
    var enabledProviders: [AnimeProvider] { AnimeProvider.allCases.filter(isEnabled) }

    func isEnabled(_ source: AnimeProvider) -> Bool {
        !(state.disabledSources?.contains(source.rawValue) ?? false)
    }

    func setEnabled(_ enabled: Bool, source: AnimeProvider) {
        guard isEnabled(source) != enabled else { return }
        var disabled = state.disabledSources ?? []
        if enabled { disabled.removeAll { $0 == source.rawValue } }
        else { disabled.append(source.rawValue) }
        state.disabledSources = disabled
        save()
    }

    func sources(for episode: AnimeEpisode) -> [AnimeSource] {
        episode.sources.filter { isEnabled($0.provider) }
    }

    func canResume(_ recent: Recent) -> Bool {
        if recent.aniWatch != nil { return isEnabled(.aniWatch) }
        return AnimeCatalog.show(recent.showID)?.episodes.first { $0.id == recent.episodeID }
            .map { sources(for: $0).contains { $0.id == recent.sourceID } } ?? false
    }

    func shows(in shelf: Shelf) -> [SavedShow] {
        ids(in: shelf).compactMap { id in
            if let show = state.aniWatchTitles?[id] { return .aniWatch(show) }
            return AnimeCatalog.show(id).map(SavedShow.collection)
        }
    }

    func contains(_ show: AnimeShow, in shelf: Shelf) -> Bool {
        ids(in: shelf).contains(show.id)
    }

    func contains(_ show: AniWatchTitle, in shelf: Shelf) -> Bool {
        ids(in: shelf).contains(show.libraryID)
    }

    func toggle(_ show: AnimeShow, in shelf: Shelf) {
        guard shelf != .recent else { return }
        toggle(show.id, in: shelf)
        save()
    }

    func toggle(_ show: AniWatchTitle, in shelf: Shelf) {
        guard shelf != .recent else { return }
        let id = show.libraryID
        toggle(id, in: shelf)
        var titles = state.aniWatchTitles ?? [:]
        titles[id] = state.bookmarks.contains(id) || state.later.contains(id) ? show : nil
        state.aniWatchTitles = titles.isEmpty ? nil : titles
        save()
    }

    private func ids(in shelf: Shelf) -> [String] {
        switch shelf {
        case .bookmarks: state.bookmarks
        case .later: state.later
        case .recent: state.recent.values.map(\.showID)
        }
    }

    private func toggle(_ id: String, in shelf: Shelf) {
        switch shelf {
        case .bookmarks: toggle(id, in: &state.bookmarks)
        case .later: toggle(id, in: &state.later)
        case .recent: break
        }
    }

    private func toggle(_ id: String, in titles: inout [String]) {
        if let index = titles.firstIndex(of: id) {
            titles.remove(at: index)
        } else {
            titles.insert(id, at: 0)
        }
    }

    func position(for episode: AnimeEpisode, source: AnimeSource) -> Double {
        state.positions[positionKey(episode, source: source)] ?? 0
    }

    func lastWatch(of episode: AnimeEpisode) -> Recent? { state.recent[episode.id] }

    func lastEpisode(of show: AniWatchTitle) -> AniWatchEpisode? {
        recent.first { $0.showID == show.libraryID }?.aniWatch?.episode
    }

    func position(for episode: AniWatchEpisode) -> Double {
        state.positions["\(episode.historyID)/\(AnimeProvider.aniWatch.rawValue)"] ?? 0
    }

    func record(_ selection: AniWatchSelection, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0, seconds >= 0, seconds <= duration else { return }
        let episodeID = selection.episode.historyID
        let sourceID = AnimeProvider.aniWatch.rawValue
        state.positions["\(episodeID)/\(sourceID)"] = seconds
        state.recent[episodeID] = Recent(showID: selection.show.libraryID, episodeID: episodeID,
                                        sourceID: sourceID, date: .now, duration: duration, aniWatch: selection)
        save()
    }

    func record(_ episode: AnimeEpisode, show: AnimeShow, source: AnimeSource, seconds: Double? = nil,
                duration: Double? = nil) {
        if let seconds, seconds.isFinite, seconds >= 0 {
            state.positions[positionKey(episode, source: source)] = seconds
        }
        let previous = state.recent[episode.id]
        let previousDuration = previous?.sourceID == source.id ? previous?.duration : nil
        let knownDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? previousDuration
        state.recent[episode.id] = Recent(showID: show.id, episodeID: episode.id, sourceID: source.id,
                                          date: .now, duration: knownDuration)
        save()
    }

    private func positionKey(_ episode: AnimeEpisode, source: AnimeSource) -> String {
        "\(episode.id)/\(source.id)"
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
