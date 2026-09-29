import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Formatted presentations of expanded tool calls, so a relayout doesn't parse them again.
@MainActor
enum ToolPresentationCache {
    private final class Box {
        let value: ToolCallPresentation
        init(_ value: ToolCallPresentation) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    static func presentation(for tool: ToolActivity) -> ToolCallPresentation {
        let key = "\(tool.id)|\(tool.arguments?.utf8.count ?? -1)|\(tool.result?.utf8.count ?? -1)|\(tool.isError)|\(tool.isRunning)|\(tool.details != nil)" as NSString
        if let cached = self.cache.object(forKey: key) { return cached.value }
        let value = ToolCallPresentation.make(tool, limit: TranscriptMetrics.toolOutputLimit)
        self.cache.setObject(Box(value), forKey: key)
        return value
    }
}

/// Header text of a tool card, split cheaply from the name (no parsing): an MCP tool is
/// `server__tool` or `mcp__server__tool`.
struct ToolCardName {
    let server: String?
    let tool: String

    init(_ name: String) {
        var rest = Substring(name)
        if rest.hasPrefix("mcp__") { rest = rest.dropFirst(5) }
        if let range = rest.range(of: "__", options: .backwards), range.lowerBound > rest.startIndex, range.upperBound < rest.endIndex {
            self.server = String(rest[..<range.lowerBound])
            self.tool = String(rest[range.upperBound...])
        } else {
            self.server = nil
            self.tool = name
        }
    }
}

extension TranscriptPart.Tool.Face {
    @MainActor func font(_ style: TranscriptStyle) -> PFont {
        switch self {
        case .caption: style.caption
        case .captionSemibold: style.captionSemibold
        case .captionMono: style.captionMono
        case .caption2Medium: style.caption2Medium
        case .code: style.code
        }
    }
}

extension TranscriptPart.Tool.Tone {
    @MainActor var color: PColor {
        switch self {
        case .label: TranscriptColors.label
        case .secondary: TranscriptColors.secondary
        case .tertiary: TranscriptColors.tertiary
        case .ok: TranscriptColors.ok
        case .failure: TranscriptColors.failure
        case .fill: TranscriptColors.fill
        case .strongFill: TranscriptColors.strongFill
        case .terminal: TranscriptColors.codeBackground
        }
    }

    /// Background of a badge in this tone.
    @MainActor var badgeFill: PColor {
        switch self {
        case .ok: self.color.withAlphaComponent(0.12)
        case .failure: self.color.withAlphaComponent(0.14)
        default: TranscriptColors.strongFill
        }
    }
}

private struct ToolCardBuild {
    var y: CGFloat
    let x: CGFloat = 10
    let inner: CGFloat
    var sections: [TranscriptPart.Tool.Section] = []
    var decor: [TranscriptPart.Tool.Decor] = []
    var controls: [TranscriptPart.Tool.Control] = []
    var notes: [TranscriptPart.Tool.Note] = []
    var matchY: CGFloat?
    var placedAny = false

