import SwiftUI

struct ChapterPicker: View {
    @Environment(ReadingStore.self) private var library
    @AppStorage("chapters-unread-only") private var unreadOnly = false
    let manga: Manga
    let current: Chapter
    let select: (Chapter) -> Void
    let close: () -> Void

    @State private var chapters: [Chapter] = []
    @State private var nextOffset: Int?
    @State private var request = Request()
    @State private var loading = true
    @State private var failure: SourceLoadFailure?
    @State private var chapterQuery = ""
    @State private var lookup: String?
    @State private var lookupIssue: LookupIssue?
    @FocusState private var chapterFieldFocused: Bool

    private struct Request: Equatable {
        var ascending = false
        var offset = 0
        var attempt = 0
    }

    private enum LookupIssue: Equatable {
        case invalidNumber, notFound(String), failed(SourceLoadFailure)
    }

    private var visibleChapters: [Chapter] {
        unreadOnly ? chapters.filter { !library.progress($0).read } : chapters
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            chapterSearch
            if !chapters.contains(where: { $0.rowKey == current.rowKey }),
               !unreadOnly || !library.progress(current).read {
                row(current).padding(.horizontal, 12)
                    .transition(.opacity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(visibleChapters, id: \.rowKey) { chapter in
                            row(chapter).id(chapter.rowKey)
                                .transition(.opacity)
                        }
                        footer
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                    .shelfAnimation(visibleChapters.map(\.rowKey))
                    .shelfAnimation(loading)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: loading) {
                    if !loading, request.offset == 0, visibleChapters.contains(where: { $0.rowKey == current.rowKey }) {
                        proxy.scrollTo(current.rowKey, anchor: .center)
                    }
                }
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.papertrailBackground)
        .shelfAnimation(unreadOnly)
        .task(id: request) { await load(request) }
        .task(id: lookup) {
            if let lookup { await findChapter(lookup) }
        }
        .onChange(of: chapterQuery) {
            lookup = nil
            lookupIssue = nil
        }
    }

