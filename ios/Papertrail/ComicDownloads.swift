import Foundation
import ImageIO
import Observation
import PDFKit

struct ComicDownload: Identifiable, Codable {
    let id: UUID
    let title: String
    let original: ComicSeries?
    let files: [String]
    let date: Date

    static let root = URL.applicationSupportDirectory.appending(path: "PapertrailComics", directoryHint: .isDirectory)

    static func available(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(component: id.uuidString).appending(path: "download.json").path)
    }

    static func pages(_ id: UUID) throws -> [URL] {
        let folder = root.appending(component: id.uuidString, directoryHint: .isDirectory)
        let download = try read(in: folder)
        guard download.id == id, !download.files.isEmpty else { throw SourceFailure.noPages }
        return download.files.map { folder.appending(component: $0) }
    }

    var cover: URL? {
        files.first.map { Self.root.appending(component: id.uuidString).appending(component: $0) }
    }

    var route: ComicReadingRoute {
        let key = URL(string: "infinit-comic://download/\(id.uuidString)")!
        let series = original ?? ComicSeries(id: id.uuidString, title: title, credit: "Downloads",
                                             source: .getComics, cover: GetComics.website, website: key)
        return ComicReadingRoute(series: series, issue: ComicIssue(title: title, number: 1, website: key,
                                                                  scanCount: files.count, downloadID: id))
    }

    static func read(in folder: URL) throws -> Self {
        let file = folder.appending(path: "download.json")
        let entry = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard entry.files.allSatisfy({ $0.wholeMatch(of: #/page-[0-9]+\.[a-z0-9]+/#) != nil }) else {
            throw SourceFailure.invalidLink
        }
        return entry
    }
}

enum ComicDownloadError: LocalizedError {
    case tooLarge, unsupported, damaged

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This comic exceeds the download or unpacked size limit."
        case .unsupported: "Choose a CBZ, CBR, ZIP, RAR, or PDF containing comic pages."
        case .damaged: "The comic file is damaged or password protected."
        }
    }
}

enum ComicFileImport {
    static let maximumBytes: Int64 = 650 * 1024 * 1024
    private static let maximumExpandedBytes = 1_024 * 1024 * 1024
    private static let pageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"]

