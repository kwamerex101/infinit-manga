import SwiftUI
import WebKit

enum AnimeWebsite: Identifiable, Sendable {
    case flixMovie, aniZone

    var host: String { self == .flixMovie ? "flixmovie.st" : "anizone.to" }
    var name: String { self == .flixMovie ? "FlixMovie" : "AniZone" }
    var id: String { self == .flixMovie ? "flixmovie" : "anizone" }
    var browserID: String { id + "-browser" }
    var browseURL: URL { self == .flixMovie ? FlixMovieCatalog.browseURL : AniZoneCatalog.browseURL }

    func homeTitles() async throws -> [AnimeWebsiteTitle] {
        switch self {
        case .flixMovie: try await FlixMovieCatalog.popular().map(AnimeWebsiteTitle.init)
        case .aniZone: try await AniZoneCatalog.latest()
        }
    }
    var dataID: UUID {
        UUID(uuidString: self == .flixMovie ? "75951FCA-A74D-493D-8F8A-F27447C22502" :
            "DE64BAFC-959C-41D3-87B0-88F2B76C54C8")!
    }

    func contains(_ url: URL?) -> Bool {
        guard let url, let host = url.host else { return false }
        return url.scheme == "https" && (host == self.host || (self == .flixMovie && host == "www." + self.host)) &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
}

struct AnimeWebsiteBrowserButton<Content: View>: View {
    var website = AnimeWebsite.flixMovie
    let url: URL
    @ViewBuilder let content: () -> Content
    @State private var showingWebsite = false

    var body: some View {
        Button {
            ShelfHaptics.tap.play()
            showingWebsite = true
        } label: { content() }
        .buttonStyle(ShelfPressStyle())
        .fullScreenCover(isPresented: $showingWebsite) {
            InAppWebsiteBrowser(website: website, url: url)
        }
    }
}

enum InAppWebsite {
    case anime(AnimeWebsite)
    case xoxoComics
    case comix

    static let comixURL = URL(string: "https://comix.to/")!

    var animeWebsite: AnimeWebsite? {
        if case let .anime(website) = self { return website }
        return nil
    }

    var host: String {
        switch self {
        case .anime(let website): website.host
        case .xoxoComics: "xoxocomic.com"
        case .comix: "comix.to"
        }
    }

    var name: String {
        switch self {
        case .anime(let website): website.name
        case .xoxoComics: "XOXO Comics"
        case .comix: "Comix"
        }
    }

    var browserID: String {
        switch self {
        case .anime(let website): website.browserID
        case .xoxoComics: "xoxo-browser"
        case .comix: "comix-browser"
        }
    }

    func contains(_ url: URL?) -> Bool {
        if let animeWebsite { return animeWebsite.contains(url) }
        guard let url, url.scheme == "https", let host = url.host?.lowercased(),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return host == self.host || host == "www." + self.host
    }
}

struct InAppWebsiteBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let website: InAppWebsite
    let url: URL

    @State private var session: InAppWebsiteBrowserSession
    @State private var attempt = 0

    init(website: AnimeWebsite, url: URL) {
        self.init(site: .anime(website), url: url)
    }

