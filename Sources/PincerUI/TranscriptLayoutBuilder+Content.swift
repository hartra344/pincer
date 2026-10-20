import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptLayoutBuilder {
    // MARK: Content

    func markdown(_ source: String, tone: TranscriptText.Tone, section: TranscriptSearch.Section, live: Bool = false,
                          into stack: inout Stack, layout: inout TranscriptRowLayout)
    {
        let width = stack.width
        // A streaming message is split into frozen chunks and a tail; a committed one is one cached list.
        let pieces: [TranscriptText.LiveSegment] = live
            ? TranscriptText.liveMarkdown(source, tone: tone, row: layout.id, owner: self.context.chat.map(ObjectIdentifier.init))
            : TranscriptText.markdown(source, tone: tone, dark: self.settings.dark).map { .init(segment: $0, isFrozen: false, extraSpacing: 0) }
        for piece in pieces {
            let spacing = TranscriptMetrics.blockSpacing + piece.extraSpacing
            switch piece.segment {
            case let .text(source):
                let (text, match) = self.marks.mark(source, section)
                let size = live ? TranscriptText.liveSize(text, width: width, frozen: piece.isFrozen && text === source, exact: true)
                    : TranscriptText.size(text, width: width, memoized: text === source)
                stack.add(.text(text), height: size.height, spacing: spacing)
                self.marks.place(match, in: text, width: width, stack: stack, into: &layout)
            case let .quote(source):
                let (text, match) = self.marks.mark(source, section)
                let quoteWidth = TranscriptText.quoteWidth(for: width)
                let size = live ? TranscriptText.liveSize(text, width: quoteWidth, frozen: piece.isFrozen && text === source, exact: false)
                    : TranscriptText.size(text, width: quoteWidth, memoized: text === source)
                stack.add(.quote(text), height: size.height, spacing: spacing)
                self.marks.place(match, in: text, width: quoteWidth, stack: stack, into: &layout)
            case .rule:
                stack.add(.rule, height: 1)
            case let .code(language, code, source):
                // Mid-stream, a diagram stays code until its chunk is final, so it isn't redrawn per token.
                if !live || piece.isFrozen,
                   let rendered = RichBlock.render(language: language, code: code, dark: self.settings.dark),
                   !self.context.gateway.images.hasFailed(rendered.ref)
                {
                    self.richBlock(rendered, into: &stack, layout: &layout)
                    let key = "\(rendered.kind.rawValue)-source:\(layout.id):\(rendered.ref.cacheKey)"
                    let expanded = self.context.disclosure.isExpanded(key, default: false)
                    let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
                    stack.add(.thinkingHeader(.init(key: key, title: rendered.kind.sourceTitle, isStreaming: false, isExpanded: expanded,
                                                     symbol: "chevron.left.forwardslash.chevron.right")),
                              height: headerHeight, width: min(width, TranscriptMetrics.maxCardWidth), spacing: 6)
                    guard expanded else { continue }
                } else if let ref = Self.inlineSVG(language: language, code: code),
                   !self.context.gateway.images.hasFailed(ref)
                {
                    self.images([ref], into: &stack, layout: &layout)
                    let key = "svg-source:\(layout.id):\(ref.cacheKey)"
                    let expanded = self.context.disclosure.isExpanded(key, default: false)
                    let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
                    stack.add(.thinkingHeader(.init(key: key, title: L("SVG source"), isStreaming: false, isExpanded: expanded,
                                                     symbol: "chevron.left.forwardslash.chevron.right")),
                              height: headerHeight, width: min(width, TranscriptMetrics.maxCardWidth), spacing: 6)
                    guard expanded else { continue }
                }
                let headerHeight = 6 + max(TranscriptStyle.lineHeight(self.style.caption), TranscriptMetrics.iconBox) + 6
                // Find skips SVG, diagram and math source, which is usually shown drawn.
                let isSVG = SVGSource.inlineSource(language: language, code: code) != nil || RichBlock.kind(language: language) != nil
                let (text, match) = isSVG ? (source, nil) : self.marks.mark(source, section)
                let size = live ? TranscriptText.liveSize(text, width: .greatestFiniteMagnitude, frozen: piece.isFrozen && text === source, exact: false)
                    : TranscriptText.size(text, width: .greatestFiniteMagnitude, memoized: text === source)
                let part = TranscriptPart.Code(language: language, code: code, text: text, textSize: size, headerHeight: headerHeight)
                stack.add(.code(part), height: headerHeight + 1 + 10 + size.height + 10)
                self.marks.place(match, in: text, width: .greatestFiniteMagnitude, stack: stack, offset: headerHeight + 11, into: &layout)
            case let .table(source):
                var cells = source.cells
                var found = false
                for row in cells.indices {
                    for column in cells[row].indices {
                        let (cell, match) = self.marks.mark(cells[row][column], section)
                        cells[row][column] = cell
                        found = found || match != nil
                    }
                }
                let table = TranscriptText.Table(cells: cells, alignments: source.alignments, plainText: source.plainText)
                let part = self.table(table, original: source, width: width)
                stack.add(.table(part), height: part.contentSize.height, width: part.contentSize.width)
                if found, let frame = stack.parts.last?.frame { layout.matchY = frame.minY + min(frame.height, 40) }
            }
        }
    }

    /// A rendered diagram or formula at its own size, scaled down to fit the width and a height cap.
    private func richBlock(_ rendered: RichBlock.Rendered, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let ref = rendered.ref
        layout.images.append(ref)
        let maxHeight: CGFloat = rendered.kind == .math ? 320 : 640
        let scale = min(1, stack.width / rendered.size.width, maxHeight / rendered.size.height)
        let size = CGSize(width: max((rendered.size.width * scale).rounded(), 1), height: max((rendered.size.height * scale).rounded(), 1))
        let loader = self.context.gateway.images
        let state: TranscriptPart.Image.State = if let image = loader.cached(ref) { .loaded(image) }
            else if loader.hasFailed(ref) { .failed } else { .loading }
        stack.add(.image(.init(ref: ref, state: state, plain: rendered.kind == .math)), height: size.height, width: size.width)
    }

    /// A complete fenced SVG (```svg, or any fence holding a whole `<svg>…</svg>`) drawn as an image.
    /// Unfinished ones, mid-stream, stay code until their closing tag arrives.
    static func inlineSVG(language: String, code: String) -> ImageRef? {
        guard let trimmed = SVGSource.inlineSource(language: language, code: code) else { return nil }
        return InlineSVGCache.ref(for: trimmed)
    }

    /// Columns share the width when each can keep a readable minimum; otherwise the table keeps
    /// its natural column widths and scrolls sideways.
    private func table(_ table: TranscriptText.Table, original: TranscriptText.Table, width available: CGFloat) -> TranscriptPart.Table {
        let columns = table.cells.first?.count ?? 0
        let padding = TranscriptTableMetrics.padding
        var naturals = Array(repeating: CGFloat(0), count: columns)
        for (rowIndex, row) in table.cells.enumerated() {
            for (column, cell) in row.enumerated() {
                naturals[column] = max(naturals[column], TranscriptText.naturalWidth(cell, memoized: cell === original.cells[rowIndex][column]))
            }
        }
        let widths = TranscriptTableMetrics.columnWidths(naturals: naturals, available: available)
        let heights = table.cells.enumerated().map { rowIndex, row in
            row.enumerated().map { column, cell in
                TranscriptText.size(cell, width: max(widths[column] - padding, 1), memoized: cell === original.cells[rowIndex][column]).height
            }.max().map { max($0, TranscriptStyle.lineHeight(self.style.body)) + 10 } ?? 0
        }
        return TranscriptPart.Table(cells: table.cells, columnWidths: widths, rowHeights: heights, plainText: table.plainText)
    }

    func thinking(_ text: String, turn: AssistantTurn, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "thinking:\(turn.id)"
        let streaming = turn.isStreaming && turn.text.isEmpty
        // Thinking opened while it streamed stays open until the turn finishes.
        if streaming { self.context.disclosure.setIfUnset(key, expanded: true) }
        let expanded = self.context.disclosure.isExpanded(key, default: streaming)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
        let title = streaming ? L("Thinking…") : L("Thinking")
        stack.add(.thinkingHeader(.init(key: key, title: title, isStreaming: streaming, isExpanded: expanded)), height: headerHeight, width: width)
        if expanded { self.thinkingBody(text, width: width, into: &stack, layout: &layout) }
    }

    /// A finished turn's reasoning and tool calls as one collapsible "Thinking" item, closed until opened.
    func thinkingGroup(_ text: String, turn: AssistantTurn, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "steps:\(turn.id)"
        let expanded = self.context.disclosure.isExpanded(key, default: false)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
        var title = L("Thinking")
        let count = turn.tools.count
        if count > 0 { title += " · " + (count == 1 ? L("1 tool call") : L("\(count) tool calls")) }
        stack.add(.thinkingHeader(.init(key: key, title: title, isStreaming: false, isExpanded: expanded)), height: headerHeight, width: width)
        guard expanded else { return }
        if !text.isEmpty { self.thinkingBody(text, width: width, into: &stack, layout: &layout) }
        self.tools(turn.tools, into: &stack, layout: &layout)
    }

    private func thinkingBody(_ text: String, width: CGFloat, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let (body, match) = self.marks.mark(TranscriptText.plain(text, font: self.style.callout, color: TranscriptColors.secondary), .thinking)
        stack.add(.thinkingBody(body), height: TranscriptText.size(body, width: max(width - 10, 20)).height, width: width, spacing: 6)
        self.marks.place(match, in: body, width: max(width - 10, 20), stack: stack, into: &layout)
    }

    func tools(_ tools: [ToolActivity], into stack: inout Stack, layout: inout TranscriptRowLayout) {
        for (index, tool) in tools.enumerated() {
            self.tool(tool, first: index == 0, into: &stack, layout: &layout)
        }
    }

    /// An edit card's diff: a "Changes" title with Copy, the colored lines (the first few when it's
    /// long and not opened in full), and a toggle to show all or fewer lines.
    func diff(_ edit: ToolFileEdit, tool: ToolActivity, row: String, width: CGFloat, y top: CGFloat)
        -> (section: TranscriptPart.Tool.Section, diff: TranscriptPart.Tool.Diff, match: NSRange?, bottom: CGFloat)
    {
        let key = "diff:\(tool.id)"
        // Find counts every line of the diff, so while it has matches in this row nothing is hidden.
        let finding = self.highlight.isActive && self.highlight.options.includeTools && self.highlight.rows.contains(row)
        let showsAll = finding || self.context.disclosure.isExpanded(key, default: false)
        let (rows, hidden) = edit.rows(collapsed: !showsAll)
        let inner = max(width - 20, 20)
        let copySize = TranscriptLabelButton.size(title: L("Copied"))
        let titleRow = max(TranscriptStyle.lineHeight(self.style.captionSemibold), copySize.height)
        var y = top
        let copyFrame = CGRect(x: width - 10 - copySize.width, y: y + (titleRow - copySize.height) / 2,
                               width: copySize.width, height: copySize.height)
        let titleY = y + (titleRow - TranscriptStyle.lineHeight(self.style.captionSemibold)) / 2
        y += titleRow + 4
        let (text, match) = self.marks.mark(TranscriptDiffText.text(rows), .tool(tool.id))
        let contentHeight = TranscriptText.size(text, width: inner).height
        // Fully shown diffs take their whole height so nothing scrolls inside the transcript's own scroll.
        let visible = hidden == 0 ? contentHeight : min(contentHeight, TranscriptMetrics.diffMaxHeight)
        let section = TranscriptPart.Tool.Section(title: L("Changes"), titleY: titleY, text: text,
                                                  frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight)
        y += visible
        var toggleTitle: String?
        if finding {
            toggleTitle = nil
        } else if hidden > 0 {
            toggleTitle = L("Show all \(edit.rows.count) lines")
        } else if showsAll, edit.isLarge {
            toggleTitle = L("Show fewer lines")
        }
        var toggleFrame = CGRect.zero
        if let toggleTitle {
            y += 6
            let size = TranscriptLabelButton.size(title: toggleTitle)
            toggleFrame = CGRect(x: 10, y: y, width: size.width, height: size.height)
            y += size.height
        }
        let diff = TranscriptPart.Tool.Diff(copyText: edit.copyText, copyFrame: copyFrame, key: key, isExpanded: showsAll,
                                            toggleTitle: toggleTitle, toggleFrame: toggleFrame)
        return (section, diff, match, y)
    }

    /// Subagent run this tool call started, so the run can be opened from where it happened.
    func spawnedRun(_ tool: ToolActivity) -> TranscriptPart.Tool.Run? {
        let sessions = self.context.gateway.sessions
        var row: SessionRow?
        if let key = tool.spawnedSessionKey { row = sessions[key] }
        if row == nil, let label = tool.spawnLabel {
            row = sessions.values.first { $0.isSubagent && $0.raw["label"]?.text == label }
        }
        return row.map { .init(key: $0.key, title: $0.title) }
    }

    func images(_ refs: [ImageRef], into stack: inout Stack, layout: inout TranscriptRowLayout) {
        guard !refs.isEmpty else { return }
        layout.images += refs
        let loader = self.context.gateway.images
        let single = refs.count == 1
        let spacing: CGFloat = 6
        let columnWidth = single ? min(stack.width, 400) : max(min((min(stack.width, 646) - spacing) / 2, 320), 60)
        let maxHeight: CGFloat = single ? 360 : 200
        let linkHeight = 6 + TranscriptStyle.lineHeight(self.style.callout) + 6

        var cells: [(TranscriptPart, CGSize)] = []
        for ref in refs {
            if let image = loader.cached(ref) {
                TranscriptImageSizes.note(image, for: ref)
                cells.append((.image(.init(ref: ref, state: .loaded(image))), self.fit(TranscriptImageSizes.size(for: ref), column: columnWidth, maxHeight: maxHeight)))
            } else if loader.hasFailed(ref), let link = Self.webLink(ref) {
                let title = ref.alt ?? link.host ?? L("Open image")
                let textWidth = TranscriptText.naturalWidth(TranscriptText.plain(title, font: self.style.callout, color: TranscriptColors.link))
                cells.append((.imageLink(title: title, url: link), CGSize(width: min(columnWidth, 10 + 16 + 6 + textWidth + 10), height: linkHeight)))
            } else {
                let state: TranscriptPart.Image.State = loader.hasFailed(ref) ? .failed : .loading
                cells.append((.image(.init(ref: ref, state: state)), self.fit(TranscriptImageSizes.size(for: ref), column: columnWidth, maxHeight: maxHeight)))
            }
        }
        let columns = single ? 1 : 2
        var index = 0
        var first = true
        while index < cells.count {
            let rowCells = cells[index..<min(index + columns, cells.count)]
            let rowHeight = rowCells.map(\.1.height).max() ?? 0
            let top = stack.next(spacing: first ? TranscriptMetrics.blockSpacing : spacing)
            var x = stack.x
            for (part, size) in rowCells {
                stack.parts.append(.init(part: part, frame: CGRect(x: x, y: top, width: size.width, height: size.height)))
                x += columnWidth + spacing
            }
            stack.y = top + rowHeight
            index += columns
            first = false
        }
    }

    /// Aspect-fit inside the column, never scaled above the image's own pixel size.
    private func fit(_ natural: CGSize?, column: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard let natural, natural.width > 0, natural.height > 0 else {
            let width = min(column, 320)
            return CGSize(width: width, height: min((width * 3 / 4).rounded(), 220))
        }
        let aspect = natural.width / natural.height
        var width = min(column, natural.width, maxHeight * aspect)
        width = max(width, min(column, 40))
        return CGSize(width: width.rounded(), height: max((width / aspect).rounded(), 24))
    }

    static func webLink(_ ref: ImageRef) -> URL? {
        guard let string = ref.url, let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    func file(_ ref: FileRef, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "file:\(layout.id):\(ref.cacheKey)"
        let canExpand = ref.isText && ref.isDownloadable && !HTMLPreview.isPreviewable(file: ref)
        let expanded = canExpand && self.context.disclosure.isExpanded(key, default: false)
        let headerHeight = 6 + TranscriptStyle.lineHeight(self.style.callout) + 6
        guard expanded else {
            let width = min(TranscriptFileView.chipWidth(for: ref, canExpand: canExpand), stack.width)
            let part = TranscriptPart.File(ref: ref, key: key, canExpand: canExpand, isExpanded: false,
                                           headerHeight: headerHeight, section: nil, note: nil, noteY: 0)
            stack.add(.file(part), height: headerHeight, width: width)
            return
        }
        layout.files.append(ref)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let inner = max(width - 20, 20)
        let noteHeight = TranscriptStyle.lineHeight(self.style.caption)
        var y = headerHeight + 1 + 10
        var section: TranscriptPart.Tool.Section?
        var note: String?
        var noteY = y
        switch self.context.gateway.files.preview(ref) {
        case nil:
            note = L("Loading…")
            y += noteHeight
        case .failed:
            note = L("Couldn’t load this file.")
            y += noteHeight
        case .binary:
            note = L("This file isn’t text. Save it to open it.")
            y += noteHeight
        case let .text(content, truncated):
            let text = TranscriptText.plain(content.isEmpty ? L("(empty file)") : content, font: self.style.captionMono,
                                            color: content.isEmpty ? TranscriptColors.secondary : TranscriptColors.label)
            let contentHeight = TranscriptText.size(text, width: inner).height
            let visible = min(contentHeight, TranscriptMetrics.filePreviewMaxHeight)
            section = .init(title: ref.name, titleY: 0, text: text,
                            frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight)
            y += visible
            if truncated {
                y += 8
                noteY = y
                note = L("Showing the start of the file. Save it to see the rest.")
                y += noteHeight
            }
        }
        let part = TranscriptPart.File(ref: ref, key: key, canExpand: true, isExpanded: true, headerHeight: headerHeight,
                                       section: section, note: note, noteY: noteY)
        stack.add(.file(part), height: y + 10, width: width)
    }
}

/// Small bounded cache so re-laying-out a row doesn't base64-encode and re-hash the same SVG.
private enum InlineSVGCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refs: [String: ImageRef] = [:]
    private static let limit = 32

    static func ref(for source: String) -> ImageRef {
        lock.lock()
        defer { lock.unlock() }
        if let hit = refs[source] { return hit }
        let ref = ImageRef(artifactId: nil, base64: Data(source.utf8).base64EncodedString(), url: nil,
                           mimeType: "image/svg+xml", alt: L("SVG image"), width: nil, height: nil)
        if refs.count >= limit { refs.removeAll(keepingCapacity: true) }
        refs[source] = ref
        return ref
    }
}
