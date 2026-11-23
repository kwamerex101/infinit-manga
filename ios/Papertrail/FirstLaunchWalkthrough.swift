import SwiftUI

enum WalkthroughStep: Int {
    case discover = 0, read = 1, bookmarks = 2, source = 3
    case ready = 4, sourceReady = 5, complete = 6

    var title: String {
        switch self {
        case .discover: "The missing page"
        case .read: "Follow the ink"
        case .bookmarks: "One more chapter?"
        case .source: "Add a manga source"
        case .ready: "Your shelf is ready"
        case .sourceReady: "Source ready!"
        case .complete: ""
        }
    }

    var detail: String {
        switch self {
        case .discover: "Browse the latest chapters by source or search for a series by name."
        case .read: "Turn pages or scroll vertically. Pick your layout and reading direction in Settings."
        case .bookmarks: "Bookmark a series, queue it in Read Later, or resume a chapter from Recent."
        case .source: "Type or paste the URL of a supported manga site."
        case .ready: "Open Home to browse the latest chapters."
        case .sourceReady: "Open Home to browse chapters from your sources."
        case .complete: ""
        }
    }

    var artwork: ImageResource? {
        switch self {
        case .discover: .walkthroughMangaDiscover
        case .read: .walkthroughMangaRead
        case .bookmarks: .walkthroughMangaSave
        default: nil
        }
    }

    var comicDescription: String? {
        switch self {
        case .discover:
            "Page Spirit opens a manga in the bookshop. The last page is gone. She follows the ink trail out the window."
        case .read:
            "On the roof, Page Spirit spots the missing page in the rain and catches it."
        case .bookmarks:
            "Back in the bookshop, Page Spirit returns the page, marks her place with a ribbon, and settles in to read."
        default:
            nil
        }
    }

    var isReady: Bool { self == .ready || self == .sourceReady }

    var next: Self {
        switch self {
        case .discover: .read
        case .read: .bookmarks
        case .bookmarks: .source
        case .source: .ready
        case .ready, .sourceReady, .complete: .complete
        }
    }

    var previous: Self? {
        switch self {
        case .read: .discover
        case .bookmarks: .read
        case .source: .bookmarks
        default: nil
        }
    }
}

struct FirstLaunchWalkthrough: View {
    let step: WalkthroughStep
    let advance: (WalkthroughStep) -> Void

    @Environment(ReadingStore.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var sourceURLFocused: Bool
    @State private var sourceURL = ""
    @State private var message: String?
    @State private var celebration: Date?
    @State private var advancing = true

    private var isReady: Bool { step.isReady }
    private var isFeature: Bool { step.artwork != nil }
    private var sourceAddress: String { sourceURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            walkthroughContent
                .safeAreaInset(edge: .bottom, spacing: 0) { footer(side: side) }
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if side {
                        Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if side {
                        VStack(spacing: 8) {
                            backButton(side: true)
                            primaryButton(side: true)
                        }
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .ignoresSafeArea(.container, edges: .trailing)
                    }
                }
        }
        .background { backdrop.ignoresSafeArea(.container) }
        .onChange(of: step) { headingFocused = true }
        .accessibilityAction(.escape) {
            if let previous = step.previous { go(to: previous) }
        }
    }

