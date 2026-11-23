import SwiftUI

enum MediaMode: String {
    case manga, novel, comics, anime

    var name: String {
        switch self {
        case .manga: "Manga"
        case .novel: "Novel"
        case .comics: "Comics"
        case .anime: "Anime"
        }
    }

    var title: String {
        switch self {
        case .manga: "infinit manga"
        case .novel: "Infinit Novel"
        case .comics: "Infinit Comics"
        case .anime: "Infinit Anime"
        }
    }

    var icon: String {
        switch self {
        case .manga: "books.vertical"
        case .novel: "book"
        case .comics: "rectangle.split.2x2"
        case .anime: "play.rectangle"
        }
    }

    var mascotPose: ShelfMascotPose {
        switch self {
        case .manga: .wave
        case .novel: .point
        case .comics: .salute
        case .anime: .flourish
        }
    }
}

struct MediaModeMenu: View {
    @Binding var mode: MediaMode

    var body: some View {
        Menu {
            Picker("Media mode", selection: $mode.withSelectionFeedback()) {
                Label(MediaMode.manga.name, systemImage: MediaMode.manga.icon).tag(MediaMode.manga)
                Label(MediaMode.comics.name, systemImage: MediaMode.comics.icon).tag(MediaMode.comics)
                Label(MediaMode.novel.name, systemImage: MediaMode.novel.icon).tag(MediaMode.novel)
                Label(MediaMode.anime.name, systemImage: MediaMode.anime.icon).tag(MediaMode.anime)
            }
        } label: {
            HStack(spacing: 10) {
                ShelfMascotAvatar(pose: mode.mascotPose, size: 38)
                Text(mode.title)
                    .font(.largeTitle.bold())
                    .tracking(-0.65)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("Media mode")
        .accessibilityValue(mode.name)
        .accessibilityHint("Choose a media mode")
        .accessibilityIdentifier("media-mode-menu")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
