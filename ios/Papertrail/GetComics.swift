import Foundation
import SwiftSoup

enum GetComics {
    static let website = URL(string: "https://getcomics.org/")!
    private static let hosts = ["getcomics.org", "www.getcomics.org"]

    static func browse(_ query: String = "") async throws -> [ComicSeries] {
        let url = query.isEmpty ? website : withQuery(website, ["s": String(query.prefix(120))])
        let document = try await markup(url)
        var seen = Set<URL>()
        return try document.select("article.post .post-title a[href]").array().compactMap { link in
            let title = try link.text()
            guard !title.isEmpty, let url = SourceHTTP.url(try link.attr("href"), relativeTo: website),
                  isIssue(url), seen.insert(url).inserted,
                  let image = link.parents().first(where: { $0.tagName() == "article" }),
                  let coverNode = try image.select(".post-header-image img").first(),
                  let cover = try imageURL(coverNode, relativeTo: website) else { return nil }
            return ComicSeries(id: "getcomics:" + url.path, title: title, credit: "Download only",
                               source: .getComics, cover: cover, website: url)
        }
    }

    static func download(_ series: ComicSeries) async throws -> URL {
        guard isIssue(series.website) else { throw SourceFailure.invalidLink }
        let document = try await markup(series.website)
        var seen = Set<URL>()
        let downloads = try document.select("a[href*=/dls/], a[href*=/dlds/]").array().compactMap { node -> URL? in
            guard let url = SourceHTTP.url(try node.attr("href"), relativeTo: website), isDownloadURL(url),
                  hosts.contains(url.host ?? ""), seen.insert(url).inserted else { return nil }
            return url
        }
        guard !downloads.isEmpty else { throw DownloadFailure.noDirectFile }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for download in downloads {
            try Task.checkCancellation()
            var request = URLRequest(url: download)
            request.setValue(series.website.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("Papertrail/0.2 (iOS comics reader)", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request, delegate: DownloadLimits())
            defer { try? FileManager.default.removeItem(at: file) }
            guard let result = response as? HTTPURLResponse, let final = result.url, isDownloadURL(final) else { continue }
            switch result.statusCode {
            case 429: throw SourceFailure.rateLimited
            case 401, 403: throw SourceFailure.restricted
            case 200..<300 where !(result.mimeType ?? "").hasPrefix("text/"):
                let target = URL.temporaryDirectory.appending(component: UUID().uuidString)
                try FileManager.default.moveItem(at: file, to: target)
                return target
            default: continue
            }
        }
        throw DownloadFailure.noDirectFile
    }

    private enum DownloadFailure: LocalizedError {
        case noDirectFile

        var errorDescription: String? {
            "GetComics didn’t provide a direct comic file. Check the GetComics download page for other options."
        }
    }

    private static func markup(_ url: URL) async throws -> Document {
        try SwiftSoup.parse(String(decoding: await SourceHTTP.data(url, allowedHosts: hosts), as: UTF8.self))
    }

    private static func isIssue(_ url: URL) -> Bool {
        guard isSecure(url), hosts.contains(url.host ?? "") else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, !["cat", "tag", "page", "news", "author", "dls", "dlds"].contains(parts[0]) else {
            return false
        }
        return true
    }

    private static func isDownloadURL(_ url: URL) -> Bool {
        guard isSecure(url), let host = url.host else { return false }
        if hosts.contains(host) { return url.path.hasPrefix("/dls/") || url.path.hasPrefix("/dlds/") }
        return host == "comicfiles.ru" || host.hasSuffix(".comicfiles.ru")
    }

    private static func isSecure(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    private final class DownloadLimits: NSObject, URLSessionDownloadDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(GetComics.isDownloadURL) == true ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let limit = ComicFileImport.maximumBytes
            if max(totalBytesWritten, totalBytesExpectedToWrite) > limit { downloadTask.cancel() }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
