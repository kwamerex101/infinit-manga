import SwiftUI

struct MangaAgentView: View {
    @Environment(ReadingStore.self) private var library
    let agent: MangaAgent
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 62
    @State private var confirmingClearChat = false
    @FocusState private var composing: Bool

    private let suggestions = [
        ("sparkles", "Suggest manga based on my recent reads"),
        ("figure.martial.arts", "Find completed full-color martial arts manga"),
        ("moon.stars", "Show me completed supernatural manga"),
        ("magnifyingglass", "Tell me about Vinland Saga")
    ]

    private var question: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    if agent.turns.isEmpty {
                        welcome
                    } else {
                        transcript
                    }
                }
                .contentMargins(.bottom, composerHeight, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: agent.turns.last?.id) { _, id in
                    guard let id else { return }
                    proxy.scrollTo("question-\(id)", anchor: .top)
                }
                .onChange(of: agent.turns.last?.reply != nil) {
                    if let turn = agent.turns.last, turn.reply != nil {
                        proxy.scrollTo("question-\(turn.id)", anchor: .top)
                    }
                }
                .overlay(alignment: .bottom) {
                    composer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            composerHeight = height
                        }
                }
            }
        }
        .background(Color.papertrailBackground)
        .alert("Clear this chat?", isPresented: $confirmingClearChat) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat", role: .destructive) {
                composing = false
                draft = ""
                agent.reset()
            }
        } message: {
            if agent.turns.isEmpty {
                Text("Your unsent draft will be deleted.")
            } else if draft.isEmpty {
                Text("This will remove your messages and the Agent’s replies from this chat.")
            } else {
                Text("This will remove your messages, the Agent’s replies, and your unsent draft from this chat.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(.brandMark)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text("Manga Agent")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                confirmingClearChat = true
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear chat")
            .disabled(agent.turns.isEmpty && draft.isEmpty)
            .opacity(agent.turns.isEmpty && draft.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.papertrailStroke).frame(height: 1)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 25) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What do you\nwant to read?")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Ask for recommendations or look up a series.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.1) { icon, prompt in
                    Divider()
                    Button {
                        send(prompt)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: icon)
                                .foregroundStyle(Color.papertrailDetail)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(prompt)
                                .font(.subheadline.weight(.medium))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 10)
                            Image(systemName: "arrow.up.left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ShelfPressStyle())
                }
                Divider()
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 19) {
            ForEach(agent.turns) { turn in
                Text(turn.question)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.papertrailFeature, in: .rect(cornerRadius: 17))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("You: \(turn.question)")
                    .id("question-\(turn.id)")

                if let reply = turn.reply {
                    VStack(alignment: .leading, spacing: 13) {
                        AgentMarkdownView(reply.answer)
                            .font(.body)
                            .textSelection(.enabled)
                        if !reply.titles.isEmpty {
                            Text("Catalog data from MangaDex")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(reply.titles) { title in
                        NavigationLink(value: title.manga) {
                            titleRow(title)
                        }
                        .buttonStyle(ShelfPressStyle())
                    }
                } else if turn.failed {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Couldn’t reach the manga catalog.")
                        if agent.turns.last?.id == turn.id {
                            Button("Try again") { agent.retry() }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    SkeletonLine(label: "Looking it up", width: 145)
                }
            }
        }
        .frame(maxWidth: 620)
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private func titleRow(_ title: AgentTitle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(url: title.manga.cover, mangaID: title.id)
                .frame(width: 66, height: 92)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title.manga.title)
                    .font(.subheadline.bold())
                if !title.metadata.isEmpty {
                    Text(title.metadata.joined(separator: " • "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.papertrailDetail)
                }
                if !title.synopsis.isEmpty {
                    Text(AgentMarkdownView.excerpt(title.synopsis))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(10)
        .background(Color.papertrailPanel, in: .rect(cornerRadius: 13))
        .contentShape(.rect(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about manga", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($composing)
                .padding(.leading, 13)
                .padding(.vertical, 12)
                .accessibilityIdentifier("agent-message-field")
            Button {
                send(question)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.papertrailOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.papertrailAccent, in: Circle())
            }
            .buttonStyle(ShelfPressStyle())
            .disabled(question.isEmpty || agent.waiting)
            .opacity(question.isEmpty || agent.waiting ? 0.42 : 1)
            .accessibilityLabel("Send message")
        }
        .padding(4)
        .background(.thinMaterial, in: .rect(cornerRadius: 27))
        .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(Color.papertrailStroke) }
        .shadow(color: .black.opacity(0.09), radius: 10, y: 3)
        .frame(maxWidth: 620)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
    }

    private func send(_ text: String) {
        guard !text.isEmpty, !agent.waiting else { return }
        draft = ""
        composing = false
        ShelfHaptics.tap.play()
        agent.ask(String(text.prefix(600)), readingHistory: library.recent.map(\.manga))
    }
}
