import AVKit
import Combine
import SwiftUI

enum AnimePlaybackTime {
    static func label(_ seconds: Double) -> String {
        let total = Int(exactly: seconds.rounded(.down)) ?? 0
        let hours = total / 3_600
        let minutes = total / 60 % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, total % 60) }
        return String(format: "%d:%02d", minutes, total % 60)
    }
}

struct AnimePlayer: View {
    @Environment(AnimeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let show: AnimeShow
    let episode: AnimeEpisode
    let source: AnimeSource

    @State private var player = AVPlayer()
    @State private var attempt = 0
    @State private var loading = true
    @State private var failure: String?
    @State private var lastRecorded: Double?
    @State private var completed = false
    @State private var prepared = false

    private let checkpoint = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        AnimePlaybackChrome(title: episode.title, subtitle: source.title, doneID: "anime-player-done", close: close) { _ in
            AnimePlaybackOptions(bookmarked: library.contains(show, in: .bookmarks),
                                 watchingLater: library.contains(show, in: .later),
                                 bookmark: { library.toggle(show, in: .bookmarks) },
                                 watchLater: { library.toggle(show, in: .later) }) {}
        } playback: {
            ZStack {
                VideoPlayer(player: player)
                    .background(.black)
                    .accessibilityIdentifier("anime-video")
                    .allowsHitTesting(!loading && failure == nil)
                if let failure {
                    ContentUnavailableView {
                        Label("Couldn’t play this episode", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Retry") { attempt += 1 }.buttonStyle(.borderedProminent)
                    }
                    .background(.black)
                } else if loading {
                    VideoSkeleton()
                }
            }
        }
        .task(id: attempt) { await prepare() }
        .task(id: attempt) {
            do {
                try await Task.sleep(for: .seconds(35))
                guard loading else { return }
                fail("The source timed out. Try again or choose another link.")
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .onReceive(checkpoint) { _ in savePosition() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
            completed = true
            record(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: RunLoop.main)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
            fail("Playback stopped before the episode ended. Try again or choose another link.")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                player.pause()
                savePosition()
            }
        }
        .onDisappear {
            player.pause()
            savePosition()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func prepare() async {
        loading = true
        failure = nil
        lastRecorded = nil
        completed = false
        prepared = false
        let item = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: item)

        let statuses = AsyncStream(AVPlayerItem.Status.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                continuation.yield(item.status)
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
        for await status in statuses {
            guard !Task.isCancelled, item === player.currentItem else { return }
            switch status {
            case .readyToPlay:
                guard !prepared else { continue }
                let saved = library.position(for: episode, source: source)
                let duration = item.duration.seconds
                let start = duration.isFinite && saved >= duration ? 0 : saved
                if start > 0 {
                    let sought = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                                   toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, item === player.currentItem else { return }
                    guard sought else {
                        fail("The source couldn’t seek to the saved time. Try again or choose another link.")
                        return
                    }
                }
                prepared = true
                loading = false
                record(start)
                if scenePhase == .active { player.play() }
            case .failed:
                fail("The video source couldn’t be loaded. Try again or choose another link.")
                return
            default:
                break
            }
        }
    }

    private func fail(_ message: String) {
        savePosition()
        prepared = false
        loading = false
        failure = message
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func close() {
        player.pause()
        savePosition()
        dismiss()
    }

    private func savePosition() {
        guard prepared else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        if completed {
            let duration = player.currentItem?.duration.seconds
            guard let duration, duration.isFinite, seconds + 1 < duration else { return }
            completed = false
        }
        if let lastRecorded, abs(seconds - lastRecorded) < 0.1 { return }
        record(seconds)
    }

    private func record(_ seconds: Double) {
        library.record(episode, show: show, source: source, seconds: seconds,
                       duration: player.currentItem?.duration.seconds)
        lastRecorded = seconds
    }
}

struct AnimePlaybackChrome<Actions: View, Playback: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let title: String
    let subtitle: String
    let doneID: String
    let close: () -> Void
    @ViewBuilder let actions: (Bool) -> Actions
    @ViewBuilder let playback: () -> Playback

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !side {
                        actions(false)
                        Button("Done", action: close)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(doneID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, side ? 5 : 8)
                playback()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if side { Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing)) }
            }
            .overlay(alignment: .bottomTrailing) {
                if side {
                    VStack(spacing: 8) {
                        Button(action: close) { ShelfDockIcon(symbol: "xmark") }
                            .accessibilityLabel("Done")
                            .accessibilityIdentifier(doneID)
                        VStack(spacing: 2) { actions(true) }
                            .padding(3)
                            .background(.regularMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(Color.papertrailStroke).allowsHitTesting(false) }
                    }
                    .buttonStyle(ShelfPressStyle())
                    .padding(.trailing, geometry.safeAreaInsets.trailing >= 24 ? 23 : 10)
                    .padding(.bottom, 10)
                    .ignoresSafeArea(.container, edges: .trailing)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("anime-player-side-nav")
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

struct AnimePlaybackOptions<Navigation: View>: View {
    let bookmarked: Bool
    let watchingLater: Bool
    let bookmark: () -> Void
    let watchLater: () -> Void
    @ViewBuilder let navigation: () -> Navigation

    var body: some View {
        Menu {
            Button(bookmarked ? "Remove bookmark" : "Bookmark", systemImage: bookmarked ? "bookmark.fill" : "bookmark") {
                bookmark()
                (bookmarked ? ShelfHaptics.selection : .success).play()
            }
            .accessibilityIdentifier("anime-player-bookmark")
            Button(watchingLater ? "Remove from Watch Later" : "Watch Later", systemImage: watchingLater ? "heart.fill" : "heart") {
                watchLater()
                (watchingLater ? ShelfHaptics.selection : .success).play()
            }
            .accessibilityIdentifier("anime-player-watch-later")
            navigation()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("anime-player-more")
    }
}
