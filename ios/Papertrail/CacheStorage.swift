import Foundation

enum CacheStorage {
    struct Locations {
        let covers: URL
        let savedChapters: URL
    }

    private static let legacyCovers = URL.cachesDirectory.appending(path: "CoverArt", directoryHint: .isDirectory)
    private static let legacySavedChapters = URL.cachesDirectory.appending(path: "Papertrail/saved-chapters.json")

    static let locations: Locations = {
        let files = FileManager.default
        var directory = URL.applicationSupportDirectory.appending(path: "PapertrailCache", directoryHint: .isDirectory)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            return Locations(covers: legacyCovers, savedChapters: legacySavedChapters)
        }

        return Locations(
            covers: migrate(legacyCovers, to: directory.appending(path: "CoverArt", directoryHint: .isDirectory)),
            savedChapters: migrate(legacySavedChapters, to: directory.appending(path: "saved-chapters.json"))
        )
    }()

    static func clearLegacyCovers() {
        if locations.covers != legacyCovers { try? FileManager.default.removeItem(at: legacyCovers) }
    }

    static func clearSavedChapters() {
        try? FileManager.default.removeItem(at: locations.savedChapters)
        if locations.savedChapters != legacySavedChapters {
            try? FileManager.default.removeItem(at: legacySavedChapters)
        }
    }

    private static func migrate(_ old: URL, to current: URL) -> URL {
        let files = FileManager.default
        guard !files.fileExists(atPath: current.path), files.fileExists(atPath: old.path) else { return current }
        do {
            // Move the whole URLCache directory together with its database and blob files.
            try files.moveItem(at: old, to: current)
            return current
        } catch {
            // Continue using the existing cache and retry migration on a later launch.
            return files.fileExists(atPath: current.path) ? current : old
        }
    }
}