    /// Space before the next block, except above the first.
    mutating func gap(_ amount: CGFloat = 8) {
        if self.placedAny { self.y += amount }
        self.placedAny = true
    }
}

/// Lines of the output shown before "Show all".
private let toolOutputPreviewLines = 12

extension TranscriptLayoutBuilder {
    func tool(_ tool: ToolActivity, first: Bool, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "tool:\(tool.id)"
        let edit = tool.fileEdit
        // A diff is the point of an edit card, so it starts open; long ones start cut short.
        let expanded = self.context.disclosure.isExpanded(key, default: edit != nil)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = 6 + max(TranscriptStyle.lineHeight(self.style.calloutMonoMedium), TranscriptMetrics.iconBox) + 6
        let run = self.spawnedRun(tool)
        if tool.spawnedSessionKey != nil || tool.spawnLabel != nil { layout.hasSpawns = true }
        if let run { layout.runs[tool.id] = run }
        var sections: [TranscriptPart.Tool.Section] = []
        var runningY: CGFloat?
        var toolMatchY: CGFloat?
        var diff: TranscriptPart.Tool.Diff?
        var decor: [TranscriptPart.Tool.Decor] = []
        var controls: [TranscriptPart.Tool.Control] = []
        var notes: [TranscriptPart.Tool.Note] = []
        var height = headerHeight
        if expanded, let edit {
            var y = headerHeight + 1 + 10
            let inner = max(width - 20, 20)
            let titleHeight = TranscriptStyle.lineHeight(self.style.captionSemibold)
            let placed = self.diff(edit, tool: tool, row: layout.id, width: width, y: y)
            sections.append(placed.section)
            diff = placed.diff
            if let match = placed.match {
                toolMatchY = placed.section.frame.minY
                    + min(self.marks.lineBottom(of: match, in: placed.section.text, width: inner), placed.section.frame.height)
            }
            y = placed.bottom
            var hasOutput = false
            if let result = tool.result, !result.isEmpty {
                hasOutput = true
                y += 8
                let limited = result.count > TranscriptMetrics.toolOutputLimit
                    ? String(result.prefix(TranscriptMetrics.toolOutputLimit)) + "\n…" : result
                let (text, match) = self.marks.mark(
                    TranscriptText.plain(limited, font: self.style.captionMono, color: TranscriptColors.label), .tool(tool.id))
                let contentHeight = TranscriptText.size(text, width: inner).height
                let visible = min(contentHeight, TranscriptMetrics.toolOutputMaxHeight)
                let titleY = y
                y += titleHeight + 4
                if let match {
                    toolMatchY = y + min(self.marks.lineBottom(of: match, in: text, width: inner), visible)
                }
                sections.append(.init(title: tool.isError ? L("Error") : L("Output"), titleY: titleY, text: text,
                                      frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight))
                y += visible
            }
            if !hasOutput, tool.isRunning {
                y += 8
                runningY = y
                y += TranscriptStyle.lineHeight(self.style.caption)
            }
            height = y + 10
        } else if expanded {
            var card = ToolCardBuild(y: headerHeight + 1 + 10, inner: max(width - 20, 20))
            runningY = self.toolCard(tool, row: layout.id, into: &card)
            sections = card.sections
            decor = card.decor
            controls = card.controls
            notes = card.notes
            toolMatchY = card.matchY
            height = card.y + 10
        }
        let part = TranscriptPart.Tool(tool: tool, key: key, isExpanded: expanded, run: run, headerHeight: headerHeight,
                                       sections: sections, runningY: runningY, edit: edit, diff: diff,
                                       decor: decor, controls: controls, notes: notes)
        stack.add(.tool(part), height: height, width: width, spacing: first ? TranscriptMetrics.blockSpacing : TranscriptMetrics.toolSpacing)
        if let toolMatchY, let frame = stack.parts.last?.frame { layout.matchY = frame.minY + toolMatchY }
    }

    /// Lays out the body of a non-edit card. Returns where "Running…" goes, if it should show.
    private func toolCard(_ tool: ToolActivity, row: String, into card: inout ToolCardBuild) -> CGFloat? {
        let presentation = ToolPresentationCache.presentation(for: tool)
        // Find counts the formatted text, so while it has matches in this row nothing is raw or cut short.
        let finding = self.highlight.isActive && self.highlight.options.includeTools && self.highlight.rows.contains(row)
        let hasRaw = presentation.rawArguments != nil
            || presentation.rawResult.map { $0 != presentation.output?.text && !$0.isEmpty } ?? false
        let rawKey = "raw:\(tool.id)"
        let showsRaw = !finding && hasRaw && self.context.disclosure.isExpanded(rawKey, default: false)
        var runningY: CGFloat?
        if showsRaw {
            self.rawBody(presentation, tool: tool, into: &card)
        } else {
            runningY = self.formattedBody(presentation, tool: tool, finding: finding, into: &card)
        }
        if hasRaw, !finding {
            card.gap()
            let title = showsRaw ? L("Show formatted") : L("Show raw JSON")
            let size = TranscriptLabelButton.size(title: title)
            let width = max(size.width, TranscriptLabelButton.size(title: L("Show raw JSON")).width,
                            TranscriptLabelButton.size(title: L("Show formatted")).width)
            card.controls.append(.init(id: "raw", title: title, symbol: showsRaw ? "text.alignleft" : "curlybraces",
                                       frame: CGRect(x: card.x + card.inner - width, y: card.y, width: width, height: size.height),
                                       action: .toggle(key: rawKey, to: !showsRaw), spoken: title, trailing: true))
            card.y += size.height
        }
        return runningY
    }

