import SwiftUI

enum ReadingDirection: String, CaseIterable, Identifiable {
    case rightToLeft = "Right to left"
    case leftToRight = "Left to right"

    var id: Self { self }
    var isRTL: Bool { self == .rightToLeft }
}

struct SourceSettings: View {
    private enum SettingsSection: String {
        case appearance = "Appearance"
        case reader = "Reader"
        case notifications = "Notifications"
        case sources = "Sources"
        case storage = "Storage"
    }

    @Environment(ReadingStore.self) private var library
    @Environment(SavedChapterUpdates.self) private var savedUpdates
    @Environment(ChapterAlerts.self) private var chapterAlerts
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var appearance: AppAppearance
    @AppStorage("reading-layout") private var layout = ReadingLayout.automatic
    @AppStorage("reading-direction") private var direction = ReadingDirection.rightToLeft
    @State private var showingSourcePicker = false
    @State private var showingComix = false
    @State private var message: String?
    @State private var wide = false
    @State private var expandedSections: Set<SettingsSection> = [.appearance]
    @State private var sourceToRemove: URL?
    @State private var confirmingCacheClear = false
    @State private var clearingCache = false
    @State private var cacheCleared = false
    @State private var changingNotifications = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShelfMasthead(title: "Settings")
                let columns = wide && !typeSize.isAccessibilitySize
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                columns {
                    VStack(alignment: .leading, spacing: 24) {
                        settingsSection(.appearance) { appearanceSettings }
                        settingsSection(.reader) { readerSettings }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 24) {
                        settingsSection(.notifications) { notificationSettings }
                        settingsSection(.sources) { sources }
                        settingsSection(.storage) { storageSettings }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .shelfAnimation(wide, animation: ShelfMotion.layout)
                about
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 22)
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= 680
        } action: { expanded in
            wide = expanded
        }
        .background(Color.papertrailBackground)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { expandedSections = [.appearance] }
        .shelfEntrance()
        .sheet(isPresented: $showingSourcePicker) {
            SourcePicker(added: Set(library.enabledSources), comixAdded: library.hasComix) { source in
                add(source)
                showingSourcePicker = false
            }
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingComix) {
            InAppWebsiteBrowser(site: .comix, url: InAppWebsite.comixURL)
        }
        .alert("Remove this source?", isPresented: Binding(
            get: { sourceToRemove != nil },
            set: { if !$0 { sourceToRemove = nil } }
        ), presenting: sourceToRemove) { website in
            Button("Cancel", role: .cancel) { ShelfHaptics.tap.play() }
            Button("Remove", role: .destructive) {
                library.removeSource(website)
                message = nil
                ShelfHaptics.warning.play()
            }
        } message: { website in
            Text(website.absoluteString)
        }
        .alert("Clear cache?", isPresented: $confirmingCacheClear) {
            Button("Cancel", role: .cancel) { ShelfHaptics.tap.play() }
            Button("Clear cache", role: .destructive) {
                clearingCache = true
                cacheCleared = false
                Task {
                    SourceMemory.removeAll()
                    savedUpdates.clear()
                    await Artwork.clearCache()
                    clearingCache = false
                    cacheCleared = true
                    ShelfHaptics.success.play()
                    AccessibilityNotification.Announcement("Cache cleared").post()
                }
            }
        } message: {
            Text("Cached covers, pages, and source data will be removed. Your bookmarks and reading progress are kept.")
        }
    }

    @ViewBuilder
    private var about: some View {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String {
            Text("Version \(version) (\(build))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-app-version")
        }
    }

    private func settingsSection<Content: View>(
        _ section: SettingsSection,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = Binding(
            get: { expandedSections.contains(section) },
            set: { expanded in
                if expanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
        return ShelfSettingsDisclosure(title: section.rawValue, expanded: isExpanded) {
            content()
        }
    }

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { chapterAlerts.enabled }, set: { enabled in
                ShelfHaptics.selection.play()
                changingNotifications = true
                Task {
                    await chapterAlerts.setEnabled(enabled, library: library)
                    changingNotifications = false
                }
            })) {
                HStack(spacing: 9) {
                    ShelfIcon(name: "bell")
                    Text("New chapters")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .accessibilityIdentifier("new-chapter-notifications")
            .disabled(changingNotifications)

            Text("Get alerts for bookmarked manga. iOS decides when checks run in the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if chapterAlerts.permissionDenied {
                Button("Open iOS notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
        .padding(12)
        .modifier(ShelfSurface())
        .shelfAnimation(chapterAlerts.permissionDenied)
    }

    private var storageSettings: some View {
        Button {
            ShelfHaptics.tap.play()
            confirmingCacheClear = true
        } label: {
            HStack(spacing: 9) {
                ShelfIcon(name: "trash")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear cache")
                        .font(.subheadline.weight(.semibold))
                    Text(clearingCache ? "Clearing…" : cacheCleared ? "Cache cleared" : "Remove temporary files and source data")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                if clearingCache {
                    SkeletonLine(label: "Clearing cache", width: 24)
                        .accessibilityHidden(true)
                } else if cacheCleared {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.papertrailAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .buttonStyle(ShelfPressStyle())
        .modifier(ShelfSurface())
        .disabled(clearingCache)
        .accessibilityIdentifier("clear-cache")
        .shelfAnimation(clearingCache)
        .shelfAnimation(cacheCleared)
    }

    private var appearanceSettings: some View {
        previewArrangement {
            ForEach(AppAppearance.allCases) { option in
                previewChoice(option.rawValue, selected: appearance == option, id: "theme-\(option.rawValue.lowercased())") {
                    appearance = option
                } preview: {
                    AppearancePreview(appearance: option)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func previewArrangement<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let arrangement = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return arrangement { content() }
    }

    private func previewChoice<Preview: View>(_ title: String, selected: Bool, id: String,
                                             action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) -> some View {
        return Button {
            guard !selected else { return }
            action()
            ShelfHaptics.selection.play()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                preview()
                    .frame(height: 64)
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.papertrailNavigation)
                                .padding(4)
                                .background(Color.papertrailBackground, in: Circle())
                                .padding(3)
                                .transition(.opacity)
                        }
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.papertrailPanel, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.papertrailNavigation : Color.papertrailStroke, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .shelfAnimation(selected, animation: ShelfMotion.feedback)
    }

    private var readerSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 13) {
                preferenceHeading("Default layout", icon: "rectangle.split.2x1")
                previewArrangement {
                    layoutChoice("Auto spread", option: .automatic)
                    layoutChoice("Single", option: .single)
                    layoutChoice("Scroll", option: .vertical)
                }

                settingsDivider

                preferenceHeading("Page direction", icon: "arrow.left.arrow.right")
                previewArrangement {
                    ForEach(ReadingDirection.allCases) { option in
                        previewChoice(option.rawValue, selected: direction == option, id: option.isRTL ? "direction-rtl" : "direction-ltr") {
                            direction = option
                        } preview: {
                            DirectionPreview(direction: option)
                        }
                    }
                }
            }
            .padding(12)
            .modifier(ShelfSurface())
            Text(readingHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .contentTransition(.opacity)
                .shelfAnimation(readingHint)
        }
    }

    private func layoutChoice(_ title: String, option: ReadingLayout) -> some View {
        previewChoice(title, selected: layout == option, id: "layout-\(option.rawValue)") {
            layout = option
        } preview: {
            LayoutPreview(layout: option)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                message = nil
                showingSourcePicker = true
                ShelfHaptics.tap.play()
            } label: {
                HStack(spacing: 9) {
                    ShelfIcon(name: "magnifyingglass")
                    Text("Add a source").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(ShelfPressStyle())
            .accessibilityIdentifier("settings-add-source")

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
            }

            ForEach(library.sourceURLs, id: \.self) { website in
                settingsDivider
                siteRow(website)
            }
        }
        .modifier(ShelfSurface())
        .shelfAnimation(library.sourceURLs, animation: ShelfMotion.layout)
    }

    private var readingHint: String {
        guard layout != .vertical else { return "Swipe up to continue reading." }
        return direction.isRTL ? "Swipe right to turn the page." : "Swipe left to turn the page."
    }

    private var settingsDivider: some View {
        Divider().padding(.horizontal, 12)
    }

    private func preferenceHeading(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) {
            ShelfIcon(name: icon)
            Text(title).font(.subheadline.weight(.semibold))
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func siteRow(_ website: URL) -> some View {
        let provider = ReadingSource.match(website)
        let isComix = InAppWebsite.comix.contains(website)
        let title = isComix ? InAppWebsite.comix.name : provider?.name ?? "Website link"
        let label = HStack(spacing: 10) {
            SourceLogo(source: provider)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(website.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        return HStack(spacing: 8) {
            Group {
                if isComix {
                    Button {
                        ShelfHaptics.tap.play()
                        showingComix = true
                    } label: { label }
                } else {
                    Link(destination: website) { label }
                }
            }
            .buttonStyle(ShelfPressStyle())

            Button {
                sourceToRemove = website
                ShelfHaptics.tap.play()
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(isComix ? title : provider?.name ?? website.absoluteString)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
    }

    private func add(_ source: SourcePicker.Option) {
        let result = switch source {
        case .native(let provider): library.addSource(provider)
        case .comix: library.addComixSource()
        }
        switch result {
        case .added:
            message = nil
            ShelfHaptics.success.play()
        case .alreadyAdded:
            message = "This source is already added."
        case .saveFailed:
            message = "Couldn’t save this source. Try again."
            ShelfHaptics.error.play()
        }
    }
}

private struct SourceLogo: View {
    let source: ReadingSource?

    var body: some View {
        Group {
            if let source, let logo = UIImage(named: "SourceLogo-\(source.rawValue)") {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 35, height: 35)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                ShelfIcon(name: "link")
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SourcePicker: View {
    enum Option: Hashable, Identifiable {
        case native(ReadingSource)
        case comix

        var id: String { provider?.rawValue ?? "comix" }
        var name: String { provider?.name ?? InAppWebsite.comix.name }
        var homepage: URL { provider?.homepage ?? InAppWebsite.comixURL }

        var provider: ReadingSource? {
            if case .native(let source) = self { return source }
            return nil
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let added: Set<ReadingSource>
    let comixAdded: Bool
    let select: (Option) -> Void

    private func isAdded(_ source: Option) -> Bool {
        source.provider.map { added.contains($0) } ?? comixAdded
    }

    private var suggestions: [Option] {
        let options = ReadingSource.allCases.map(Option.native) + [.comix]
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return options }
        let key = search.filter { $0.isLetter || $0.isNumber }
        return options.filter { source in
            let name = source.name.filter { $0.isLetter || $0.isNumber }
            return source.name.localizedCaseInsensitiveContains(search)
                || source.homepage.absoluteString.localizedCaseInsensitiveContains(search)
                || (!key.isEmpty && name.localizedCaseInsensitiveContains(key))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search sources", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("source-picker-search")
                        .onSubmit {
                            if suggestions.count == 1, let source = suggestions.first, !isAdded(source) {
                                select(source)
                            }
                        }
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .modifier(ShelfSurface())
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

                if suggestions.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(suggestions) { source in
                        let isAdded = isAdded(source)
                        Button {
                            select(source)
                        } label: {
                            HStack(spacing: 10) {
                                SourceLogo(source: source.provider)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name).font(.body.weight(.semibold))
                                    if source == .comix {
                                        Text("Opens in the in-app browser")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isAdded {
                                    Text("Added").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "plus.circle").accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .disabled(isAdded)
                        .accessibilityIdentifier("source-option-\(source.id)")
                    }
                    .listStyle(.insetGrouped)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Add a source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .tint(Color(uiColor: .systemRed))
                }
            }
        }
    }
}

private struct AppearancePreview: View {
    let appearance: AppAppearance

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature(appearance == .light ? .light : .dark)
                if appearance == .system {
                    miniature(.light)
                        .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width / 2) }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.papertrailStroke) }
    }

    private func miniature(_ palette: ShelfPalette) -> some View {
        let accent = Color(uiColor: palette.accent)
        return VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(accent).frame(width: 24, height: 3)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.65)).frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(accent.opacity(0.65)).frame(width: 20, height: 2)
                    Capsule().fill(accent.opacity(0.30)).frame(width: 13, height: 2)
                }
                Spacer(minLength: 0)
            }
            .padding(3)
            .frame(height: 19)
            .background(Color(uiColor: palette.panel), in: .rect(cornerRadius: 4))
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.15 + Double(index) * 0.10))
                }
            }
        }
        .padding(7)
        .background(Color(uiColor: palette.background))
    }
}

private struct LayoutPreview: View {
    let layout: ReadingLayout

    var body: some View {
        Group {
            switch layout {
            case .automatic:
                HStack(spacing: 3) {
                    page(width: 26, height: 38)
                    page(width: 26, height: 38)
                }
            case .single:
                page(width: 33, height: 44)
            case .vertical:
                HStack(spacing: 6) {
                    VStack(spacing: 3) {
                        page(width: 29, height: 20)
                        page(width: 29, height: 20)
                    }
                    Image(systemName: "arrow.up.and.down").font(.caption.weight(.semibold))
                }
            }
        }
        .foregroundStyle(Color.papertrailAccent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.papertrailBackground, in: .rect(cornerRadius: 7))
    }

    private func page(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(Color.papertrailAccent.opacity(0.45))
            RoundedRectangle(cornerRadius: 2).fill(Color.papertrailAccent.opacity(0.22))
        }
        .padding(3)
        .frame(width: width, height: height)
        .background(Color.papertrailFeature, in: .rect(cornerRadius: 3))
    }
}

private struct DirectionPreview: View {
    let direction: ReadingDirection

    var body: some View {
        HStack(spacing: 7) {
            page(direction.isRTL ? 2 : 1)
            Image(systemName: direction.isRTL ? "arrow.left" : "arrow.right")
                .font(.caption.weight(.semibold))
            page(direction.isRTL ? 1 : 2)
        }
        .foregroundStyle(Color.papertrailAccent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.papertrailBackground, in: .rect(cornerRadius: 7))
    }

    private func page(_ number: Int) -> some View {
        Text(number.formatted())
            .font(.caption2.weight(.semibold).monospacedDigit())
            .frame(width: 22, height: 31)
            .background(Color.papertrailFeature, in: .rect(cornerRadius: 3))
    }
}
