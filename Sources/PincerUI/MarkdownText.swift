import SwiftUI

/// Block-level Markdown (headings, lists, quotes, fenced code, rules) with inline styling
/// from Foundation's parser. Enough for agent output without a third-party dependency.
struct MarkdownText: View {
    let source: String
    var isSecondary = false

    var body: some View {
        let blocks = MarkdownCache.blocks(self.source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                self.view(for: block)
            }
        }
        .textSelection(.enabled)
        .foregroundStyle(self.isSecondary ? .secondary : .primary)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 2)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Self.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case .rule:
            Divider()
        case let .table(header, alignments, rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        MarkdownCache.inline(text)
    }

    static func parseInline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct MarkdownTableView: View {
    let header: [String]
    let alignments: [MarkdownBlock.Alignment]
    let rows: [[String]]

    var body: some View {
        // Wrap cells to the available width when every column can keep a readable minimum;
        // otherwise fall back to horizontal scrolling at the minimum widths.
        ViewThatFits(in: .horizontal) {
            self.table(fillsWidth: true)
            ScrollView(.horizontal, showsIndicators: false) {
                self.table(fillsWidth: false)
            }
        }
    }

    private func table(fillsWidth: Bool) -> some View {
        MarkdownTableLayout(columns: self.header.count, fillsWidth: fillsWidth) {
            ForEach(self.header.indices, id: \.self) { column in
                self.cell(self.header[column], column: column)
                    .fontWeight(.semibold)
                    .background(Theme.codeBackground)
            }
            ForEach(self.rows.indices, id: \.self) { index in
                ForEach(self.header.indices, id: \.self) { column in
                    self.cell(column < self.rows[index].count ? self.rows[index][column] : "", column: column)
                        .overlay(alignment: .top) { Rectangle().fill(.quaternary).frame(height: 1) }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = column < self.alignments.count ? self.alignments[column] : .leading
        let frameAlignment: SwiftUI.Alignment = alignment == .trailing ? .topTrailing : alignment == .center ? .top : .topLeading
        let textAlignment: TextAlignment = alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
        return Text(MarkdownText.inline(text))
            .multilineTextAlignment(textAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }
}

/// Lays out table cells (row-major) with shared column widths so wrapped cells grow their
/// whole row instead of overlapping the next one.
struct MarkdownTableLayout: Layout {
    let columns: Int
    /// When true, columns shrink/wrap to fit the proposed width. When false, columns use
    /// their ideal widths (capped) and the table may be wider than its container.
    let fillsWidth: Bool

    private static let minimumColumn: CGFloat = 72
    private static let maximumColumn: CGFloat = 320

    struct Metrics {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = self.metrics(width: proposal.width, subviews: subviews)
        return CGSize(width: metrics.widths.reduce(0, +), height: metrics.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = self.metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in metrics.heights.indices {
            var x = bounds.minX
            for column in 0..<self.columns {
                let index = row * self.columns + column
                guard index < subviews.count else { return }
                let size = CGSize(width: metrics.widths[column], height: metrics.heights[row])
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += metrics.heights[row]
        }
    }

    private func metrics(width available: CGFloat?, subviews: Subviews) -> Metrics {
        guard self.columns > 0 else { return Metrics(widths: [], heights: []) }
        var ideals = Array(repeating: CGFloat(0), count: self.columns)
        for (index, subview) in subviews.enumerated() {
            let column = index % self.columns
            ideals[column] = max(ideals[column], ceil(subview.sizeThatFits(.unspecified).width))
        }
        ideals = ideals.map { min($0, Self.maximumColumn) }
        let minimums = ideals.map { min($0, Self.minimumColumn) }

        var widths = ideals
        if self.fillsWidth {
            // A nil width is an ideal-size query (e.g. from ViewThatFits): report the narrowest
            // readable table so we're chosen whenever the minimums fit.
            let target = available ?? minimums.reduce(0, +)
            let idealTotal = ideals.reduce(0, +)
            let minimumTotal = minimums.reduce(0, +)
            if idealTotal > target {
                let slack = max(0, target - minimumTotal)
                let flexible = idealTotal - minimumTotal
                widths = zip(ideals, minimums).map { ideal, minimum in
                    flexible > 0 ? minimum + (ideal - minimum) / flexible * slack : minimum
                }
                widths = widths.map { floor($0) }
            }
        }

        let rowCount = (subviews.count + self.columns - 1) / self.columns
        var heights = Array(repeating: CGFloat(0), count: rowCount)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index % self.columns], height: nil))
            heights[index / self.columns] = max(heights[index / self.columns], ceil(size.height))
        }
        return Metrics(widths: widths, heights: heights)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.language?.isEmpty == false ? self.language! : "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Clipboard.copy(self.code)
                    self.copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        self.copied = false
                    }
                } label: {
                    Label(self.copied ? "Copied" : "Copy", systemImage: self.copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(self.code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable {
        var text: String
        var indent: Int
    }

    case paragraph(String)
    case heading(Int, String)
    case list([Item], ordered: Bool)
    case quote(String)
    case code(String?, String)
    case rule
    case table(header: [String], alignments: [Alignment], rows: [[String]])

    enum Alignment: Equatable { case leading, center, trailing }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [Item] = []
        var listOrdered = false
        var quote: [String] = []
        var code: [String]?
        var codeLanguage: String?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(listItems, ordered: listOrdered))
                listItems.removeAll()
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote.removeAll()
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            index += 1
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(codeLanguage, code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(rawLine)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                    flushAll()
                    blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1))))
                    continue
                }
            }
            if code == nil, trimmed.contains("|"), index < lines.count,
               let alignments = Self.tableAlignments(lines[index]) {
                let header = Self.tableCells(trimmed)
                if header.count == alignments.count {
                    flushAll()
                    index += 1
                    var rows: [[String]] = []
                    while index < lines.count {
                        let next = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !next.isEmpty, next.contains("|") else { break }
                        rows.append(Self.tableCells(next))
                        index += 1
                    }
                    blocks.append(.table(header: header, alignments: alignments, rows: rows))
                    continue
                }
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if let item = Self.bullet(trimmed) {
                flushParagraph()
                flushQuote()
                if listItems.isEmpty { listOrdered = false }
                listItems.append(Item(text: item, indent: indent))
                continue
            }
            if let item = Self.numbered(trimmed) {
                flushParagraph()
                flushQuote()
                if listItems.isEmpty { listOrdered = true }
                listItems.append(Item(text: item, indent: indent))
                continue
            }
            if !listItems.isEmpty, indent > 0 {
                listItems[listItems.count - 1].text += " " + trimmed
                continue
            }
            flushList()
            flushQuote()
            paragraph.append(line)
        }
        if let code { blocks.append(.code(codeLanguage, code.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    static func tableCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for char in body {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Alignments from a GFM delimiter row like `|:---|--:|:-:|`, or nil if the line isn't one.
    static func tableAlignments(_ line: String) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.contains(":") else { return nil }
        var alignments: [Alignment] = []
        for cell in Self.tableCells(trimmed) {
            let leading = cell.hasPrefix(":"), trailing = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return alignments
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = String(line.dropFirst(2))
            if rest.hasPrefix("[ ] ") { return "☐ " + rest.dropFirst(4) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return "☑ " + rest.dropFirst(4) }
            return rest
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

/// Parsing markdown on every render made long transcripts stutter while scrolling.
@MainActor
enum MarkdownCache {
    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let cached = self.blockCache[source] { return cached }
        let blocks = MarkdownBlock.parse(source)
        if self.blockCache.count > 1500 { self.blockCache.removeAll(keepingCapacity: true) }
        self.blockCache[source] = blocks
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        if let cached = self.inlineCache[text] { return cached }
        let parsed = MarkdownText.parseInline(text)
        if self.inlineCache.count > 6000 { self.inlineCache.removeAll(keepingCapacity: true) }
        self.inlineCache[text] = parsed
        return parsed
    }
}
