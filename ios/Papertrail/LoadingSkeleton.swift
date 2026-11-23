import SwiftUI

struct SkeletonBlock: View {
    var radius: CGFloat = 5

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color.primary.opacity(0.14))
    }
}

struct LoadingSkeleton<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .opacity(pulsing && !reduceMotion ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .allowsHitTesting(false)
    }
}

struct MangaGridSkeleton: View {
    let label: String

    var body: some View {
        LoadingSkeleton(label: label) {
            LazyVGrid(columns: mangaGridColumns, alignment: .leading, spacing: 17) {
                ForEach(0..<6, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(radius: 8).aspectRatio(0.72, contentMode: .fit)
                        SkeletonBlock().frame(height: 10)
                            .padding(.trailing, index.isMultiple(of: 2) ? 10 : 22)
                        SkeletonBlock().frame(width: 56, height: 8)
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

struct ChapterRowSkeleton: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock().frame(width: 105, height: 13)
                SkeletonBlock().frame(width: 63, height: 9)
            }
            Spacer()
            SkeletonBlock().frame(width: 9, height: 13)
        }
        .padding(.vertical, 7)
    }
}

struct SkeletonLine: View {
    let label: String
    var width: CGFloat = 110

    var body: some View {
        LoadingSkeleton(label: label) {
            SkeletonBlock().frame(width: width, height: 9)
        }
    }
}

struct NovelTextSkeleton: View {
    let label: String

    var body: some View {
        LoadingSkeleton(label: label) {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            SkeletonBlock().frame(height: 12)
                            SkeletonBlock().frame(height: 12)
                            SkeletonBlock().frame(width: min(geometry.size.width * 0.58, 330), height: 12)
                        }
                    }
                }
                .frame(maxWidth: 650)
                .padding(.horizontal, 23)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

struct VideoSkeleton: View {
    var body: some View {
        LoadingSkeleton(label: "Loading video") {
            SkeletonBlock(radius: 12)
                .aspectRatio(16 / 9, contentMode: .fit)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        }
    }
}

struct ReaderPageSkeleton: View {
    var body: some View {
        GeometryReader { geometry in
            let gutter = min(20, geometry.size.width * 0.08)
            let row = max(0, (geometry.size.height - gutter * 4) / 3)
            VStack(spacing: gutter) {
                SkeletonBlock(radius: 7)
                HStack(spacing: gutter) {
                    SkeletonBlock(radius: 7)
                    SkeletonBlock(radius: 7)
                }
                SkeletonBlock(radius: 7)
            }
            .frame(height: row * 3 + gutter * 2)
            .padding(gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
