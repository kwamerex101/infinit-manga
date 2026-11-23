import SwiftUI
import UIKit

extension GeometryProxy {
    func usesShelfSideNavigation(verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        verticalSizeClass != .compact && (size.width >= 680 || safeAreaInsets.trailing >= 24)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ShelfMotion {
    static let fade = Animation.easeOut(duration: 0.18)
    static let layout = Animation.smooth(duration: 0.24)
    static let feedback = Animation.easeOut(duration: 0.14)
}

enum ShelfHaptics {
    case tap, selection, pageTurn, success, warning, error

    @MainActor func play() {
        switch self {
        case .tap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .pageTurn:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension Binding where Value: Equatable {
    @MainActor func withSelectionFeedback() -> Self {
        Binding(get: { wrappedValue }, set: { value in
            guard wrappedValue != value else { return }
            wrappedValue = value
            ShelfHaptics.selection.play()
        })
    }
}

extension View {
    func shelfAnimation<Value: Equatable>(_ value: Value, animation: Animation = ShelfMotion.fade) -> some View {
        modifier(ShelfAnimation(value: value, animation: animation))
    }

    func shelfEntrance() -> some View {
        modifier(ShelfEntrance())
    }

    func shelfResumeTile() -> some View {
        frame(maxWidth: 340)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShelfAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct ShelfEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .animation(reduceMotion || !appeared ? nil : ShelfMotion.fade, value: appeared)
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
    }
}

struct ShelfPalette {
    let background: UIColor
    let ink: UIColor
    let panel: UIColor
    let feature: UIColor
    let accent: UIColor
    let onAccent: UIColor
    let navigation: UIColor
    let selection: UIColor
    let detail: UIColor
    let stroke: UIColor

    static let light = ShelfPalette(
        background: UIColor(white: 0.98, alpha: 1), ink: .white,
        panel: UIColor(white: 0.94, alpha: 1),
        feature: rgb(0xF3E9FA), accent: rgb(0x6236B2), onAccent: .white,
        navigation: rgb(0x494AA1), selection: rgb(0xE9E7FC), detail: rgb(0x793983),
        stroke: UIColor.black.withAlphaComponent(0.12)
    )
    static let dark = ShelfPalette(
        background: .black, ink: .black, panel: UIColor(white: 0.10, alpha: 1),
        feature: rgb(0x2A1C3B), accent: rgb(0xB79AFF), onAccent: rgb(0x170F2B),
        navigation: rgb(0xACB2FF), selection: rgb(0x29254A), detail: rgb(0xE2A9EC),
        stroke: UIColor.white.withAlphaComponent(0.12)
    )

    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let papertrailBackground = themed(\.background)
    static let papertrailInk = themed(\.ink)
    static let papertrailPanel = themed(\.panel)
    static let papertrailFeature = themed(\.feature)
    static let papertrailAccent = themed(\.accent)
    static let papertrailOnAccent = themed(\.onAccent)
    static let papertrailNavigation = themed(\.navigation)
    static let papertrailSelection = themed(\.selection)
    static let papertrailDetail = themed(\.detail)
    static let papertrailStroke = themed(\.stroke)

    private static func themed(_ field: KeyPath<ShelfPalette, UIColor>) -> Color {
        Color(uiColor: UIColor { traits in
            let palette = traits.userInterfaceStyle == .dark ? ShelfPalette.dark : .light
            return palette[keyPath: field]
        })
    }
}

struct ShelfMasthead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .tracking(-0.65)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ShelfHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .tracking(-0.35)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ShelfSettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded.withSelectionFeedback()) {
            content().padding(.top, 8)
        } label: {
            ShelfHeading(title)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

struct ShelfStateView: View {
    enum Style {
        case standard, compact
    }

    struct Action {
        let title: String
        let perform: () -> Void

        init(_ title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let message: String?
    private let style: Style
    private let action: Action?

    init(_ title: String, message: String? = nil,
         style: Style = .standard, action: Action? = nil) {
        self.title = title
        self.message = message
        self.style = style
        self.action = action
    }

    init(failure: SourceLoadFailure, title: String, message: String,
         offlineMessage: String = "Reconnect to the internet and try again.",
         style: Style = .standard, action: Action) {
        switch failure {
        case .offline:
            self.init("No internet connection", message: offlineMessage, style: style, action: action)
        case .source(let detail):
            self.init(title, message: detail ?? message, style: style, action: action)
        }
    }

    var body: some View {
        let compact = style == .compact
        VStack(spacing: compact ? 7 : 12) {
            ShelfMascotBadge(size: compact ? 42 : 72, stateTitle: title)

            VStack(spacing: 5) {
                Text(title)
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(compact ? .footnote : .subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button {
                    ShelfHaptics.tap.play()
                    action.perform()
                } label: {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.papertrailAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Color.papertrailAccent.opacity(0.10), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(ShelfPressStyle())
            }
        }
        .frame(maxWidth: 330)
        .padding(.horizontal, compact ? 4 : 16)
        .padding(.vertical, compact ? 12 : 28)
        .frame(maxWidth: .infinity)
        .transition(reduceMotion ? .identity : .opacity)
    }
}

private struct ShelfMascotBadge: View {
    let size: CGFloat
    let stateTitle: String
    @State private var pose: ShelfMascotPose?

    var body: some View {
        ZStack {
            if let pose {
                ShelfMascotAvatar(pose: pose, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(Color.papertrailAccent.opacity(0.28)) }
        .accessibilityHidden(true)
        .onAppear { pose = ShelfMascotPose.next() }
        .onChange(of: stateTitle) { pose = ShelfMascotPose.next() }
    }
}

struct ShelfMascotAvatar: View {
    let pose: ShelfMascotPose
    let size: CGFloat

    var body: some View {
        let scale = size / 360
        Image(.stateMascot)
            .resizable()
            .frame(width: 1774 * scale, height: 887 * scale)
            .offset(x: (887 - pose.center.x) * scale, y: (443.5 - pose.center.y) * scale)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

@MainActor
enum ShelfMascotPose: CaseIterable {
    case wave, point, salute, flourish

    // The order changes each launch. A pose is shown once per rotation.
    private static let order = allCases.shuffled()
    private static var index = 0

    static func next() -> Self {
        let pose = order[index]
        index = (index + 1) % order.count
        return pose
    }

    // Centers are measured on the original 1774 × 887 artwork.
    var center: CGPoint {
        switch self {
        case .wave: CGPoint(x: 224, y: 200)
        case .point: CGPoint(x: 647, y: 225)
        case .salute: CGPoint(x: 1057, y: 181)
        case .flourish: CGPoint(x: 1419, y: 247)
        }
    }
}

struct ShelfSurface: ViewModifier {
    var radius: CGFloat = 15

    func body(content: Content) -> some View {
        content
            .background(Color.papertrailPanel, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.papertrailStroke)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct ShelfIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.papertrailDetail)
            .frame(width: 35, height: 35)
            .background(Color.papertrailFeature, in: .rect(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct ShelfDockIcon: View {
    let symbol: String
    var selected = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(selected ? Color.papertrailNavigation : .secondary)
            .frame(width: 50, height: 50)
            .background {
                Circle().fill(.regularMaterial)
                    .overlay { Circle().fill(selected ? Color.papertrailSelection : .clear) }
            }
            .overlay { Circle().strokeBorder(Color.papertrailStroke) }
            .contentShape(Circle())
    }
}

enum ShelfDestination: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", settings = "Settings", agent = "Agent", search = "Search"

    var id: Self { self }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .library: "books.vertical.fill"
        case .settings: "gearshape.fill"
        case .agent: "bubble.left.and.text.bubble.right.fill"
        case .search: "magnifyingglass"
        }
    }

    var isShortcut: Bool { self == .agent || self == .search }
}

struct ShelfNavigation<Content: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding var selection: ShelfDestination
    var destinations = ShelfDestination.allCases
    var identifierPrefix = "dock"
    var showsDock = true
    var inlineDock = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.usesShelfSideNavigation(verticalSizeClass: verticalSizeClass)
            VStack(spacing: 0) {
                content()
                if showsDock && !side && inlineDock {
                    dock(side: false).padding(.vertical, 5)
                }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if showsDock && side {
                    Color.clear.frame(width: max(0, 66 - geometry.safeAreaInsets.trailing))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsDock && !side && !inlineDock {
                    dock(side: false).padding(.vertical, 5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsDock && side {
                    dock(side: true)
                        .padding([.trailing, .bottom], 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .ignoresSafeArea(.container, edges: .trailing)
                }
            }
            .shelfAnimation(showsDock)
        }
    }

    private func dock(side: Bool) -> some View {
        let outer = side ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        let inner = side ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return outer {
            inner {
                ForEach(destinations.filter { !$0.isShortcut }) { destination in
                    dockButton(destination, side: side)
                }
            }
            .padding(3)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.papertrailStroke) }
            ForEach(destinations.filter(\.isShortcut)) { destination in
                dockButton(destination, side: side)
            }
        }
        .buttonStyle(ShelfPressStyle())
        .transition(.opacity)
    }

    private func dockButton(_ destination: ShelfDestination, side: Bool) -> some View {
        let selected = selection == destination
        return Button {
            if selected {
                ShelfHaptics.tap.play()
            } else {
                ShelfHaptics.selection.play()
                selection = destination
            }
        } label: {
            if destination.isShortcut {
                ShelfDockIcon(symbol: destination.icon, selected: selected)
            } else {
                VStack(spacing: 3) {
                    Image(systemName: destination.icon).font(.system(size: side ? 21 : 18, weight: .semibold))
                    if !side { Text(destination.rawValue).font(.caption2.weight(.medium)) }
                }
                .foregroundStyle(selected ? Color.papertrailNavigation : .secondary)
                .frame(width: side ? 44 : 62, height: side ? 44 : 48)
                .background(selected ? Color.papertrailSelection : .clear, in: Capsule())
                .contentShape(Capsule())
            }
        }
        .accessibilityLabel(destination.rawValue)
        .accessibilityIdentifier("\(identifierPrefix)-\(destination.rawValue.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .shelfAnimation(selected, animation: ShelfMotion.feedback)
    }
}

struct ShelfPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.74 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : ShelfMotion.feedback, value: configuration.isPressed)
    }
}

struct ShelfSearchBar<Field: View>: View {
    let hasQuery: Bool
    var submit: (() -> Void)?
    var submitIdentifier = "submit-search"
    var canSubmit = true
    let clear: () -> Void
    @ViewBuilder let field: () -> Field

    var body: some View {
        HStack(spacing: 4) {
            if let submit {
                Button(action: submit) { searchIcon }
                    .accessibilityLabel("Submit search")
                    .accessibilityIdentifier(submitIdentifier)
                    .disabled(!hasQuery || !canSubmit)
            } else {
                searchIcon.accessibilityHidden(true)
            }
            field()
            if hasQuery {
                Button {
                    ShelfHaptics.tap.play()
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search text")
                .transition(.opacity)
            }
        }
        .padding(.trailing, hasQuery ? 0 : 14)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.papertrailStroke).allowsHitTesting(false) }
        .font(.body.weight(.medium))
        .buttonStyle(ShelfPressStyle())
        .shelfAnimation(hasQuery, animation: ShelfMotion.feedback)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(hasQuery && canSubmit ? Color.papertrailAccent : Color.secondary)
            .frame(width: 44, height: 48)
            .contentShape(Rectangle())
    }
}

struct ShelfSearchPage<Filters: View, Results: View, SearchBar: View>: View {
    let mode: String
    let cancel: () -> Void
    @ViewBuilder let filters: () -> Filters
    @ViewBuilder let results: () -> Results
    @ViewBuilder let searchBar: () -> SearchBar

    var body: some View {
        VStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    ShelfMasthead(title: "Search")
                    Button(action: cancel) {
                        Text("Cancel")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color(uiColor: .systemRed))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-\(mode)-search")
                }
                filters()
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)

            GeometryReader { viewport in
                ScrollView {
                    results()
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                        .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            HStack(spacing: 10) {
                searchBar()
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(uiColor: .systemRed))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(Color.papertrailStroke) }
                        .contentShape(Circle())
                }
                .buttonStyle(ShelfPressStyle())
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("close-\(mode)-search")
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .background(Color.papertrailBackground)
        .accessibilityAction(.escape, cancel)
        .toolbar(.hidden, for: .tabBar)
        .shelfEntrance()
    }
}

struct ShelfListSearch: View {
    let prompt: String
    let identifier: String
    @Binding var query: String
    var autofocus = false
    var submit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $query)
                .font(.subheadline)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(performSearch)
                .accessibilityIdentifier(identifier)
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            if submit != nil {
                Button("Go", action: performSearch)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(ShelfListQuery(query).isEmpty)
            }
        }
        .buttonStyle(ShelfPressStyle())
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .modifier(ShelfSurface(radius: 10))
        .task {
            if autofocus { focused = true }
        }
    }

    private func performSearch() {
        guard !ShelfListQuery(query).isEmpty else { return }
        focused = false
        submit?()
    }
}

struct ShelfListQuery {
    let text: String
    private let number: String?

    init(_ query: String) {
        text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.replacingOccurrences(of: #"(?i)^(chapter|issue|episode|page)\s+|^#"#,
                                                 with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        number = Chapter.normalizedNumber(candidate)
    }

    var isEmpty: Bool { text.isEmpty }

    func matches(number itemNumber: String?, title: String, label: String = "") -> Bool {
        if isEmpty { return true }
        if let number, let itemNumber { return Chapter.normalizedNumber(itemNumber) == number }
        return title.localizedStandardContains(text) || label.localizedStandardContains(text)
    }
}

struct ShelfSourceFilters<Source: Hashable & RawRepresentable>: View where Source.RawValue == String {
    let sources: [Source]
    @Binding var selection: Source?
    let name: (Source) -> String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    filter(nil)
                    ForEach(sources, id: \.self) { source in filter(source).id(source) }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection, initial: true) {
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by source")
    }

    private func filter(_ source: Source?) -> some View {
        let selected = selection == source
        return Button {
            guard !selected else { return }
            selection = source
            ShelfHaptics.selection.play()
        } label: {
            VStack(spacing: 7) {
                Text(source.map(name) ?? "All sources")
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : .secondary)
                Capsule().fill(selected ? Color.papertrailNavigation : .clear).frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("source-filter-\(source?.rawValue ?? "all")")
        .shelfAnimation(selected, animation: ShelfMotion.feedback)
    }
}

struct ShelfProviderSettings<Source: Hashable & RawRepresentable>: View where Source.RawValue == String {
    let title: String
    let sources: [Source]
    let name: (Source) -> String
    let website: (Source) -> URL
    let isEnabled: (Source) -> Bool
    let setEnabled: (Bool, Source) -> Void

    @State private var expanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShelfMasthead(title: title)
                ShelfSettingsDisclosure(title: "Sources", expanded: $expanded) {
                    VStack(spacing: 0) {
                        ForEach(sources, id: \.self) { source in
                            providerRow(source)
                            if source != sources.last { Divider().padding(.horizontal, 12) }
                        }
                    }
                    .modifier(ShelfSurface())
                    Text("Choose which sources appear in Home and Search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
            }
            .padding(18)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .shelfEntrance()
    }

    private func providerRow(_ source: Source) -> some View {
        HStack(spacing: 10) {
            ShelfIcon(name: "link")
            Toggle(name(source), isOn: Binding {
                isEnabled(source)
            } set: { enabled in
                setEnabled(enabled, source)
            }.withSelectionFeedback())
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("provider-\(source.rawValue)")
            Link(destination: website(source)) {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 36, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open \(name(source))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