    private var chapterSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Chapter number", text: Binding(get: { chapterQuery }, set: { chapterQuery = Self.numericInput($0) }))
                    .font(.subheadline)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($chapterFieldFocused)
                    .onSubmit(startJump)
                    .accessibilityIdentifier("chapter-number-field")
                Button("Go", action: startJump)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .buttonStyle(ShelfPressStyle())
                    .disabled(chapterQuery.isEmpty || lookup != nil)
                    .accessibilityLabel("Go to chapter")
            }
            .padding(.leading, 12)
            .modifier(ShelfSurface(radius: 10))
            if lookup != nil {
                LoadingSkeleton(label: "Finding chapter") { SkeletonBlock(radius: 5).frame(height: 12) }
                    .transition(.opacity)
            } else if let lookupIssue {
                lookupState(lookupIssue)
                    .accessibilityIdentifier("chapter-lookup-message")
            }
        }
        .padding(.horizontal, 12)
        .shelfAnimation(lookup != nil)
        .shelfAnimation(lookupIssue)
    }

    @ViewBuilder
    private func lookupState(_ issue: LookupIssue) -> some View {
        switch issue {
        case .invalidNumber:
            Text("Enter a chapter number, such as 12 or 12.5.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notFound(let number):
            ShelfStateView("Chapter \(number) unavailable",
                           message: "No chapter with that number was found on \(manga.provider.name).",
                           style: .compact, action: .init("Edit number") { chapterFieldFocused = true })
        case .failed(let failure):
            ShelfStateView(failure: failure, title: "Chapter lookup failed",
                           message: "Couldn’t look up that chapter on \(manga.provider.name).",
                           style: .compact, action: .init("Retry", perform: startJump))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ShelfHeading("Chapters")
                Spacer()
                Menu {
                    Picker("Chapter order", selection: Binding(get: { request.ascending }, set: {
                        request = Request(ascending: $0)
                    }).withSelectionFeedback()) {
                        Text("Newest first").tag(false)
                        Text("Oldest first").tag(true)
                    }
                    Divider()
                    Toggle("Unread only", isOn: $unreadOnly.withSelectionFeedback())
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Sort and filter chapters")
                .accessibilityValue(unreadOnly ? "Unread only" : "All chapters")
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .buttonStyle(ShelfPressStyle())
                .accessibilityLabel("Close chapters")
                .keyboardShortcut(.cancelAction)
            }
            Text(manga.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
    }

    private func row(_ chapter: Chapter) -> some View {
        let selected = chapter.rowKey == current.rowKey
        let read = library.progress(chapter).read
        return Button {
            if selected { ShelfHaptics.tap.play() }
            select(selected ? current : library.readingRelease(chapter))
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.displayTitle).font(.subheadline.weight(selected ? .semibold : .medium))
                    if let note = chapter.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected || read {
                    Image(systemName: selected ? "book.fill" : "checkmark")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? Color.papertrailNavigation : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .background(selected ? Color.papertrailSelection : .clear, in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(read ? "Read" : "")
        .contextMenu {
            if chapter.alternateReleases != nil {
                ForEach(chapter.releases) { release in
                    Button(release.releaseLabel) { select(chapter.opening(release)) }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !loading, failure == nil, unreadOnly, visibleChapters.isEmpty, !chapters.isEmpty {
            ShelfStateView("No unread chapters",
                           message: nextOffset == nil ? "Show all chapters to revisit them." : "Load more to check the remaining chapters.",
                           style: .compact)
        }
        if loading {
            ForEach(0..<(visibleChapters.isEmpty ? 4 : 2), id: \.self) { index in
                LoadingSkeleton(label: "Loading chapters") { ChapterRowSkeleton() }
                    .accessibilityHidden(index != 0)
            }
        } else if let failure {
            ShelfStateView(failure: failure, title: "Chapters unavailable",
                           message: "Couldn’t load chapters from \(manga.provider.name).",
                           style: .compact, action: .init("Retry") { request.attempt += 1 })
        } else if let nextOffset {
            Button("Load more chapters") {
                ShelfHaptics.tap.play()
                request.offset = nextOffset
            }
            .frame(minHeight: 44)
        } else if chapters.isEmpty {
            ShelfStateView("No more chapters",
                           message: "\(manga.provider.name) lists no other chapters for this series.",
                           style: .compact)
        }
    }

    private func load(_ request: Request) async {
        loading = true
        failure = nil
        if request.offset == 0 {
            chapters = []
            nextOffset = nil
        }
        defer { if !Task.isCancelled { loading = false } }
        do {
            let info = try await manga.provider.series(manga.slug)
            let list = try await manga.provider.chapters(info, offset: request.offset, ascending: request.ascending)
            try Task.checkCancellation()
            chapters = Chapter.coalesced(chapters + list.items.filter { $0.slug == manga.slug })
            nextOffset = list.nextOffset
        } catch {
            if !Task.isCancelled { failure = SourceLoadFailure(error) }
        }
    }

    private func startJump() {
        guard lookup == nil else { return }
        guard let number = Chapter.normalizedNumber(chapterQuery) else {
            lookupIssue = .invalidNumber
            ShelfHaptics.error.play()
            return
        }
        chapterFieldFocused = false
        ShelfHaptics.tap.play()
        lookupIssue = nil
        lookup = number
    }

    private func findChapter(_ number: String) async {
        defer { if !Task.isCancelled { lookup = nil } }
        if let cached = ([current] + chapters).first(where: { Chapter.normalizedNumber($0.number) == number }) {
            select(library.readingRelease(cached))
            return
        }

        // Start from the older end for numbers below the current chapter, or reuse pages already browsed.
        let locale = Locale(identifier: "en_US_POSIX")
        let target = Decimal(string: number, locale: locale)
        let currentNumber = Chapter.normalizedNumber(current.number).flatMap { Decimal(string: $0, locale: locale) }
        let ascending = target.map { $0 < (currentNumber ?? $0) } ?? false
        var offset: Int? = 0
        if !loading, failure == nil {
            if nextOffset == nil || request.ascending == ascending { offset = nextOffset }
        }

        do {
            if offset != nil {
                let info = try await manga.provider.series(manga.slug)
                while let start = offset {
                    try Task.checkCancellation()
                    let page = try await manga.provider.chapters(info, offset: start, ascending: ascending)
                    try Task.checkCancellation()
                    if let match = page.items.first(where: {
                        $0.slug == manga.slug && Chapter.normalizedNumber($0.number) == number
                    }) {
                        select(library.readingRelease(match))
                        return
                    }
                    offset = page.nextOffset.flatMap { $0 > start ? $0 : nil }
                }
            }
            lookupIssue = .notFound(number)
            ShelfHaptics.warning.play()
        } catch {
            if !Task.isCancelled {
                lookupIssue = .failed(SourceLoadFailure(error))
                ShelfHaptics.error.play()
            }
        }
    }

    private static func numericInput(_ text: String) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        return String(text.compactMap { character -> Character? in
            if character == "." || character == "," || String(character) == separator { return "." }
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            return Character(String(digit))
        })
    }

}

extension Chapter {
    static func normalizedNumber(_ value: String) -> String? {
        var number = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if number.hasPrefix("chapter ") { number = String(number.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        if number == "oneshot" { return number }
        number = number.replacingOccurrences(of: ",", with: ".")
        guard number.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }

        let parts = number.split(separator: ".")
        let digits = parts[0].drop(while: { $0 == "0" })
        let whole = digits.isEmpty ? "0" : String(digits)
        if parts.count == 2 {
            let fraction = String(parts[1].reversed().drop(while: { $0 == "0" }).reversed())
            return fraction.isEmpty ? whole : "\(whole).\(fraction)"
        }
        return ([whole] + parts.dropFirst().map(String.init)).joined(separator: ".")
    }
}