    static func store(_ file: URL, title: String, original: ComicSeries?) throws -> ComicDownload {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ComicDownloadError.damaged }
        guard Int64(size) <= maximumBytes else { throw ComicDownloadError.tooLarge }
        let manager = FileManager.default
        let root = ComicDownload.root
        let id = UUID()
        let staging = root.appending(component: ".\(id.uuidString)", directoryHint: .isDirectory)
        let destination = root.appending(component: id.uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let input = try FileHandle(forReadingFrom: file)
        let signature = try input.read(upToCount: 8) ?? Data()
        try input.close()
        let files: [String]
        if signature.starts(with: "%PDF-".utf8) {
            files = try pdf(file, into: staging)
        } else if signature.starts(with: [0x50, 0x4B]) || signature.starts(with: [0x52, 0x61, 0x72, 0x21]) {
            files = try archive(file, into: staging)
        } else {
            throw ComicDownloadError.unsupported
        }
        try Task.checkCancellation()
        guard !files.isEmpty else { throw SourceFailure.noPages }
        let download = ComicDownload(id: id, title: title, original: original, files: files, date: .now)
        try JSONEncoder().encode(download).write(to: staging.appending(path: "download.json"), options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        return download
    }

    private static func archive(_ file: URL, into folder: URL) throws -> [String] {
        guard let reader = archive_read_new() else { throw ComicDownloadError.damaged }
        defer { archive_read_free(reader) }
        archive_read_support_format_zip(reader)
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
        guard (file.path.withCString { archive_read_open_filename(reader, $0, 64 * 1024) }) == 0 else {
            throw ComicDownloadError.damaged
        }
        var entry: OpaquePointer?
        var pages: [(path: String, local: String)] = []
        var total = 0
        var entries = 0
        while true {
            try Task.checkCancellation()
            let result = archive_read_next_header(reader, &entry)
            if result == 1 { break }
            guard result == 0, let entry else { throw ComicDownloadError.damaged }
            entries += 1
            guard entries <= 12_000, pages.count < 2_500 else { throw ComicDownloadError.tooLarge }
            guard archive_entry_filetype(entry) == 0o100000, let path = archive_entry_pathname(entry),
                  let name = String(validatingCString: path),
                  !name.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }),
                  pageExtensions.contains((name as NSString).pathExtension.lowercased()) else {
                guard archive_read_data_skip(reader) >= 0 else { throw ComicDownloadError.damaged }
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            let local = "page-\(pages.count).\(ext)"
            let destination = folder.appending(component: local)
            total += try extractPage(reader, to: destination, remaining: maximumExpandedBytes - total)
            if CGImageSourceCreateWithURL(destination as CFURL, nil) != nil {
                pages.append((name, local))
            } else {
                try FileManager.default.removeItem(at: destination)
            }
        }
        return pages.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.local < $1.local : order == .orderedAscending
        }.map(\.local)
    }

    private static func extractPage(_ reader: OpaquePointer, to destination: URL, remaining: Int) throws -> Int {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var bytes = Data(count: 64 * 1024)
        var count = 0
        let limit = min(remaining, 45 * 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let read = bytes.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
            guard read >= 0 else { throw ComicDownloadError.damaged }
            if read == 0 { return count }
            count += read
            guard count <= limit else { throw ComicDownloadError.tooLarge }
            try output.write(contentsOf: bytes.prefix(read))
        }
    }

    private static func pdf(_ file: URL, into folder: URL) throws -> [String] {
        guard let document = PDFDocument(url: file), !document.isLocked else { throw ComicDownloadError.damaged }
        guard document.pageCount <= 2_500 else { throw ComicDownloadError.tooLarge }
        var total = 0
        return try (0..<document.pageCount).map { index in
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let page = document.page(at: index),
                      let data = page.thumbnail(of: CGSize(width: 1700, height: 2400), for: .mediaBox)
                        .jpegData(compressionQuality: 0.87) else { throw ComicDownloadError.damaged }
                total += data.count
                guard total <= maximumExpandedBytes else { throw ComicDownloadError.tooLarge }
                let name = "page-\(index).jpg"
                try data.write(to: folder.appending(component: name))
                return name
            }
        }
    }
}

@MainActor
@Observable
final class ComicDownloadStore {
    private(set) var items: [ComicDownload]
    private(set) var active: String?
    private(set) var failure: String?

    init() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: ComicDownload.root, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)) ?? []
        items = folders.compactMap { folder in
            guard let entry = try? ComicDownload.read(in: folder), entry.id.uuidString == folder.lastPathComponent else {
                return nil
            }
            return entry
        }.sorted { $0.date > $1.date }
    }

    func saved(_ series: ComicSeries) -> ComicDownload? { items.first { $0.original?.id == series.id } }

    func download(_ series: ComicSeries) async {
        guard active == nil, saved(series) == nil else { return }
        active = series.id
        failure = nil
        defer { active = nil }
        do {
            let temporary = try await GetComics.download(series)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await add(file: temporary, title: series.title, original: series)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    func importFile(_ file: URL) async {
        guard active == nil else { return }
        active = file.lastPathComponent
        failure = nil
        defer { active = nil }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            try await add(file: file, title: file.deletingPathExtension().lastPathComponent, original: nil)
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    func remove(_ entry: ComicDownload) {
        do {
            let folder = ComicDownload.root.appending(component: entry.id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: folder)
            items.removeAll { $0.id == entry.id }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func add(file: URL, title: String, original: ComicSeries?) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try ComicFileImport.store(file, title: title, original: original)
        }
        let entry = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        items.insert(entry, at: 0)
    }
}
