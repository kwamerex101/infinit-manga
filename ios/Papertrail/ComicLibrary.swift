import Foundation
import Observation

@MainActor
@Observable
final class ComicLibrary {
    enum Shelf: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks", later = "Read Later", recent = "Recent", downloads = "Downloads"
        var id: Self { self }
    }

    struct Recent: Codable, Identifiable {
        let series: ComicSeries
        let issue: ComicIssue
        let page: Int
        let pageCount: Int
        let date: Date

        var id: String { issue.id }
        var route: ComicReadingRoute { ComicReadingRoute(series: series, issue: issue) }
    }

    private struct State: Codable {
        var bookmarks: [ComicSeries] = []
        var later: [ComicSeries] = []
        var readings: [String: Recent] = [:]
        var disabledSources: [String]? = nil
    }

    private let file = URL.applicationSupportDirectory.appending(path: "Papertrail/comics.json")
    private var state = State()
    private var canSave = true
    private(set) var saveError = false

    init() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } catch {
            canSave = false
            saveError = true
        }
    }

    var recent: [Recent] {
        state.readings.values.filter { reading in
            reading.issue.downloadID.map(ComicDownload.available) ?? true
        }.sorted { $0.date > $1.date }
    }
    var enabledSources: [ComicSource] { ComicSource.allCases.filter(isEnabled) }

    func isEnabled(_ source: ComicSource) -> Bool {
        !(state.disabledSources?.contains(source.rawValue) ?? false)
    }

    func setEnabled(_ enabled: Bool, source: ComicSource) {
        guard isEnabled(source) != enabled else { return }
        var disabled = state.disabledSources ?? []
        if enabled { disabled.removeAll { $0 == source.rawValue } }
        else { disabled.append(source.rawValue) }
        state.disabledSources = disabled
        save()
    }

    func titles(in shelf: Shelf) -> [ComicSeries] {
        switch shelf {
        case .bookmarks: state.bookmarks
        case .later: state.later
        case .recent, .downloads: []
        }
    }

    func contains(_ series: ComicSeries, in shelf: Shelf) -> Bool {
        titles(in: shelf).contains { $0.id == series.id }
    }

    func toggle(_ series: ComicSeries, in shelf: Shelf) {
        switch shelf {
        case .bookmarks: Self.toggle(series, in: &state.bookmarks)
        case .later: Self.toggle(series, in: &state.later)
        case .recent, .downloads: return
        }
        save()
    }

    func lastRead(_ series: ComicSeries) -> Recent? {
        recent.first { $0.series.id == series.id }
    }

    func progress(_ issue: ComicIssue) -> Recent? { state.readings[issue.id] }

    func record(_ route: ComicReadingRoute, page: Int, pageCount: Int) {
        if !saveError, let previous = progress(route.issue), previous.page == page,
           previous.pageCount == pageCount, recent.first?.id == route.issue.id { return }
        state.readings[route.issue.id] = Recent(series: route.series, issue: route.issue,
                                              page: page, pageCount: pageCount, date: .now)
        save()
    }

    private static func toggle(_ series: ComicSeries, in titles: inout [ComicSeries]) {
        if let index = titles.firstIndex(where: { $0.id == series.id }) {
            titles.remove(at: index)
        } else {
            titles.insert(series, at: 0)
        }
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