    private func formattedBody(_ presentation: ToolCallPresentation, tool: ToolActivity, finding: Bool,
                               into card: inout ToolCardBuild) -> CGFloat?
    {
        if let headline = presentation.headline, !headline.isEmpty {
            card.gap(8)
            self.headline(headline, kind: presentation.kind, tool: tool, into: &card)
        }
        let chips = presentation.chips.filter { $0.symbol != "server.rack" }
        if !chips.isEmpty {
            card.gap(6)
            self.chips(chips, into: &card)
        }
        if let argumentsText = presentation.argumentsText, !argumentsText.isEmpty {
            card.gap(8)
            self.inputTitle(into: &card)
            let body = self.keyValueText(presentation.arguments, text: argumentsText, inner: card.inner)
            card.y += self.textSection("\(tool.id):arguments", body, tool: tool, x: card.x, width: card.inner,
                                       maxHeight: TranscriptMetrics.toolOutputMaxHeight, into: &card)
        } else if presentation.rawArguments == nil, let plain = tool.arguments, !plain.isEmpty {
            // Arguments that aren't a JSON object; Find doesn't count them.
            card.gap(8)
            self.inputTitle(into: &card)
            let text = plain.count > TranscriptMetrics.toolOutputLimit ? String(plain.prefix(TranscriptMetrics.toolOutputLimit)) + "\n…" : plain
            card.y += self.textSection("\(tool.id):arguments", TranscriptText.plain(text, font: self.style.captionMono, color: TranscriptColors.label),
                                       tool: tool, x: card.x, width: card.inner, maxHeight: TranscriptMetrics.toolOutputMaxHeight,
                                       searchable: false, into: &card)
        }
        if let output = presentation.output {
            card.gap(8)
            self.output(output, kind: presentation.kind, finding: finding, tool: tool, into: &card)
            return nil
        }
        guard tool.isRunning else { return nil }
        card.gap(8)
        let y = card.y
        card.y += TranscriptStyle.lineHeight(self.style.caption)
        return y
    }

    /// The old view: the arguments and the result as the gateway sent them.
    private func rawBody(_ presentation: ToolCallPresentation, tool: ToolActivity, into card: inout ToolCardBuild)
    {
        let font = self.style.captionMono
        func limited(_ text: String) -> String {
            text.count > TranscriptMetrics.toolOutputLimit ? String(text.prefix(TranscriptMetrics.toolOutputLimit)) + "\n…" : text
        }
        if let raw = presentation.rawArguments, !raw.isEmpty {
            card.gap(8)
            self.inputTitle(into: &card)
            card.y += self.textSection("\(tool.id):raw-arguments", TranscriptText.plain(limited(raw), font: font, color: TranscriptColors.label),
                                       tool: tool, x: card.x, width: card.inner, maxHeight: TranscriptMetrics.toolOutputMaxHeight,
                                       searchable: false, into: &card)
        }
        if let result = presentation.rawResult, !result.isEmpty {
            card.gap(8)
            let failed = tool.isError
            self.titleRow(failed ? L("Error") : L("Output"), failed: failed, badges: [], copy: result, into: &card)
            card.y += 4
            card.y += self.textSection("\(tool.id):raw-result",
                                       TranscriptText.plain(limited(result), font: font, color: failed ? TranscriptColors.failure : TranscriptColors.label),
                                       tool: tool, x: card.x, width: card.inner, maxHeight: TranscriptMetrics.toolOutputMaxHeight,
                                       searchable: false, into: &card)
        }
    }

