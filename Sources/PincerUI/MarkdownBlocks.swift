import Foundation

/// Block-level Markdown (headings, lists, quotes, fenced code, rules), with inline styling left
/// to Foundation's parser. Enough for agent output without a third-party dependency.
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
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        if self.inlineCache.count > 6000 { self.inlineCache.removeAll(keepingCapacity: true) }
        self.inlineCache[text] = parsed
        return parsed
    }
}

