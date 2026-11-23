import SwiftUI

@MainActor
@Observable
final class NovelAgent {
    enum Topic: String, CaseIterable {
        case adaptations = "Find novels from my manga library"
        case cultivation = "Find wuxia and cultivation novels"
        case chinese = "Find Chinese action novels"
        case japanese = "Find Japanese action novels"
        case action = "Find action and martial arts novels"

        init?(question: String) {
            let question = question.lowercased()
            if let exact = Self.allCases.first(where: { $0.rawValue.lowercased() == question }) {
                self = exact
            } else if question.contains("manga library") || question.contains("my manga") || question.contains("my manhwa") {
                self = .adaptations
            } else if question.contains("japanese") {
                self = .japanese
            } else if question.contains("chinese") {
                self = .chinese
            } else if ["wuxia", "xianxia", "cultivation"].contains(where: question.contains),
                      !question.hasPrefix("is "), !question.contains("chapter") {
                self = .cultivation
            } else if ["recommend", "suggest", "find", "show me"].contains(where: question.contains),
                      ["martial arts", "action novels", "murim"].contains(where: question.contains) {
                self = .action
            } else {
                return nil
            }
        }

        var candidateTitles: [String] {
            switch self {
            case .adaptations, .action: []
            case .cultivation: ["A Regressor’s Tale of Cultivation", "The Tale of Cultivation and Demon Extermination"]
            case .chinese: ["The Tale of Cultivation and Demon Extermination"]
            case .japanese: ["Mushoku Tensei", "Tensei Shitara Slime Datta Ken"]
            }
        }

