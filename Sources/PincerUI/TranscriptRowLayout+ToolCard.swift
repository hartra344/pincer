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
        if let range = rest.range(of: "__"), range.lowerBound > rest.startIndex, range.upperBound < rest.endIndex {
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
    var color: PColor {
        switch self {
        case .label: TranscriptColors.label
        case .secondary: TranscriptColors.secondary
        case .tertiary: TranscriptColors.tertiary
        case .red: TranscriptColors.red
        case .green: TranscriptColors.green
        case .fill: TranscriptColors.fill
        case .strongFill: TranscriptColors.strongFill
        case .terminal: TranscriptColors.codeBackground
        }
    }

    /// Background of a badge in this tone.
    var badgeFill: PColor {
        switch self {
        case .red, .green: self.color.withAlphaComponent(0.15)
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
    var spoken: [String] = []
    var matchY: CGFloat?
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
        var spoken: [String] = []
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
            spoken = card.spoken
            toolMatchY = card.matchY
            height = card.y + 10
        }
        let part = TranscriptPart.Tool(tool: tool, key: key, isExpanded: expanded, run: run, headerHeight: headerHeight,
                                       sections: sections, runningY: runningY, edit: edit, diff: diff,
                                       decor: decor, controls: controls, spoken: spoken)
        stack.add(.tool(part), height: height, width: width, spacing: first ? TranscriptMetrics.blockSpacing : TranscriptMetrics.toolSpacing)
        if let toolMatchY, let frame = stack.parts.last?.frame { layout.matchY = frame.minY + toolMatchY }
    }

    /// Lays out the formatted body of a non-edit card. Returns where "Running…" goes, if it should show.
    private func toolCard(_ tool: ToolActivity, row: String, into card: inout ToolCardBuild) -> CGFloat? {
        let presentation = ToolPresentationCache.presentation(for: tool)
        // Find counts the formatted text, so while it has matches in this row nothing is raw or cut short.
        let finding = self.highlight.isActive && self.highlight.options.includeTools && self.highlight.rows.contains(row)
        var placedAny = false
        func gap() {
            if placedAny { card.y += 8 }
            placedAny = true
        }

        if let headline = presentation.headline, !headline.isEmpty {
            gap()
            self.headline(headline, kind: presentation.kind, tool: tool, into: &card)
        }
        if !presentation.chips.isEmpty {
            if placedAny { card.y += 6 }
            placedAny = true
            self.chips(presentation.chips, into: &card)
        }
        let rawKey = "raw:\(tool.id)"
        let showsRaw = !finding && presentation.rawArguments != nil && self.context.disclosure.isExpanded(rawKey, default: false)
        if let argumentsText = presentation.argumentsText, !argumentsText.isEmpty {
            gap()
            self.arguments(presentation, text: argumentsText, raw: showsRaw, rawKey: rawKey, finding: finding, tool: tool, into: &card)
        } else if !finding, let raw = presentation.rawArguments, !raw.isEmpty {
            gap()
            self.arguments(presentation, text: nil, raw: showsRaw, rawKey: rawKey, finding: finding, tool: tool, into: &card)
        }
        var hasOutput = false
        if let output = presentation.output, !output.text.isEmpty || output.imageCount > 0 {
            gap()
            hasOutput = true
            self.output(output, kind: presentation.kind, finding: finding, tool: tool, into: &card)
        }
        guard !hasOutput, tool.isRunning else { return nil }
        gap()
        let y = card.y
        card.y += TranscriptStyle.lineHeight(self.style.caption)
        return y
    }

    private func textSection(_ id: String, _ string: NSAttributedString, tool: ToolActivity, x: CGFloat, width: CGFloat,
                             maxHeight: CGFloat, into card: inout ToolCardBuild) -> CGFloat
    {
        let (text, match) = self.marks.mark(string, .tool(tool.id))
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

    /// The command in a terminal block with a prompt and Copy; other kinds get a symbol and the text.
    private func headline(_ headline: String, kind: ToolCallPresentation.Kind, tool: ToolActivity, into card: inout ToolCardBuild) {
        let style = self.style
        if kind == .exec {
            let pad: CGFloat = 8
            let font = style.code
            let prompt = "$ "
            let promptWidth = singleLine(prompt, font, TranscriptColors.tertiary).lineWidth
            let copy = TranscriptLabelButton.size(title: "")
            let textX = card.x + pad + promptWidth
            let textWidth = max(card.inner - pad - promptWidth - pad - copy.width - 4, 20)
            let top = card.y
            card.y += pad
            let textTop = card.y
            let attributed = TranscriptText.plain(headline, font: font, color: TranscriptColors.label)
            let visible = self.textSection("\(tool.id):command", attributed, tool: tool, x: textX, width: textWidth,
                                           maxHeight: TranscriptMetrics.toolOutputMaxHeight, into: &card)
            let blockHeight = pad + max(visible, TranscriptStyle.lineHeight(font)) + pad
            card.decor.append(.block(CGRect(x: card.x, y: top, width: card.inner, height: blockHeight), .terminal))
            card.decor.append(.label(prompt, CGPoint(x: card.x + pad, y: textTop), width: promptWidth + 2, .code, .tertiary,
                                     truncation: .byClipping))
            card.controls.append(.init(id: "copy-command", title: "", symbol: "doc.on.doc",
                                       frame: CGRect(x: card.x + card.inner - pad - copy.width, y: top + pad, width: copy.width, height: copy.height),
                                       action: .copy(headline), spoken: L("Copy command"), trailing: true, iconOnly: true))
            card.y = top + blockHeight
        } else {
            let symbol = switch kind {
            case .read: "doc.text"
            case .webFetch: "globe"
            case .webSearch: "magnifyingglass"
            default: "chevron.right"
            }
            let font = style.captionMono
            let attributed = TranscriptText.plain(headline, font: font, color: TranscriptColors.label)
            let top = card.y
            let visible = self.textSection("\(tool.id):headline", attributed, tool: tool, x: card.x + 20, width: max(card.inner - 20, 20),
                                           maxHeight: TranscriptMetrics.toolOutputMaxHeight, into: &card)
            card.decor.append(.symbol(symbol, CGRect(x: card.x, y: top, width: 16, height: TranscriptStyle.lineHeight(font)), .secondary))
            card.y = top + visible
        }
    }

    private func chips(_ chips: [ToolCallPresentation.Chip], into card: inout ToolCardBuild) {
        let style = self.style
        let font = style.captionMono
        let height = TranscriptStyle.lineHeight(font) + 6
        var x = card.x
        for chip in chips {
            let text = singleLine(chip.value, font, TranscriptColors.secondary)
            let width = min(8 + 12 + 4 + text.lineWidth + 8, card.inner)
            if x > card.x, x + width > card.x + card.inner {
                x = card.x
                card.y += height + 4
            }
            let rect = CGRect(x: x, y: card.y, width: width, height: height)
            card.decor.append(.pill(rect, .strongFill))
            card.decor.append(.symbol(chip.symbol, CGRect(x: rect.minX + 8, y: rect.minY, width: 12, height: height), .secondary))
            card.decor.append(.label(chip.value, CGPoint(x: rect.minX + 24, y: rect.minY + 3), width: max(width - 32, 1),
                                     .captionMono, .secondary, truncation: .byTruncatingMiddle))
            card.spoken.append("\(chip.label) \(chip.value)")
            x += width + 6
        }
        card.y += height
    }

    private func arguments(_ presentation: ToolCallPresentation, text: String?, raw: Bool, rawKey: String, finding: Bool,
                           tool: ToolActivity, into card: inout ToolCardBuild)
    {
        let style = self.style
        let toggleTitle = raw ? L("Formatted") : L("Raw JSON")
        let toggle = CGSize(width: max(TranscriptLabelButton.size(title: L("Formatted")).width, TranscriptLabelButton.size(title: L("Raw JSON")).width),
                            height: TranscriptLabelButton.size(title: toggleTitle).height)
        let titleHeight = max(TranscriptStyle.lineHeight(style.captionSemibold), toggle.height)
        if text != nil {
            card.decor.append(.label(L("Arguments"), CGPoint(x: card.x, y: card.y + (titleHeight - TranscriptStyle.lineHeight(style.captionSemibold)) / 2),
                                     width: card.inner, .captionSemibold, .secondary, truncation: .byTruncatingTail))
        }
        if !finding, presentation.rawArguments != nil {
            card.controls.append(.init(id: "raw-arguments", title: toggleTitle, symbol: raw ? "list.bullet" : "curlybraces",
                                       frame: CGRect(x: card.x + card.inner - toggle.width, y: card.y + (titleHeight - toggle.height) / 2,
                                                     width: toggle.width, height: toggle.height),
                                       action: .toggle(key: rawKey, to: !raw),
                                       spoken: raw ? L("Show formatted arguments") : L("Show raw JSON arguments"), trailing: true))
        }
        card.y += titleHeight
        guard let text else { return }
        card.y += 4
        let body: NSAttributedString
        if raw, let rawArguments = presentation.rawArguments {
            body = TranscriptText.plain(rawArguments, font: style.captionMono, color: TranscriptColors.label)
        } else {
            body = self.keyValueText(presentation.arguments, text: text)
        }
        card.y += self.textSection("\(tool.id):arguments", body, tool: tool, x: card.x, width: card.inner,
                                   maxHeight: TranscriptMetrics.toolOutputMaxHeight, into: &card)
    }

    /// "key<TAB>value" lines with the keys dimmed, values aligned on a tab stop and wrapped under themselves.
    private func keyValueText(_ arguments: [ToolCallPresentation.Argument], text: String) -> NSAttributedString {
        let style = self.style
        let font = style.captionMono
        let keyWidth = arguments.map { singleLine($0.key, font, TranscriptColors.secondary).lineWidth }.max() ?? 0
        let stop = min(keyWidth + 14, 160)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: stop)]
        paragraph.defaultTabInterval = stop
        paragraph.headIndent = stop
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: TranscriptColors.label, .paragraphStyle: paragraph,
        ])
        let string = text as NSString
        var lineStart = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let tab = (line as NSString).range(of: "\t")
            if tab.location != NSNotFound {
                result.addAttribute(.foregroundColor, value: TranscriptColors.secondary, range: NSRange(location: lineStart, length: tab.location))
            }
            lineStart += length + 1
            if lineStart > string.length { break }
        }
        return result
    }

    private func output(_ output: ToolCallPresentation.Output, kind: ToolCallPresentation.Kind, finding: Bool,
                        tool: ToolActivity, into card: inout ToolCardBuild)
    {
        let style = self.style
        let failed = output.isError || tool.isError
        let copy = TranscriptLabelButton.size(title: "Copied")
        let badgeFont = style.caption2Medium
        let badgeHeight = TranscriptStyle.lineHeight(badgeFont) + 2
        let titleFont = style.captionSemibold
        let titleHeight = max(TranscriptStyle.lineHeight(titleFont), copy.height, badgeHeight)
        let title = failed ? L("Error") : L("Output")
        let titleWidth = singleLine(title, titleFont, TranscriptColors.secondary).lineWidth
        card.decor.append(.label(title, CGPoint(x: card.x, y: card.y + (titleHeight - TranscriptStyle.lineHeight(titleFont)) / 2),
                                 width: titleWidth + 2, .captionSemibold, failed ? .red : .secondary, truncation: .byClipping))
        var badges: [(String, TranscriptPart.Tool.Tone, String)] = []
        if let code = output.exitCode {
            badges.append((L("exit \(code)"), code == 0 ? .green : .red, L("Exit code \(code)")))
        }
        if let status = output.status, !status.isEmpty { badges.append((status, .secondary, status)) }
        if let ms = output.durationMs {
            let text = Self.duration(ms)
            badges.append((text, .secondary, L("Took \(text)")))
        }
        if output.lineCount > 1 { badges.append((L("\(output.lineCount) lines"), .secondary, L("\(output.lineCount) lines"))) }
        var x = card.x + titleWidth + 8
        let limit = card.x + card.inner - copy.width - 8
        for (text, tone, spoken) in badges {
            let width = singleLine(text, badgeFont, tone.color).lineWidth + 10
            guard x + width <= limit else { break }
            card.decor.append(.pill(CGRect(x: x, y: card.y + (titleHeight - badgeHeight) / 2, width: width, height: badgeHeight), tone))
            card.decor.append(.label(text, CGPoint(x: x + 5, y: card.y + (titleHeight - badgeHeight) / 2 + 1), width: width - 8,
                                     .caption2Medium, tone, truncation: .byClipping))
            card.spoken.append(spoken)
            x += width + 6
        }
        if !output.text.isEmpty {
            card.controls.append(.init(id: "copy-output", title: L("Copy"), symbol: "doc.on.doc",
                                       frame: CGRect(x: card.x + card.inner - copy.width, y: card.y + (titleHeight - copy.height) / 2,
                                                     width: copy.width, height: copy.height),
                                       action: .copy(output.text), spoken: failed ? L("Copy error") : L("Copy output"), trailing: true))
        }
        card.y += titleHeight
        if !output.text.isEmpty {
            card.y += 4
            let outKey = "out:\(tool.id)"
            let canCollapse = !finding && output.lineCount > toolOutputPreviewLines
            let showsAll = !canCollapse || self.context.disclosure.isExpanded(outKey, default: false)
            let shown = showsAll ? output.text : Self.firstLines(output.text, toolOutputPreviewLines)
            let pad: CGFloat = 8
            let attributed = TranscriptText.plain(shown, font: style.captionMono,
                                                  color: failed ? TranscriptColors.red : TranscriptColors.label)
            let top = card.y
            card.y += pad
            let visible = self.textSection("\(tool.id):output", attributed, tool: tool, x: card.x + pad, width: max(card.inner - pad * 2, 20),
                                           maxHeight: TranscriptMetrics.toolOutputMaxHeight, into: &card)
            card.y += visible + pad
            card.decor.append(.block(CGRect(x: card.x, y: top, width: card.inner, height: card.y - top), .terminal))
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
            if !output.text.isEmpty { card.y += 6 }
            let caption = output.imageCount == 1 ? L("1 image") : L("\(output.imageCount) images")
            card.decor.append(.symbol("photo", CGRect(x: card.x, y: card.y, width: 14, height: TranscriptStyle.lineHeight(style.caption)), .secondary))
            card.decor.append(.label(caption, CGPoint(x: card.x + 20, y: card.y), width: card.inner - 20, .caption, .secondary,
                                     truncation: .byTruncatingTail))
            card.spoken.append(caption)
            card.y += TranscriptStyle.lineHeight(style.caption)
        }
    }

    private static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
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