    init(site website: InAppWebsite, url: URL) {
        self.website = website
        self.url = url
        _session = State(initialValue: InAppWebsiteBrowserSession(site: website))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left", action: session.goBack)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .disabled(!session.canGoBack)
                    .accessibilityIdentifier(website.browserID + "-back")
                Spacer(minLength: 0)
                Text(website.host)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(website.browserID + "-domain")
                Spacer(minLength: 0)
                Button("Reload", systemImage: "arrow.clockwise") {
                    if session.webView == nil { attempt += 1 }
                    else { session.reload() }
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier(website.browserID + "-reload")
                Button("Done") {
                    session.close()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(website.browserID + "-done")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Rectangle()
                .fill(Color.papertrailStroke)
                .frame(height: 1)
                .overlay(alignment: .leading) {
                    if session.loading {
                        LoadingSkeleton(label: "Loading \(website.name)") {
                            SkeletonBlock(radius: 0).frame(width: 92, height: 2)
                        }
                    }
                }

            ZStack {
                if let webView = session.webView {
                    InAppWebsiteContent(webView: webView)
                        .id(ObjectIdentifier(webView))
                }
                if let error = session.failure {
                    ShelfStateView("Couldn’t open \(website.name)", message: error,
                                   action: .init("Retry") { attempt += 1 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.papertrailBackground)
                } else if session.webView == nil {
                    if website.animeWebsite != nil { VideoSkeleton() }
                    else { LoadingSkeleton(label: "Loading \(website.name)") { ReaderPageSkeleton() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.papertrailBackground.ignoresSafeArea())
        .task(id: attempt) { await session.open(url) }
        .onDisappear { session.close() }
    }
}

struct InAppWebsiteContent: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor
@Observable
final class InAppWebsiteBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var loading = true
    private(set) var canGoBack = false
    private(set) var failure: String?
    private(set) var playbackReady = false

    private let website: InAppWebsite
    private let focusedPlayback: Bool

    init(site: InAppWebsite, focusedPlayback: Bool = false) {
        website = site
        self.focusedPlayback = focusedPlayback
    }

    func open(_ url: URL) async {
        guard website.contains(url) else { return }
        close()
        failure = nil
        loading = true
        do {
            let rules = try await InAppWebsiteRules.load(for: website)
            try Task.checkCancellation()
            let configuration = WKWebViewConfiguration()
            if let dataID = website.animeWebsite?.dataID {
                configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataID)
            } else {
                configuration.websiteDataStore = .nonPersistent()
            }
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.allowsInlineMediaPlayback = true
            configuration.preferences.isElementFullscreenEnabled = true
            configuration.userContentController.add(rules)
            if website.animeWebsite == .aniZone {
                configuration.userContentController.addUserScript(WKUserScript(
                    source: Self.aniZonePlaybackControls, injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient
                ))
            }

            if focusedPlayback {
                configuration.mediaTypesRequiringUserActionForPlayback = []
                configuration.userContentController.addUserScript(WKUserScript(
                    source: Self.videoOnlyScript, injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient
                ))
            }

            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            view.allowsBackForwardNavigationGestures = true
            view.allowsLinkPreview = false
            if focusedPlayback {
                view.isOpaque = false
                view.backgroundColor = .black
                view.scrollView.isScrollEnabled = false
            }
            webView = view
            view.load(URLRequest(url: url, timeoutInterval: 30))
            if focusedPlayback { try await waitForPlayer(in: view) }
        } catch {
            if !Task.isCancelled { fail("The ad blocker couldn’t start. Try again.") }
        }
    }

    private func waitForPlayer(in view: WKWebView) async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(400))
            guard webView === view, failure == nil else { return }
            let ready = try? await view.evaluateJavaScript(
                "Boolean(document.querySelector('media-player[data-infinit-player] video')?.readyState)"
            ) as? Bool
            if ready == true {
                playbackReady = true
                return
            }
        }
        fail("The video didn’t load. Try again or open the episode website.")
    }

    // Keep the provider's player in its original document for captions and playback settings.
    private static let videoOnlyScript = #"""
    (() => {
        if (location.origin !== "https://anizone.to" ||
            !/^\/anime\/[a-z0-9-]+\/[a-z0-9.-]+\/?$/i.test(location.pathname)) return;

        const style = document.createElement("style");
        style.textContent = `
            html, body { margin: 0 !important; padding: 0 !important;
                background: black !important; overflow: hidden !important; }
            body > :not([data-infinit-path]):not([data-infinit-player]),
            [data-infinit-path] > :not([data-infinit-path]):not([data-infinit-player]) {
                display: none !important;
            }
            body [data-infinit-path] { display: contents !important; }
            media-player[data-infinit-player] { position: fixed !important; inset: 0 !important;
                width: 100vw !important; height: 100dvh !important; max-width: none !important;
                max-height: none !important; aspect-ratio: auto !important; background: black !important;
                border: 0 !important; border-radius: 0 !important; }
            media-player[data-infinit-player] video {
                width: 100% !important; height: 100% !important; object-fit: contain !important;
            }
        `;
        const started = new WeakSet();
        let player;
        let pending;
        function update() {
            const next = document.querySelector("media-player");
            if (!next) return;
            if (player !== next) {
                document.querySelectorAll("[data-infinit-path], [data-infinit-player]").forEach(node => {
                    node.removeAttribute("data-infinit-path");
                    node.removeAttribute("data-infinit-player");
                });
                player = next;
                player.setAttribute("data-infinit-player", "");
                for (let node = player.parentElement; node && node !== document.body; node = node.parentElement) {
                    node.setAttribute("data-infinit-path", "");
                }
                document.head.append(style);
            }
            const video = player.querySelector("video");
            if (!video || video.readyState < HTMLMediaElement.HAVE_METADATA || started.has(video)) return;
            started.add(video);
            video.play().catch(() => {});
        }
        function schedule() {
            if (pending !== undefined) return;
            pending = setTimeout(() => {
                pending = undefined;
                update();
            }, 150);
        }
        new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
        document.addEventListener("loadedmetadata", schedule, true);
        schedule();
    })();
    """#

    // AniZone can load the video without mounting Vidstack's controls.
    private static let aniZonePlaybackControls = #"""
    (() => {
        if (location.origin !== "https://anizone.to") return;

        const fallbackVideos = new WeakSet();
        let pending;
        function refresh() {
            if (!/^\/anime\/[a-z0-9-]+\/[a-z0-9.-]+\/?$/i.test(location.pathname)) return;
            const player = document.querySelector("media-player");
            const video = player?.querySelector("video");
            if (!video || video.readyState < HTMLMediaElement.HAVE_METADATA) return;

            if (player.querySelector("media-play-button")) {
                if (fallbackVideos.delete(video)) video.controls = false;
            } else if (!video.controls) {
                video.controls = true;
                fallbackVideos.add(video);
            }
        }

        function schedule() {
            if (pending !== undefined) return;
            pending = setTimeout(() => {
                pending = undefined;
                refresh();
            }, 400);
        }

        new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
        document.addEventListener("loadedmetadata", schedule, true);
        schedule();
    })();
    """#

    func close() {
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
        canGoBack = false
        loading = false
        playbackReady = false
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, !action.shouldPerformDownload else { return .cancel }
        if action.targetFrame == nil {
            if website.animeWebsite != nil || website.host == InAppWebsite.comix.host,
               action.sourceFrame.isMainFrame,
               action.navigationType == .linkActivated, website.contains(url) {
                view.load(action.request)
            }
            return .cancel
        }

        if action.targetFrame?.isMainFrame == true {
            guard website.contains(url), action.sourceFrame.isMainFrame || view.url == nil else {
                return .cancel
            }
            return .allow
        }

        guard let animeWebsite = website.animeWebsite else { return .cancel }
        switch url.scheme {
        case "https":
            return InAppWebsiteRules.isAdHost(url.host, on: animeWebsite) ? .cancel : .allow
        case "about", "blob":
            return .allow
        default:
            return .cancel
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame else { return .allow }
        return response.canShowMIMEType && website.contains(response.response.url) ? .allow : .cancel
    }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failure = nil
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = view.canGoBack
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, error: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        fail("The browser closed unexpectedly. Try again.")
    }

    private func navigationFailed(_ view: WKWebView, error: Error) {
        loading = false
        canGoBack = view.canGoBack
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if view.url == nil { fail("Check your connection and try again.") }
    }

    private func fail(_ message: String) {
        loading = false
        failure = message
    }
}

@MainActor
private enum InAppWebsiteRules {
    private static let adHosts = [
        "createlouisville.org", "tagivi.com",
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adnxs.com", "popads.net", "popcash.net", "propellerads.com", "adsterra.com"
    ]

    static func isAdHost(_ host: String?, on website: AnimeWebsite) -> Bool {
        guard let host else { return false }
        return blockedHosts(on: website).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func blockedHosts(on website: AnimeWebsite) -> [String] {
        website == .aniZone ? adHosts + ["a-ads.com"] : adHosts
    }

    static func load(for website: InAppWebsite) async throws -> WKContentRuleList {
        let version = switch website.animeWebsite {
        case .flixMovie: 2
        case .aniZone: 3
        case nil: 1
        }
        let identifier = "Infinit.\(website.name).AdRules.v\(version)"
        guard let store = WKContentRuleListStore.default() else { throw SourceFailure.unavailable }
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) { return existing }
        let blocked = website.animeWebsite.map(blockedHosts(on:)) ?? []
        var rules: [[String: [String: Any]]] = blocked.map { host in
            let pattern = NSRegularExpression.escapedPattern(for: host)
            return [
                "trigger": ["url-filter": "^https?://([^/?#]+\\.)?\(pattern)[/:?#]"],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": "ins.adsbygoogle, [data-ad-slot], [data-ad-unit]"],
        ])
        switch website.animeWebsite {
        case .flixMovie:
            rules.append([
                "trigger": ["url-filter": "^https://(www\\.)?flixmovie\\.st/"],
                "action": ["type": "css-display-none", "selector": "#tg-toast"],
            ])
        case .aniZone:
            rules.append([
                "trigger": ["url-filter": "^https://anizone\\.to/"],
                "action": ["type": "css-display-none", "selector": "[x-init='checkAd()']"],
            ])
        case nil:
            rules.append([
                "trigger": ["url-filter": "^https?://", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = String(decoding: data, as: UTF8.self)
        guard let rules = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
            throw SourceFailure.unavailable
        }
        return rules
    }
}