    private func textSection(_ id: String, _ string: NSAttributedString, tool: ToolActivity, x: CGFloat, width: CGFloat,
                             maxHeight: CGFloat, searchable: Bool = true, into card: inout ToolCardBuild) -> CGFloat
    {
        let (text, match) = searchable ? self.marks.mark(string, .tool(tool.id)) : (string, nil)
        let contentHeight = TranscriptText.size(text, width: width).height
        let visible = min(contentHeight, maxHeight)
        if let match {
            card.matchY = card.y + min(self.marks.lineBottom(of: match, in: text, width: width), visible)
        }
        card.sections.append(.init(title: "", titleY: 0, text: text,
                                   frame: CGRect(x: x, y: card.y, width: width, height: visible),
                                   contentHeight: contentHeight, id: id))
        return visible
    }

    private var titleRowHeight: CGFloat { max(TranscriptStyle.lineHeight(self.style.captionSemibold), 16) }

    private func inputTitle(into card: inout ToolCardBuild) {
        let font = self.style.captionSemibold
        card.decor.append(.label(L("Input"), CGPoint(x: card.x, y: card.y + (self.titleRowHeight - TranscriptStyle.lineHeight(font)) / 2),
                                 width: card.inner, .captionSemibold, .secondary, truncation: .byTruncatingTail))
        card.y += self.titleRowHeight + 4
    }

    /// The command in a terminal block with a prompt and Copy; other kinds get a symbol and the text.
    private func headline(_ headline: String, kind: ToolCallPresentation.Kind, tool: ToolActivity, into card: inout ToolCardBuild) {
        let style = self.style
        let font = style.captionMono
        if kind == .exec {
            let padX: CGFloat = 10
            let padY: CGFloat = 8
            let prompt = "$ "
            let promptWidth = singleLine(prompt, font, TranscriptColors.tertiary).lineWidth
            let copy = TranscriptLabelButton.size(title: "")
            let textX = card.x + padX + promptWidth
            let textWidth = max(card.inner - padX - promptWidth - 34, 20)
            let top = card.y
            card.y += padY
            let textTop = card.y
            let attributed = TranscriptText.plain(headline, font: font, color: TranscriptColors.label)
            let visible = self.textSection("\(tool.id):command", attributed, tool: tool, x: textX, width: textWidth,
                                           maxHeight: TranscriptStyle.lineHeight(font) * 10, into: &card)
            let blockHeight = padY + max(visible, TranscriptStyle.lineHeight(font)) + padY
            card.decor.append(.block(CGRect(x: card.x, y: top, width: card.inner, height: blockHeight), .terminal, stroke: nil))
            card.decor.append(.label(prompt, CGPoint(x: card.x + padX, y: textTop), width: promptWidth + 2, .captionMono, .tertiary,
                                     truncation: .byClipping))
            card.controls.append(.init(id: "copy-command", title: "", symbol: "doc.on.doc",
                                       frame: CGRect(x: card.x + card.inner - padX - copy.width, y: top + 7, width: copy.width, height: copy.height),
                                       action: .copy(headline), spoken: L("Copy command"), trailing: true, iconOnly: true))
            card.y = top + blockHeight
        } else {
            let symbol = switch kind {
            case .read: "doc.text"
            case .webFetch: "globe"
            case .webSearch: "magnifyingglass"
            default: "chevron.right"
            }
            let lineHeight = TranscriptStyle.lineHeight(font)
            let attributed = TranscriptText.plain(headline, font: font,
                                                  color: kind == .webFetch ? TranscriptColors.link : TranscriptColors.label)
            let top = card.y
            let visible = self.textSection("\(tool.id):headline", attributed, tool: tool, x: card.x + 20, width: max(card.inner - 20, 20),
                                           maxHeight: lineHeight * 2, into: &card)
            card.decor.append(.symbol(symbol, CGRect(x: card.x, y: top, width: 16, height: lineHeight), .secondary))
            card.y = top + visible
        }
    }

