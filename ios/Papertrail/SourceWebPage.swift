import Foundation
import WebKit

// Use the same public document a browser renders for sources that require WebKit.
@MainActor
final class SourceWebPage: NSObject, WKNavigationDelegate {
    struct Document {
        let url: URL
        let html: String
    }

    private static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    let webView: WKWebView
    private let hosts: [String]
    private let documentScript: String
    private var continuation: CheckedContinuation<Document, Error>?
    private var timeout: Task<Void, Never>?
    private var checkingAccess = false
    private let keepsPageOpen: Bool
    private var finishedLoading = false

    private init(hosts: [String], documentScript: String, keepsWebsiteSession: Bool,
                 rules: WKContentRuleList? = nil) {
        keepsPageOpen = rules != nil
        self.hosts = hosts
        self.documentScript = documentScript
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = keepsWebsiteSession ? .default() : Self.websiteDataStore
        if let rules { configuration.userContentController.add(rules) }
        if keepsPageOpen { configuration.preferences.javaScriptCanOpenWindowsAutomatically = false }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: configuration)
        super.init()
        if keepsPageOpen {
            webView.isUserInteractionEnabled = false
            webView.accessibilityElementsHidden = true
        }
        webView.navigationDelegate = self
    }

    static func load(_ url: URL, hosts: [String], keepsWebsiteSession: Bool = false,
                     documentScript: String = "return document.documentElement.outerHTML") async throws -> Document {
        try await SourceWebPage(hosts: hosts, documentScript: documentScript, keepsWebsiteSession: keepsWebsiteSession).load(url)
    }

    static func openComixChapter(_ url: URL, documentScript: String) async throws -> (SourceWebPage, Document) {
        let rules = try await InAppWebsiteRules.load(for: .comix)
        let page = SourceWebPage(hosts: ReadingSource.comix.hosts, documentScript: documentScript,
                                 keepsWebsiteSession: false, rules: rules)
        return (page, try await page.load(url))
    }

    func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        guard let value = try await webView.callAsyncJavaScript(
            script, arguments: arguments, in: nil, contentWorld: .defaultClient
        ) as? String else { throw SourceFailure.unavailable }
        return value
    }

    static func brainRotImage(_ url: URL) async throws -> Data {
        let provider = ReadingSource.brainRotComics
        guard ReadingSource.match(url) == provider, url.path.hasPrefix("/wp-content/uploads/") else {
            throw SourceFailure.invalidLink
        }
        let document = try await load(url, hosts: provider.hosts, keepsWebsiteSession: true, documentScript: """
        const response = await fetch(location.href, { mode: 'same-origin' });
        if (!response.ok || !response.headers.get('Content-Type')?.toLowerCase().startsWith('image/')) return '';
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.length > 12 * 1024 * 1024) return '';
        let binary = '';
        for (let offset = 0; offset < bytes.length; offset += 8192) {
            binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
        }
        return btoa(binary);
        """)
        guard document.url.path.hasPrefix("/wp-content/uploads/"),
              let bytes = Data(base64Encoded: document.html), !bytes.isEmpty else { throw SourceFailure.noPages }
        return bytes
    }

    private func load(_ url: URL) async throws -> Document {
        guard allows(url) else { throw SourceFailure.invalidLink }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(18))
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    let error: Error = checkingAccess ? SourceFailure.restricted : URLError(.timedOut)
                    finish(.failure(error))
                }
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return hosts.contains(host)
    }

    private func finish(_ result: Result<Document, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        if keepsPageOpen, case .success = result {
            finishedLoading = true
        } else {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.targetFrame else { return .cancel }
        if keepsPageOpen && (!target.isMainFrame || finishedLoading) { return .cancel }
        if !target.isMainFrame || allows(action.request.url) { return .allow }
        finish(.failure(SourceFailure.restricted))
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame else { return .allow }
        guard let http = response.response as? HTTPURLResponse, allows(http.url) else {
            finish(.failure(SourceFailure.unavailable))
            return .cancel
        }
        checkingAccess = http.statusCode == 403 && http.value(forHTTPHeaderField: "cf-mitigated") == "challenge"
        if checkingAccess { return .allow }
        switch http.statusCode {
        case 200..<300: return .allow
        case 401, 403: finish(.failure(SourceFailure.restricted))
        case 429: finish(.failure(SourceFailure.rateLimited))
        default: finish(.failure(SourceFailure.unavailable))
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !checkingAccess else { return }
        guard let url = webView.url, allows(url) else {
            finish(.failure(SourceFailure.unavailable))
            return
        }
        Task {
            do {
                let html = try await evaluate(documentScript)
                guard webView.url == url else { throw SourceFailure.unavailable }
                finish(.success(Document(url: url, html: html)))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(SourceFailure.unavailable))
    }
}
