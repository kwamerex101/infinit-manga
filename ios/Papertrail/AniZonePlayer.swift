import SwiftUI

struct AniZonePlayer: View {
    @Environment(\.dismiss) private var dismiss
    let title: AnimeWebsiteTitle
    let series: URL

    @State private var episode: AniZoneEpisode?
    @State private var episodes: [AniZoneEpisode] = []
    @State private var session = InAppWebsiteBrowserSession(site: .anime(.aniZone), focusedPlayback: true)
    @State private var catalogFailed = false
    @State private var showsEpisodes = false
    @State private var showsWebsite = false
    @State private var attempt = 0

    init(title: AnimeWebsiteTitle, series: URL, episode: AniZoneEpisode?) {
        self.title = title
        self.series = series
        _episode = State(initialValue: episode)
    }

    private struct Load: Hashable {
        let url: URL?
        let attempt: Int
    }

    private var episodeURL: URL? { episode.map { series.appending(component: $0.id) } }
    private var current: AniZoneEpisode? {
        episodes.first { $0.id == episode?.id } ?? episode
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.title).font(.headline).lineLimit(1)
                    if let current {
                        Text(current.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("anizone-player-title")
                Spacer(minLength: 0)
                Button("Episodes", systemImage: "list.bullet") { showsEpisodes = true }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .disabled(episodes.isEmpty)
                    .accessibilityIdentifier("anizone-player-episodes")
                Button("Done") {
                    session.close()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("anizone-player-done")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            ZStack {
                if let webView = session.webView {
                    InAppWebsiteContent(webView: webView).id(ObjectIdentifier(webView))
                }
                if let message = session.failure ?? (episode == nil && catalogFailed ? "Try reopening the show." : nil) {
                    VStack(spacing: 12) {
                        ShelfStateView("Couldn’t play this episode", message: message,
                                       action: .init("Retry") { attempt += 1 })
                        Button("Open AniZone website") { showsWebsite = true }
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                } else if !session.playbackReady {
                    VideoSkeleton().allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: attempt) {
            catalogFailed = false
            do {
                let result = try await AniZoneCatalog.episodes(series)
                try Task.checkCancellation()
                episodes = result
                if episode == nil {
                    episode = result.first
                    catalogFailed = result.isEmpty
                }
            } catch {
                if !Task.isCancelled { catalogFailed = true }
            }
        }
        .task(id: Load(url: episodeURL, attempt: attempt)) {
            if let episodeURL { await session.open(episodeURL) }
        }
        .onDisappear { session.close() }
        .sheet(isPresented: $showsEpisodes) {
            AniZoneEpisodePicker(episodes: episodes, current: episode?.id) { selection in
                episode = selection
                showsEpisodes = false
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsWebsite) {
            InAppWebsiteBrowser(website: .aniZone, url: episodeURL ?? series)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct AniZoneEpisodePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let episodes: [AniZoneEpisode]
    let current: String?
    let select: (AniZoneEpisode) -> Void

    var body: some View {
        NavigationStack {
            let term = ShelfListQuery(query)
            let matches = episodes.filter { term.matches(number: $0.id, title: $0.title, label: $0.label) }
            List {
                ForEach(matches) { episode in
                    Button {
                        ShelfHaptics.selection.play()
                        select(episode)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(episode.label)
                                if !episode.title.isEmpty {
                                    Text(episode.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if episode.id == current { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .accessibilityAddTraits(episode.id == current ? .isSelected : [])
                    .accessibilityIdentifier("anizone-episode-\(episode.id)")
                }
                if matches.isEmpty {
                    ShelfStateView("No matching episodes", message: "Try a different number or title.", style: .compact)
                }
            }
            .safeAreaInset(edge: .top) {
                ShelfListSearch(prompt: "Episode number or title", identifier: "anizone-episode-search", query: $query)
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