    private func chips(_ chips: [ToolCallPresentation.Chip], into card: inout ToolCardBuild) {
        let style = self.style
        let font = style.caption
        let height = TranscriptStyle.lineHeight(font) + 4
        var x = card.x
        let startY = card.y
        var spoken: [String] = []
        for chip in chips {
            let (value, said) = Self.chipText(chip)
            let text = singleLine(value, font, TranscriptColors.secondary)
            let textWidth = min(text.lineWidth, 240)
            let width = min(6 + 10 + 4 + textWidth + 6, card.inner)
            if x > card.x, x + width > card.x + card.inner {
                x = card.x
                card.y += height + 4
            }
            let rect = CGRect(x: x, y: card.y, width: width, height: height)
            card.decor.append(.pill(rect, .strongFill))
            card.decor.append(.symbol(ToolSymbols.chipSymbol(chip.symbol), CGRect(x: rect.minX + 6, y: rect.minY, width: 10, height: height), .secondary))
            card.decor.append(.label(value, CGPoint(x: rect.minX + 20, y: rect.minY + 2), width: max(width - 26, 1),
                                     .caption, .secondary, truncation: .byTruncatingMiddle))
            spoken.append("\(Self.chipLabel(chip.label)) \(said)")
            x += width + 6
        }
        card.y += height
        card.notes.append(.init(frame: CGRect(x: card.x, y: startY, width: card.inner, height: card.y - startY),
                                text: spoken.joined(separator: ", ")))
    }

    /// A chip's text as drawn and as spoken: `~` for the home folder, "30 s timeout".
    private static func chipText(_ chip: ToolCallPresentation.Chip) -> (String, String) {
        if chip.label == "Working directory" {
            let home = abbreviatedHome(chip.value)
            return (home, chip.value)
        }
        if chip.label == "Timeout", chip.value.hasSuffix("s"), let seconds = Int(chip.value.dropLast()) {
            return (L("\(seconds) s timeout"), L("\(seconds) seconds"))
        }
        return (chip.value, chip.value)
    }

    /// `/Users/<name>` or `/home/<name>` at the start of a path, shown as `~`.
    static func abbreviatedHome(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let name = rest.prefix { $0 != "/" }
            guard !name.isEmpty else { return path }
            return "~" + rest.dropFirst(name.count)
        }
        return path
    }