    private var walkthroughContent: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if isReady {
                        Spacer().frame(height: min(88, max(20, viewport.size.height * 0.13)))
                    } else {
                        Spacer(minLength: 16)
                    }
                    if isFeature {
                        WalkthroughCardDeck(position: Double(step.rawValue))
                            .frame(height: min(460, max(140, viewport.size.height * 0.67)))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(step.comicDescription ?? "")
                            .transition(reduceMotion ? .identity : .opacity)
                        Spacer(minLength: 20)
                    }
                    ZStack {
                        pageContent
                            .id(step)
                            .transition(pageTransition)
                    }
                    if !isFeature {
                        Spacer(minLength: 20)
                    }
                }
                .padding(.bottom, isFeature ? 22 : 0)
                .frame(maxWidth: 410, alignment: .leading)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 22).onEnded(changePage)
            )
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let fromRight = advancing == (layoutDirection == .leftToRight)
        return .asymmetric(
            insertion: .offset(x: fromRight ? 110 : -110).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var colors: (background: Color, accent: Color) {
        let swatches: (light: (UInt32, UInt32), dark: (UInt32, UInt32)) = switch step {
        case .discover: ((0xE1D3F5, 0x6438B2), (0x3D2B56, 0xC4A6FF))
        case .read: ((0xD9E8FD, 0x275599), (0x233654, 0x9DC5FF))
        case .bookmarks: ((0xF6DDEF, 0x953862), (0x48293F, 0xF3ACD5))
        case .source: ((0xD4EFE6, 0x206B54), (0x1A4138, 0x8BE2C1))
        case .ready: ((0xE5DFF3, 0xD9CAF8), (0x302A45, 0xD9C2FF))
        case .sourceReady: ((0xDDEFD4, 0x406D32), (0x294227, 0xB8E5A4))
        case .complete: ((0xFAFAFA, 0x6236B2), (0x000000, 0xB79AFF))
        }
        let (background, accent) = colorScheme == .dark ? swatches.dark : swatches.light
        return (Color(uiColor: ShelfPalette.rgb(background)), Color(uiColor: ShelfPalette.rgb(accent)))
    }

    private var backdrop: some View {
        let fade = colorScheme == .dark ? Color(white: 0.13) : Color.papertrailBackground
        return LinearGradient(stops: [
            .init(color: colors.background, location: 0),
            .init(color: colors.background, location: typeSize.isAccessibilitySize ? 0.25 : 0.36),
            .init(color: fade, location: typeSize.isAccessibilitySize ? 0.70 : 0.83)
        ], startPoint: .top, endPoint: .bottom)
        .accessibilityHidden(true)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: isReady ? 22 : 18) {
            if isReady {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 25.9, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(uiColor: ShelfPalette.rgb(0x23764B)))
                        .accessibilityHidden(true)
                    pageHeading
                }
                mascot
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 18, x: 0, y: 9)
            } else {
                pageHeading
                if step == .source {
                    sourceEntry
                    mascot
                }
            }
        }
    }

    private var sourceEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(colors.accent)
                    .accessibilityHidden(true)
                TextField("Website URL", text: $sourceURL, prompt: Text("roliascan.com"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($sourceURLFocused)
                    .onSubmit(addSource)
                    .onChange(of: sourceURL) { message = nil }
                    .accessibilityIdentifier("walkthrough-source-url")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .modifier(ShelfSurface())
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(step.title)
                .font(.system(.largeTitle, design: .default, weight: .heavy))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(step.detail)
                .font(.body)
                .foregroundStyle(isReady ? Color.primary.opacity(0.72) : .secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            heroLogo
                .accessibilityHidden(true)
            Text("infinit manga")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if !isReady {
                Button("Skip tour") { go(to: .complete) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        }
        .frame(minHeight: 44)
    }

    private var heroLogo: some View {
        let pose: (size: CGFloat, x: CGFloat, y: CGFloat) = switch step {
        case .discover: (27, 0, 0)
        case .read: (35, 13, -3)
        case .bookmarks: (28, 3, 5)
        case .source: (32, 14, -1)
        case .ready, .sourceReady: (34, 8, 0)
        case .complete: (27, 0, 0)
        }

        let base: CGFloat = 27
        return Image(.brandMark)
            .resizable()
            .scaledToFill()
            .frame(width: base, height: base)
            .clipShape(Circle())
            .scaleEffect(pose.size / base)
            .offset(x: pose.x, y: pose.y)
            .frame(width: 44, height: 40, alignment: .leading)
            .shelfAnimation(step, animation: .smooth(duration: 0.38))
    }

    private var mascot: some View {
        ZStack(alignment: .bottom) {
            Color.white
            Image(.walkthroughSourcePoses)
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if step == .sourceReady, let celebration, !reduceMotion {
                WalkthroughConfetti(start: celebration)
            }
        }
        .frame(height: verticalSizeClass == .compact ? 108 : 194)
        .clipShape(.rect(cornerRadius: 22))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func footer(side: Bool) -> some View {
        let showsProgress = !isReady
        if !side || showsProgress || step == .source {
            VStack(spacing: 8) {
                if showsProgress {
                    progressIndicator
                }
                if !side {
                    HStack(spacing: 10) {
                        backButton(side: false)
                        primaryButton(side: false)
                    }
                }
                if step == .source {
                    Button("Skip for now") { go(to: .ready) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
            }
            .frame(maxWidth: 410)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private var progressIndicator: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 5) {
                ForEach(0...WalkthroughStep.source.rawValue, id: \.self) { _ in
                    Capsule()
                        .fill(Color.secondary.opacity(0.36))
                        .frame(width: 8, height: 5)
                        .frame(width: 20)
                }
            }
            Capsule()
                .fill(colors.accent)
                .frame(width: 20, height: 5)
                .offset(x: 25 * CGFloat(step.rawValue))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 4")
    }

    @ViewBuilder
    private func backButton(side: Bool) -> some View {
        if let previous = step.previous {
            Button {
                go(to: previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: side ? 50 : 54, height: side ? 50 : 54)
                    .background(colors.accent.opacity(0.18), in: .rect(cornerRadius: side ? 25 : 15))
            }
            .buttonStyle(ShelfPressStyle())
            .accessibilityLabel("Back")
        }
    }

    private func primaryButton(side: Bool) -> some View {
        let title: LocalizedStringKey = isReady ? "Open Home" : step == .source ? "Add source" : "Continue"
        let icon = isReady ? "house.fill" : step == .source ? "plus" : "arrow.right"
        let foreground = isReady ? Color(uiColor: ShelfPalette.rgb(0x341363)) : .papertrailOnAccent
        let background = isReady
            ? Color(uiColor: ShelfPalette.rgb(colorScheme == .dark ? 0xD9C2FF : 0xD9CAF8))
            : colors.accent

        return Button {
            if step == .source {
                addSource()
            } else {
                go(to: step.next, feedback: .tap)
            }
        } label: {
            Group {
                if side {
                    Image(systemName: icon)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 50, height: 50)
                } else {
                    HStack(spacing: 8) {
                        if isReady { Image(systemName: icon) }
                        Text(title)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.horizontal, 10)
                }
            }
            .font(.headline)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: side ? 25 : 15))
            .contentShape(.rect(cornerRadius: side ? 25 : 15))
        }
        .buttonStyle(ShelfPressStyle())
        .disabled(step == .source && sourceAddress.isEmpty)
        .opacity(step == .source && sourceAddress.isEmpty ? 0.55 : 1)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("walkthrough-primary")
        .overlay(alignment: .bottom) {
            if isReady && side {
                Text("Home")
                    .font(.caption2.weight(.semibold))
                    .fixedSize()
                    .offset(y: 18)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, isReady && side ? 14 : 0)
    }

    private func changePage(_ swipe: DragGesture.Value) {
        let horizontal = swipe.translation.width
        let vertical = swipe.translation.height
        guard abs(horizontal) >= 44, abs(horizontal) > abs(vertical) * 1.35 else { return }
        let forward = layoutDirection == .leftToRight ? horizontal < 0 : horizontal > 0
        if forward && isFeature {
            go(to: step.next)
        } else if !forward, let previous = step.previous {
            go(to: previous)
        }
    }

    private func go(to next: WalkthroughStep, feedback: ShelfHaptics? = .selection) {
        if step == .source { sourceURLFocused = false }
        feedback?.play()
        let duration = isFeature && next.artwork != nil ? 0.38 : 0.28
        withAnimation(reduceMotion ? nil : .smooth(duration: duration)) {
            advancing = next.rawValue > step.rawValue
            advance(next)
        }
    }

    private func addSource() {
        guard step == .source, !sourceAddress.isEmpty else { return }
        let address = sourceAddress
        let absoluteAddress = address.contains("://") ? address : "https://\(address)"
        guard var components = URLComponents(string: absoluteAddress),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            showError("Enter a website URL, such as roliascan.com.")
            return
        }
        components.scheme = "https"
        guard let url = SourceHTTP.url(components.string ?? "") else {
            showError("Enter a website URL, such as roliascan.com.")
            return
        }
        guard let source = ReadingSource.match(url) else {
            showError("This manga site isn’t supported. Try roliascan.com or mangadex.org.")
            return
        }
        switch library.addSource(source) {
        case .added, .alreadyAdded:
            break
        case .saveFailed:
            showError("Couldn’t save this source. Try again.")
            return
        }
        celebration = .now
        ShelfHaptics.success.play()
        go(to: .sourceReady, feedback: nil)
    }

    private func showError(_ error: String) {
        message = error
        ShelfHaptics.error.play()
        AccessibilityNotification.Announcement(error).post()
    }
}

private struct WalkthroughCardDeck: View, Animatable {
    var position: Double
    @Environment(\.layoutDirection) private var layoutDirection

    private let pages: [WalkthroughStep] = [.discover, .read, .bookmarks]

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.71, geometry.size.height * 0.70)
            let height = min(geometry.size.height * 0.94, width * 1.46)
            ZStack {
                ForEach(pages, id: \.self) { page in
                    if let artwork = page.artwork {
                        let position = distance(to: page)
                        let depth = abs(position)
                        let direction = layoutDirection == .leftToRight ? 1.0 : -1.0
                        // The hidden rear card wraps around; the visible cards turn between face-on positions.
                        let turn = 8 * position + 62 * sin(.pi * position)
                        comicPage(artwork, width: width, height: height)
                            .scaleEffect(1.10 * (1 - min(depth, 1.5) * 0.10))
                            .rotation3DEffect(.degrees(turn * direction), axis: (x: 0, y: 1, z: 0), perspective: 0.50)
                            .rotationEffect(.degrees(position * direction * 11))
                            .offset(x: width * position * direction * 0.17, y: depth * 8)
                            .opacity(max(0, 1 - max(0, depth - 1.05) / 0.40))
                            .zIndex(2 - depth)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func distance(to page: WalkthroughStep) -> Double {
        let distance = Double(page.rawValue) - position
        if distance > 1.5 { return distance - 3 }
        if distance < -1.5 { return distance + 3 }
        return distance
    }

    private func comicPage(_ artwork: ImageResource, width: CGFloat, height: CGFloat) -> some View {
        Image(artwork)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .background(.white)
            .clipShape(.rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.10)) }
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 6)
    }
}

private struct WalkthroughConfetti: View {
    let start: Date
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(paused: finished)) { timeline in
            let time = max(0, timeline.date.timeIntervalSince(start))
            Canvas { context, size in
                guard time < 1.25 else { return }
                let colors: [Color] = [.papertrailAccent, .pink, .yellow, .cyan]
                for index in 0..<38 {
                    let angle = Double(index) * 2.39996
                    let speed = Double(65 + (index * 23) % 160)
                    let x = size.width * 0.5 + cos(angle) * speed * time
                    let y = size.height * 0.65 + sin(angle) * speed * time - 90 * time + 118 * time * time
                    var piece = context
                    piece.opacity = min(1, (1.25 - time) * 3)
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(angle + time * 7))
                    let rect = CGRect(x: -3, y: -2, width: index.isMultiple(of: 3) ? 9 : 6, height: 4)
                    piece.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colors[index % colors.count]))
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.25))
            if !Task.isCancelled { finished = true }
        }
        .allowsHitTesting(false)
    }
}
