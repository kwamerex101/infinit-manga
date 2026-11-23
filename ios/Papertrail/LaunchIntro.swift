import AVFoundation
import SwiftUI
import UIKit

struct LaunchIntro: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var player: AVPlayer?
    @State private var hasVideoFrame = false

    private static let clipURL = Bundle.main.url(forResource: "LaunchIntro", withExtension: "mov")

    private var isShowing: Bool {
        !finished && !reduceMotion && Self.clipURL != nil
    }

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!isShowing)
            .accessibilityHidden(isShowing)
            .overlay {
                if isShowing {
                    splash
                        .transition(.opacity)
                        .task(id: scenePhase) {
                            await updatePlayback()
                        }
                        .onDisappear { player = nil }
                }
            }
            .onChange(of: reduceMotion, initial: true) {
                if reduceMotion { finish(animated: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
                .merge(with: NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime))
                .receive(on: RunLoop.main)) { notification in
                    guard let item = player?.currentItem, notification.object as? AVPlayerItem === item else { return }
                    finish()
                }
    }

    private var splash: some View {
        GeometryReader { geometry in
            ZStack {
                Color.papertrailBackground
                if !hasVideoFrame {
                    Image("LaunchIntroPoster")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let player {
                    LaunchVideoSurface(player: player) {
                        hasVideoFrame = true
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @MainActor
    private func updatePlayback() async {
        guard isShowing, let url = Self.clipURL else { return }
        switch scenePhase {
        case .active:
            let playback = player ?? AVPlayer(url: url)
            playback.isMuted = true
            player = playback
            playback.play()
            // A failed or interrupted decode must never block the shelf.
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { finish() }
        case .background:
            finish(animated: false)
        default:
            player?.pause()
        }
    }

    private func finish(animated: Bool = true) {
        guard !finished else { return }
        player?.pause()
        withAnimation(animated ? .easeOut(duration: 0.18) : nil) {
            finished = true
        }
    }
}

private struct LaunchVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let onFirstFrame: () -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.playerLayer.isOpaque = false
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        guard view.playerLayer.player !== player else { return }
        view.readiness = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { onFirstFrame() }
        }
        view.playerLayer.player = player
    }

    final class PlayerView: UIView {
        var readiness: NSKeyValueObservation?

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
