import SwiftUI
import WebKit

struct AniWatchLaunchButton<Content: View>: View {
    let show: AniWatchTitle
    var episode: AniWatchEpisode? = nil
    @ViewBuilder let content: () -> Content

    @State private var playing = false

    var body: some View {
        Button {
            ShelfHaptics.tap.play()
            playing = true
        } label: { content() }
        .buttonStyle(ShelfPressStyle())
        .fullScreenCover(isPresented: $playing) {
            AniWatchPlayer(show: show, episode: episode)
        }
    }
}

private struct AniWatchPlayer: View {
    @Environment(AnimeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("aniwatch-audio-track") private var preferredTrack = "sub"
    let show: AniWatchTitle
    let episode: AniWatchEpisode?

    @State private var episodes: [AniWatchEpisode] = []
    @State private var selected: AniWatchEpisode?
    @State private var servers: [AniWatchServer] = []
    @State private var server: AniWatchServer?
    @State private var showingEpisodes = false
    @State private var discoveryFailure: SourceLoadFailure?
    @State private var serverFailure: SourceLoadFailure?
    @State private var catalogAttempt = 0
    @State private var playbackAttempt = 0

    private struct Request: Hashable {
        let episode: String?
        let attempt: Int
    }

    var body: some View {
        AnimePlaybackChrome(title: show.title, subtitle: selected?.label ?? episode?.label ?? "AniWatch",
                            doneID: "aniwatch-done", close: close) { side in
            controls(side: side)
        } playback: {
            if let selected, let server {
                AniWatchEmbeddedPlayer(show: show, episode: selected, server: server)
                    .id(Request(episode: selected.id + server.id.absoluteString, attempt: playbackAttempt))
            } else if let failure = discoveryFailure ?? serverFailure {
                ShelfStateView(failure: failure, title: "Couldn’t open the episode",
                               message: "Try again to load AniWatch.", action: .init("Retry", perform: retry))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VideoSkeleton()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingEpisodes) {
            AniWatchEpisodePicker(episodes: episodes, current: selected?.id) { item in
                showingEpisodes = false
                select(item)
            }
            .presentationDragIndicator(.visible)
        }
        .task(id: catalogAttempt) { await loadEpisodes() }
        .task(id: Request(episode: selected?.id, attempt: playbackAttempt)) {
            if let selected { await loadServers(for: selected) }
        }
    }

    @ViewBuilder
    private func controls(side: Bool) -> some View {
        if let server, servers.count > 1 {
            Menu {
                ForEach(servers) { item in
                    Button(item.trackLabel + " · " + item.name,
                           systemImage: item.id == server.id ? "checkmark" : "waveform") {
                        preferredTrack = item.track
                        self.server = item
                        ShelfHaptics.selection.play()
                    }
                    .accessibilityIdentifier("aniwatch-track-\(item.track)")
                }
            } label: {
                Text(server.trackLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: side ? 44 : nil, height: 44)
                    .padding(.horizontal, side ? 0 : 5)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Audio and subtitles")
            .accessibilityValue(server.trackLabel)
            .accessibilityIdentifier("aniwatch-tracks")
        }

        Button {
            ShelfHaptics.tap.play()
            showingEpisodes = true
        } label: {
            Image(systemName: "list.bullet")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(episodes.isEmpty)
        .accessibilityLabel("Episodes")
        .accessibilityIdentifier("aniwatch-episodes")

        AnimePlaybackOptions(bookmarked: library.contains(show, in: .bookmarks),
                             watchingLater: library.contains(show, in: .later),
                             bookmark: { library.toggle(show, in: .bookmarks) },
                             watchLater: { library.toggle(show, in: .later) }) {
            Divider()
            episodeStep("Previous episode", symbol: "backward.end", offset: -1)
            episodeStep("Next episode", symbol: "forward.end", offset: 1)
        }
    }

    private func episodeStep(_ title: String, symbol: String, offset: Int) -> some View {
        let target = selected.flatMap { current in
            episodes.firstIndex { $0.id == current.id }
        }.map { $0 + offset }
        let item = target.flatMap { episodes.indices.contains($0) ? episodes[$0] : nil }
        return Button(title, systemImage: symbol) {
            if let item {
                ShelfHaptics.selection.play()
                select(item)
            }
        }
        .disabled(item == nil)
        .accessibilityIdentifier(offset < 0 ? "aniwatch-previous-episode" : "aniwatch-next-episode")
    }

    private func close() {
        ShelfHaptics.tap.play()
        dismiss()
    }

    private func retry() {
        if selected == nil { catalogAttempt += 1 }
        else { playbackAttempt += 1 }
    }

    private func select(_ item: AniWatchEpisode) {
        guard selected?.id != item.id else { return }
        server = nil
        servers = []
        serverFailure = nil
        selected = item
    }

    private func loadEpisodes() async {
        discoveryFailure = nil
        do {
            let list = try await AniWatchCatalog.episodes(of: show)
            try Task.checkCancellation()
            let requested = show.watchURL(episode: episode).flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value
            }
            guard let initial = list.first(where: { $0.id == requested }) ?? list.first else {
                throw SourceFailure.unavailable
            }
            episodes = list
            select(initial)
        } catch {
            if !Task.isCancelled { discoveryFailure = SourceLoadFailure(error) }
        }
    }

    private func loadServers(for episode: AniWatchEpisode) async {
        serverFailure = nil
        do {
            let list = try await AniWatchCatalog.servers(for: episode)
            try Task.checkCancellation()
            guard selected?.id == episode.id else { return }
            servers = list
            server = list.first { $0.track == preferredTrack } ?? list.first
        } catch {
            if !Task.isCancelled, selected?.id == episode.id { serverFailure = SourceLoadFailure(error) }
        }
    }
}

private struct AniWatchEpisodePicker: View {
    @Environment(\.dismiss) private var dismiss
    let episodes: [AniWatchEpisode]
    let current: String?
    let select: (AniWatchEpisode) -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            let term = ShelfListQuery(query)
            let matches = episodes.filter { term.matches(number: $0.number, title: $0.title, label: $0.label) }
            List {
                ForEach(matches) { episode in
                    Button {
                        ShelfHaptics.selection.play()
                        select(episode)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(episode.label)
                                if !episode.title.isEmpty, episode.title != episode.label {
                                    Text(episode.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if episode.id == current { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .accessibilityAddTraits(episode.id == current ? .isSelected : [])
                    .accessibilityIdentifier("aniwatch-episode-\(episode.id)")
                }
                if matches.isEmpty {
                    ShelfStateView("No matching episodes", message: "Try a different number or title.", style: .compact)
                }
            }
            .safeAreaInset(edge: .top) {
                ShelfListSearch(prompt: "Episode number or title", identifier: "aniwatch-episode-search", query: $query)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.papertrailBackground)
            }
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct AniWatchEmbeddedPlayer: View {
    @Environment(AnimeLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let show: AniWatchTitle
    let episode: AniWatchEpisode
    let server: AniWatchServer

    @State private var attempt = 0
    @State private var session = AniWatchEmbedSession()

    var body: some View {
        VStack(spacing: 0) {
            if let warning = session.restoreWarning {
                Text("Couldn’t resume automatically. Seek to \(AnimePlaybackTime.label(warning)) in the player.")
                    .font(.footnote).foregroundStyle(.secondary).padding(8)
            }
            ZStack {
                AniWatchWebView(selection: .init(show: show, episode: episode), server: server, session: session,
                                library: library)
                    .id(attempt)
                if let failure = session.failure {
                    ShelfStateView("Couldn’t play this episode", message: failure,
                                   action: .init("Retry") { attempt += 1 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else if session.loading {
                    VideoSkeleton()
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { session.flush() }
        }
        .onDisappear { session.flush() }
    }
}

private struct AniWatchWebView: UIViewRepresentable {
    let selection: AniWatchSelection
    let server: AniWatchServer
    let session: AniWatchEmbedSession
    let library: AnimeLibrary

    func makeCoordinator() -> AniWatchEmbedSession { session }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 16.4, *) { configuration.preferences.isElementFullscreenEnabled = true }
        let bridge = configuration.userContentController
        bridge.add(session, contentWorld: AniWatchEmbedSession.world, name: "aniWatch")
        bridge.addUserScript(WKUserScript(source: AniWatchEmbedSession.bridge, injectionTime: .atDocumentStart,
                                          forMainFrameOnly: true, in: AniWatchEmbedSession.world))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.underPageBackgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = session
        session.load(view, selection: selection, server: server, library: library)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: AniWatchEmbedSession) {
        coordinator.detach(view)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "aniWatch", contentWorld: AniWatchEmbedSession.world)
        view.navigationDelegate = nil
        view.stopLoading()
    }
}

@MainActor
@Observable
private final class AniWatchEmbedSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "InfinitAniWatchEmbed")
    private(set) var loading = true
    private(set) var failure: String?
    private(set) var restoreWarning: Double?

    @ObservationIgnored private weak var view: WKWebView?
    @ObservationIgnored private weak var library: AnimeLibrary?
    @ObservationIgnored private var selection: AniWatchSelection?
    @ObservationIgnored private var originHost: String?
    @ObservationIgnored private var latest: Sample?
    @ObservationIgnored private var checkpoint: Sample?

    private struct Sample: Equatable {
        let seconds: Double
        let duration: Double
    }

    func load(_ view: WKWebView, selection: AniWatchSelection, server: AniWatchServer, library: AnimeLibrary) {
        self.view = view
        self.library = library
        self.selection = selection
        latest = nil
        checkpoint = nil
        loading = true
        failure = nil
        restoreWarning = nil
        let start = Int(exactly: library.position(for: selection.episode).rounded(.down)) ?? 0
        guard let url = server.playbackURL(start: start), let host = url.host, AniWatchServer.hosts.contains(host) else {
            fail("AniWatch did not provide a supported player.")
            return
        }
        originHost = host
        // The provider gets an isolated iframe on an app-owned page.
        let address = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        view.loadHTMLString("""
        <!doctype html>
        <html lang="en"><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src https://\(host)">
        <title>Episode player</title>
        <style>
        html,body { margin:0; width:100%; height:100%; background:#000; overflow:hidden; }
        iframe { display:block; border:0; width:100%; height:100%; }
        </style>
        </head><body>
        <iframe id="video" title="Episode video" data-start="\(max(0, start))"
                src="\(address)" allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """, baseURL: nil)
    }

    func detach(_ view: WKWebView) {
        guard self.view === view else { return }
        flush()
        self.view = nil
    }

    func flush() {
        guard let latest, latest != checkpoint, let library, let selection else { return }
        library.record(selection, seconds: latest.seconds, duration: latest.duration)
        checkpoint = latest
    }

    private func fail(_ reason: String) {
        flush()
        loading = false
        failure = reason
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let frame = action.targetFrame, let url = action.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        guard !frame.isMainFrame, url.scheme == "https", url.host == originHost,
              url.port == nil, url.user == nil, url.password == nil else { return .cancel }
        return .allow
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if self.view === view, let http = response.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail("The video server returned an error. Try again or choose another track.")
            return .cancel
        }
        return .allow
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        if self.view === view { loading = false }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, error: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, error: error)
    }

    private func navigationFailed(_ view: WKWebView, error: Error) {
        if self.view === view, (error as NSError).code != NSURLErrorCancelled {
            fail("Check your connection and try again.")
        }
    }

    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        if self.view === view { fail("The player closed unexpectedly. Retry to reopen the episode.") }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view, message.webView === view,
              let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "error": fail("The video server couldn’t play this episode. Try again or choose another track.")
        case "restoreFailed":
            if let selection { restoreWarning = library?.position(for: selection.episode) }
        case "sample":
            guard let seconds = payload["seconds"] as? Double, let duration = payload["duration"] as? Double,
                  seconds.isFinite, duration.isFinite, duration > 0, seconds >= 0, seconds <= duration else { return }
            restoreWarning = nil
            latest = .init(seconds: seconds, duration: duration)
            if checkpoint == nil || abs((checkpoint?.seconds ?? 0) - seconds) >= 2 ||
                payload["finished"] as? Bool == true {
                flush()
            }
        default: break
        }
    }
}

private extension AniWatchEmbedSession {
    static let bridge = #"""
    (() => {
        const frame = () => document.querySelector('#video');
        const send = body => window.webkit.messageHandlers.aniWatch.postMessage(body);
        const origin = iframe => new URL(iframe.src).origin;
        const command = (iframe, type, extra) => {
            iframe.contentWindow?.postMessage({ channel: 'zokoanime', type, ...extra }, origin(iframe));
        };
        let seekingSince = 0;
        let restored = false;
        let warned = false;
        let duration = 0;
        let ended = false;

        document.addEventListener('fullscreenchange', () => {
            const iframe = frame();
            if (iframe) command(iframe, 'fullscreen', { active: document.fullscreenElement === iframe });
        });

        window.addEventListener('message', event => {
            const iframe = frame();
            if (!iframe || event.source !== iframe.contentWindow || event.origin !== origin(iframe)) return;
            let data = event.data;
            if (typeof data === 'string') {
                try { data = JSON.parse(data); } catch { return; }
            }
            if (!data || typeof data !== 'object') return;
            const kind = data.type || data.event;
            if (data.channel === 'zokoanime' && kind === 'fullscreen' && data.request) {
                if (document.fullscreenElement) document.exitFullscreen?.()?.catch(() => {});
                else iframe.requestFullscreen?.()?.catch(() => {});
                return;
            }

            if (kind === 'error') {
                send({ type: 'error' });
                return;
            }
            if (kind === 'ended' || kind === 'complete') {
                if (duration > 0 && !ended && restored) {
                    ended = true;
                    send({ type: 'sample', seconds: 0, duration, finished: true });
                }
                return;
            }

            let seconds, length;
            if (kind === 'progress' && data.payload) {
                ({ currentTime: seconds, duration: length } = data.payload);
            } else if (kind === 'watching-log' || kind === 'time') {
                seconds = data.currentTime ?? data.time;
                length = data.duration;
            } else {
                return;
            }
            seconds = Number(seconds);
            length = Number(length);
            if (!Number.isFinite(seconds) || !Number.isFinite(length) || seconds < 0 || length <= 0) return;
            duration = length;

            if (!restored) {
                const target = Number(iframe.dataset.start) || 0;
                if (target >= 1 && target < duration - 1 && Math.abs(seconds - target) > 3) {
                    if (!seekingSince) {
                        seekingSince = Date.now();
                        if (event.origin === 'https://zokoanime.video') command(iframe, 'seek', { time: target });
                    } else if (!warned && Date.now() - seekingSince > 8000) {
                        warned = true;
                        send({ type: 'restoreFailed' });
                    }
                    return;
                }
                restored = true;
            }
            if (ended && seconds > 3) return;
            ended = false;
            if (seconds >= 0.5) send({ type: 'sample', seconds: Math.min(seconds, duration), duration });
        });
    })();
    """#
}