    /// "key<TAB>value" lines with the keys dimmed, values aligned on a tab stop and wrapped under themselves.
    private func keyValueText(_ arguments: [ToolCallPresentation.Argument], text: String, inner: CGFloat) -> NSAttributedString {
        let style = self.style
        let keyFont = style.caption
        let keyWidth = arguments.map { singleLine($0.key, keyFont, TranscriptColors.secondary).lineWidth }.max() ?? 0
        let stop = min(keyWidth, inner * 0.35) + 12
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: stop)]
        paragraph.defaultTabInterval = stop
        paragraph.headIndent = stop
        paragraph.paragraphSpacing = 3
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: style.captionMono, .foregroundColor: TranscriptColors.label, .paragraphStyle: paragraph,
        ])
        let string = text as NSString
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let tab = (line as NSString).range(of: "\t")
            if tab.location != NSNotFound {
                let keyRange = NSRange(location: lineStart, length: tab.location)
                result.addAttributes([.foregroundColor: TranscriptColors.secondary, .font: keyFont], range: keyRange)
            }
            lineStart += length + 1
            if lineStart > string.length { break }
        }
        return result
    }

    /// "Output" (or "Error"), badges after it and Copy at the right.
    private func titleRow(_ title: String, failed: Bool, badges: [(String, TranscriptPart.Tool.Tone, String)], copy text: String?,
                          into card: inout ToolCardBuild)
    {
        let style = self.style
        let copy = TranscriptLabelButton.size(title: "Copied")
        let badgeFont = style.caption2Medium
        let badgeHeight = TranscriptStyle.lineHeight(badgeFont) + 2
        let titleFont = style.captionSemibold
        let height = max(self.titleRowHeight, copy.height, badgeHeight)
        let titleWidth = singleLine(title, titleFont, TranscriptColors.secondary).lineWidth
        card.decor.append(.label(title, CGPoint(x: card.x, y: card.y + (height - TranscriptStyle.lineHeight(titleFont)) / 2),
                                 width: titleWidth + 2, .captionSemibold, failed ? .failure : .secondary, truncation: .byClipping))
        var spoken = [title]
        var x = card.x + titleWidth + 8
        let limit = card.x + card.inner - copy.width - 8
        for (text, tone, said) in badges {
            let width = singleLine(text, badgeFont, tone.color).lineWidth + 10
            guard x + width <= limit else { break }
            let top = card.y + (height - badgeHeight) / 2
            card.decor.append(.pill(CGRect(x: x, y: top, width: width, height: badgeHeight), tone))
            card.decor.append(.label(text, CGPoint(x: x + 5, y: top + 1), width: width - 8, .caption2Medium,
                                     tone == .strongFill ? .secondary : tone, truncation: .byClipping))
            spoken.append(said)
            x += width + 6
        }
        if let text, !text.isEmpty {
            card.controls.append(.init(id: "copy-output", title: L("Copy"), symbol: "doc.on.doc",
                                       frame: CGRect(x: card.x + card.inner - copy.width, y: card.y + (height - copy.height) / 2,
                                                     width: copy.width, height: copy.height),
                                       action: .copy(text), spoken: failed ? L("Copy error") : L("Copy output"), trailing: true))
        }
        card.notes.append(.init(frame: CGRect(x: card.x, y: card.y, width: card.inner, height: height),
                                text: spoken.joined(separator: ", ")))
        card.y += height
    }

    private func output(_ output: ToolCallPresentation.Output, kind: ToolCallPresentation.Kind, finding: Bool,
                        tool: ToolActivity, into card: inout ToolCardBuild)
    {
        let style = self.style
        let isExec = kind == .exec
        // Exec merges stdout and stderr, so its failure shows in the badges and outline; other tools' error text is the error.
        let failed = (output.isError || tool.isError) && !isExec
        var badges: [(String, TranscriptPart.Tool.Tone, String)] = []
        if let code = output.exitCode {
            badges.append((L("exit \(code)"), code == 0 ? .ok : .failure, L("Exit code \(code)")))
        }
        if let status = output.status, !status.isEmpty {
            if kind == .webFetch, let code = Int(status) {
                badges.append((L("HTTP \(code)"), (200..<300).contains(code) ? .ok : code >= 400 ? .failure : .strongFill, L("HTTP status \(code)")))
            } else {
                let text = Self.statusText(status)
                badges.append((text, .strongFill, text.prefix(1).uppercased() + text.dropFirst()))
            }
        }
        if let ms = output.durationMs {
            let (text, spoken) = Self.duration(ms)
            badges.append((text, .strongFill, spoken))
        }
        if output.lineCount > 1 { badges.append((L("\(output.lineCount) lines"), .strongFill, L("\(output.lineCount) lines"))) }
        self.titleRow(failed ? L("Error") : L("Output"), failed: failed, badges: badges, copy: output.text, into: &card)
        let lineHeight = TranscriptStyle.lineHeight(style.captionMono)
        if output.text.isEmpty, output.imageCount == 0 {
            card.y += 4
            card.decor.append(.label(L("No output"), CGPoint(x: card.x, y: card.y), width: card.inner, .caption, .tertiary,
                                     truncation: .byTruncatingTail))
            card.y += TranscriptStyle.lineHeight(style.caption)
            return
        }
        if !output.text.isEmpty {
            card.y += 4
            let outKey = "out:\(tool.id)"
            let canCollapse = !finding && output.lineCount > toolOutputPreviewLines
            let showsAll = finding || !canCollapse || self.context.disclosure.isExpanded(outKey, default: false)
            let shown = showsAll ? output.text : Self.firstLines(output.text, toolOutputPreviewLines)
            let maxHeight = showsAll && output.lineCount > toolOutputPreviewLines
                ? TranscriptMetrics.diffMaxHeight : TranscriptMetrics.toolOutputMaxHeight
            let attributed = TranscriptText.plain(shown, font: style.captionMono, color: failed ? TranscriptColors.failure : TranscriptColors.label)
            if isExec {
                let padX: CGFloat = 10
                let padY: CGFloat = 8
                let top = card.y
                card.y += padY
                let visible = self.textSection("\(tool.id):output", attributed, tool: tool, x: card.x + padX, width: max(card.inner - padX * 2, 20),
                                               maxHeight: maxHeight, into: &card)
                card.y += max(visible, lineHeight) + padY
                card.decor.append(.block(CGRect(x: card.x, y: top, width: card.inner, height: card.y - top), .terminal,
                                         stroke: tool.isError || output.isError ? .failure : nil))
            } else {
                card.y += self.textSection("\(tool.id):output", attributed, tool: tool, x: card.x, width: card.inner,
                                           maxHeight: maxHeight, into: &card)
            }
            if canCollapse {
                card.y += 6
                let label = showsAll ? L("Show fewer lines") : L("Show all \(output.lineCount) lines")
                let size = TranscriptLabelButton.size(title: label)
                card.controls.append(.init(id: "toggle-output", title: label, symbol: showsAll ? "chevron.up" : "chevron.down",
                                           frame: CGRect(x: card.x, y: card.y, width: size.width, height: size.height),
                                           action: .toggle(key: outKey, to: !showsAll), spoken: label))
                card.y += size.height
            }
        }
        if output.imageCount > 0 {
            card.y += output.text.isEmpty ? 4 : 6
            let caption = output.imageCount == 1 ? L("1 image (shown in the reply)") : L("\(output.imageCount) images (shown in the reply)")
            let height = TranscriptStyle.lineHeight(style.caption)
            card.decor.append(.symbol("photo", CGRect(x: card.x, y: card.y, width: 14, height: height), .secondary))
            card.decor.append(.label(caption, CGPoint(x: card.x + 20, y: card.y), width: card.inner - 20, .caption, .secondary,
                                     truncation: .byTruncatingTail))
            card.notes.append(.init(frame: CGRect(x: card.x, y: card.y, width: card.inner, height: height),
                                    text: output.imageCount == 1 ? L("1 image, shown in the reply") : L("\(output.imageCount) images, shown in the reply")))
            card.y += height
        }
    }

    private static func chipLabel(_ label: String) -> String {
        switch label {
        case "Working directory": L("Working directory")
        case "Timeout": L("Timeout")
        case "Background": L("Background")
        case "Pseudo-terminal": L("Pseudo-terminal")
        case "Elevated": L("Elevated")
        case "Extract mode": L("Extract mode")
        case "Result count": L("Result count")
        case "Server": L("Server")
        default: label
        }
    }

    /// The kit's fixed English exec statuses, localized.
    private static func statusText(_ status: String) -> String {
        switch status {
        case "timed out": return L("timed out")
        case "no output timeout": return L("no output timeout")
        case "command not found": return L("command not found")
        case "running": return L("running")
        case "approval pending": return L("approval pending")
        case "approval unavailable": return L("approval unavailable")
        default:
            if status.hasPrefix("signal ") { return L("signal \(String(status.dropFirst(7)))") }
            return status
        }
    }

    /// "340 ms", "1.2 s", "2 m 05 s", with how VoiceOver says it.
    private static func duration(_ ms: Int) -> (String, String) {
        if ms < 1000 { return ("\(ms) ms", L("Took \(ms) milliseconds")) }
        if ms < 60_000 {
            var number = String(format: "%.1f", Double(ms) / 1000)
            if number.hasSuffix(".0") { number.removeLast(2) }
            return ("\(number) s", L("Took \(number) seconds"))
        }
        let seconds = ms / 1000
        let text = String(format: "%d m %02d s", seconds / 60, seconds % 60)
        return (text, L("Took \(text)"))
    }

    private static func firstLines(_ text: String, _ count: Int) -> String {
        var end = text.startIndex
        var lines = 0
        while lines < count, let newline = text[end...].firstIndex(of: "\n") {
            end = text.index(after: newline)
            lines += 1
        }
        guard lines == count else { return text }
        return String(text[..<text.index(before: end)])
    }
}