        var genreIDs: [String] {
            switch self {
            case .cultivation: ["56", "68", "718", "1365"]
            case .action: ["5", "56"]
            default: []
            }
        }
    }

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var novels: [Novel] = []
    }

    private(set) var turns: [Turn] = []
    private var task: Task<Void, Never>?
    private(set) var waiting = false

    func ask(_ question: String, sources: [NovelSource], manga: [Manga]) {
        guard !waiting else { return }
        let turn = Turn(question: question)
        turns.append(turn)
        waiting = true
        task = Task { [weak self] in
            let reply = await Self.reply(question, sources: sources, manga: manga)
            guard let self, !Task.isCancelled, turns.last?.id == turn.id, let index = turns.indices.last else { return }
            turns[index].answer = reply.0
            turns[index].novels = reply.1
            waiting = false
            task = nil
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        turns.removeAll()
        waiting = false
    }

    private static func reply(_ question: String, sources: [NovelSource], manga: [Manga]) async -> (String, [Novel]) {
        guard !sources.isEmpty else { return ("Enable a provider in Novel Settings to look up novels.", []) }
        let topic = Topic(question: question)
        if topic == .adaptations, manga.isEmpty {
            return ("Save or read a manga title first, or ask for its novel by name.", [])
        }

        var names: [String] = []
        var candidates: [Novel] = []
        var failures = Set<NovelSource>()
        if topic == .adaptations {
            var keys = Set<String>()
            names = Array(manga.map(\.title).filter { keys.insert(Novel.titleKey($0)).inserted }.prefix(5))
        } else if let topic {
            names = topic.candidateTitles
            if !topic.genreIDs.isEmpty {
                let genres = topic.genreIDs
                let result = await NovelCatalog.collect(sources) { try await $0.discover(genres: genres) }
                failures.formUnion(result.failed)
                candidates = result.items.filter { novel in
                    novel.provider == .roliaScan || novel.genres.contains("Action")
                        || novel.genres.contains("Martial Arts")
                        || novel.synopsis.localizedCaseInsensitiveContains("Murim")
                }
            }
        } else {
            let title = searchTitle(question)
            if title.isEmpty { return ("Enter a novel or comic title, or choose a discovery prompt.", []) }
            names = [title]
        }

        for name in names {
            if Task.isCancelled { return ("", []) }
            let result = await NovelCatalog.collect(sources) { try await $0.search(name) }
            failures.formUnion(result.failed)
            let exact = result.items.filter { $0.titleKeys.contains(Novel.titleKey(name)) }
            let matches = topic != nil || !exact.isEmpty ? exact : result.items
            candidates.insert(contentsOf: matches, at: 0)
        }

        let preview = Array(NovelCatalog.unique(candidates).prefix(10))
        let available = await withTaskGroup(of: (Int, Novel?).self) { group in
            for (index, novel) in preview.enumerated() {
                group.addTask {
                    guard let details = try? await novel.provider.details(novel),
                          details.chapters.contains(where: { !$0.locked }) else { return (index, nil) }
                    return (index, details.novel)
                }
            }
            var checked: [(Int, Novel)] = []
            for await (index, novel) in group {
                if let novel { checked.append((index, novel)) }
            }
            return checked.sorted { $0.0 < $1.0 }.prefix(6).map(\.1)
        }
        guard !available.isEmpty else {
            if !failures.isEmpty {
                return ("I couldn’t confirm a match. Sources unavailable: \(failures.map(\.name).sorted().joined(separator: ", ")).", [])
            }
            return ("I couldn’t find a matching novel with an available chapter. Try another title or topic.", [])
        }
        let answer = topic == .adaptations
            ? "These novel listings match titles or alternate titles in your manga library. Open a listing to check the edition and chapters."
            : "I found these novel listings with available chapters on your enabled sources."
        return (answer, available)
    }

    private static func searchTitle(_ question: String) -> String {
        question.replacingOccurrences(of: #"^(?:(?:is there|find|show me|look up|tell me about|do you have)\s+)?(?:(?:a|the)\s+)?(?:(?:light |web )?novel (?:version|adaptation) (?:of|for)\s+|(?:a |the )?novel (?:for|of)\s+)?"#,
                                      with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(?:(?:light |web )?novel|novel adaptation)\s*[?!.]*$"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"?!")))
    }
}

struct NovelAgentView: View {
    @Environment(NovelLibrary.self) private var library
    @Environment(ReadingStore.self) private var mangaLibrary
    let agent: NovelAgent
    @State private var draft = ""
    @State private var clearing = false
    @FocusState private var composing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ShelfMasthead(title: "Novel Agent")
                Button("Clear chat", systemImage: "trash") { clearing = true }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .disabled(agent.turns.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if agent.turns.isEmpty {
                            Text("Look up a title or find novels you can read from your enabled sources.")
                                .foregroundStyle(.secondary)
                            ForEach(NovelAgent.Topic.allCases, id: \.self) { topic in
                                Button { send(topic.rawValue) } label: {
                                    Label(topic.rawValue, systemImage: "sparkle.magnifyingglass")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        ForEach(agent.turns) { turn in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(turn.question)
                                    .padding(10)
                                    .background(Color.papertrailPanel, in: .rect(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .accessibilityLabel("You: \(turn.question)")
                                if let answer = turn.answer {
                                    Text(answer).foregroundStyle(.secondary)
                                    ForEach(turn.novels) { novel in
                                        NavigationLink(value: novel) {
                                            HStack(spacing: 11) {
                                                CoverView(url: novel.cover, mangaID: novel.id)
                                                    .frame(width: 40, height: 55)
                                                    .accessibilityHidden(true)
                                                VStack(alignment: .leading) {
                                                    Text(novel.title).font(.subheadline.weight(.semibold))
                                                    Text("Novel · \(novel.provider.name)")
                                                        .font(.caption).foregroundStyle(Color.papertrailDetail)
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right").font(.caption)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("novel-agent-result-\(novel.slug)")
                                    }
                                } else {
                                    SkeletonLine(label: "Checking the catalog", width: 145)
                                }
                            }
                            .id(turn.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: agent.turns.last?.id) {
                    if let id = agent.turns.last?.id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            HStack {
                TextField("Ask about a novel", text: $draft)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit { send(draft) }
                    .accessibilityIdentifier("novel-agent-field")
                Button("Send", systemImage: "arrow.up.circle.fill") { send(draft) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.waiting)
            }
            .padding(10)
            .background(Color.papertrailPanel, in: .rect(cornerRadius: 12))
        }
        .padding(18)
        .alert("Clear this Novel Agent chat?", isPresented: $clearing) {
            Button("Cancel", role: .cancel) {}
            Button("Clear chat", role: .destructive) { agent.clear() }
        }
    }

    private func send(_ message: String) {
        let question = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !agent.waiting else { return }
        composing = false
        draft = ""
        let manga = mangaLibrary.recent.map(\.manga) + mangaLibrary.bookmarks + mangaLibrary.readLater
        agent.ask(question, sources: library.enabledSources, manga: manga)
    }
}
