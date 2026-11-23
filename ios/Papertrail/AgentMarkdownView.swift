import SwiftUI

struct AgentMarkdownView: View {
    private let blocks: [Block]

    init(_ markdown: String) {
        blocks = Self.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                if let table = blocks[index].table {
                    if index == 0 || blocks[index - 1].table?.identity != table.identity {
                        tableView(table, from: index)
                    }
                } else {
                    let previous = index > 0 ? blocks[index - 1] : nil
                    blockView(blocks[index], previous: previous)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(.papertrailDetail)
    }

    static func excerpt(_ markdown: String) -> AttributedString {
        let blocks = parse(markdown)
        var text = blocks.first { $0.kind == .paragraph }?.text
            ?? blocks.first { $0.kind != .thematicBreak }?.text
            ?? AttributedString()
        text.link = nil
        return text
    }

    private struct Block {
        let components: [PresentationIntent.IntentType]
        var text: AttributedString

        var kind: PresentationIntent.Kind? { components.first?.kind }

        var item: (identity: Int, label: String)? {
            guard let index = components.firstIndex(where: {
                if case .listItem = $0.kind { return true }
                return false
            }), case .listItem(let ordinal) = components[index].kind else { return nil }
            let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
            return (components[index].identity, ordered ? "\(ordinal)." : "•")
        }

        var listDepth: Int {
            components.count { $0.kind == .orderedList || $0.kind == .unorderedList }
        }

        var table: (identity: Int, columns: Int)? {
            for component in components {
                if case .table(let columns) = component.kind { return (component.identity, columns.count) }
            }
            return nil
        }

        var tableRow: PresentationIntent.IntentType? {
            components.first {
                switch $0.kind {
                case .tableHeaderRow, .tableRow: return true
                default: return false
                }
            }
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)),
              !parsed.characters.isEmpty else {
            return markdown.isEmpty ? [] : [Block(components: [], text: AttributedString(markdown))]
        }

        var blocks: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            var fragment = AttributedString(parsed[run.range])
            fragment.presentationIntent = nil
            if let link = run.link,
               link.host == nil || !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                fragment.link = nil
            }
            if let last = blocks.indices.last, blocks[last].components == components {
                blocks[last].text += fragment
            } else {
                blocks.append(Block(components: components, text: fragment))
            }
        }
        return blocks
    }

    private func blockView(_ block: Block, previous: Block?) -> some View {
        let quoted = block.components.contains { $0.kind == .blockQuote }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let item = block.item {
                Text(item.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(previous?.item?.identity == item.identity ? 0 : 1)
                    .accessibilityHidden(true)
            }
            blockContent(block)
        }
        .padding(.leading, CGFloat(min(4, max(0, block.listDepth - 1))) * 16 + (quoted ? 12 : 0))
        .overlay(alignment: .leading) {
            if quoted {
                Capsule()
                    .fill(Color.papertrailStroke)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func blockContent(_ block: Block) -> some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font(level <= 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
        case .thematicBreak:
            Rectangle()
                .fill(Color.papertrailStroke)
                .frame(height: 1)
                .padding(.vertical, 3)
                .accessibilityHidden(true)
        case .codeBlock:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .background(Color.papertrailPanel, in: .rect(cornerRadius: 8))
        default:
            Text(block.text)
        }
    }

    private func tableView(_ table: (identity: Int, columns: Int), from index: Int) -> some View {
        let cells = blocks[index...].prefix { $0.table?.identity == table.identity }
        let rows = Dictionary(grouping: cells) { $0.tableRow?.identity ?? 0 }
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                ForEach(rows.keys.sorted(), id: \.self) { row in
                    if let cells = rows[row] {
                        tableRow(cells, columns: table.columns)
                        if cells.first?.tableRow?.kind == .tableHeaderRow {
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.papertrailPanel, in: .rect(cornerRadius: 8))
    }
    private func tableRow(_ cells: [Block], columns: Int) -> some View {
        let font: Font = cells.first?.tableRow?.kind == .tableHeaderRow ? .subheadline.bold() : .subheadline
        return GridRow(alignment: .top) {
            ForEach(0..<columns, id: \.self) { column in
                let cell = cells.first { $0.kind == .tableCell(columnIndex: column) }
                Text(cell?.text ?? AttributedString())
                    .font(font)
                    .frame(minWidth: 36, maxWidth: 240, alignment: .leading)
            }
        }
    }

}
