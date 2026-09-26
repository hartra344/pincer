import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One positioned piece of a transcript row. Frames are in row coordinates, top-left origin.
enum TranscriptPart {
    struct Avatar {
        let text: String
        let emoji: String?
        let color: PColor
    }

    struct Header {
        let name: String
        let badge: String?
        let time: String?
        let isPending: Bool
    }

    struct Code {
        let language: String
        let code: String
        let text: NSAttributedString
        let textSize: CGSize
        let headerHeight: CGFloat
    }

    struct Table {
        let cells: [[NSAttributedString]]
        let columnWidths: [CGFloat]
        let rowHeights: [CGFloat]
        let plainText: String
        var contentSize: CGSize {
            CGSize(width: self.columnWidths.reduce(0, +), height: self.rowHeights.reduce(0, +))
        }
    }

    struct Thinking {
        let key: String
        let title: String
        let isStreaming: Bool
        let isExpanded: Bool
        var symbol = "brain.head.profile"
    }

    struct Tool {
        struct Section {
            let title: String
            let titleY: CGFloat
            let text: NSAttributedString
            /// Visible frame of the text inside the card; the text scrolls when it's taller.
            let frame: CGRect
            let contentHeight: CGFloat
        }

        struct Run: Equatable {
            let key: String
            let title: String
        }

        let tool: ToolActivity
        let key: String
        let isExpanded: Bool
        let run: Run?
        let headerHeight: CGFloat
        let sections: [Section]
        /// Where "Running…" goes when there's no output yet.
        let runningY: CGFloat?
    }

    /// The line under a message: a Copy button and details such as when it was sent.
    struct Footer {
        /// Tells a recycled footer it now shows a different message, so "Copied" resets.
        let key: String
        let copyText: String
        let details: String
    }

    struct Image {
        enum State { case loading, loaded(CGImage), failed }
        let ref: ImageRef
        let state: State
    }

    case avatar(Avatar)
    case header(Header)
    case text(NSAttributedString)
    case quote(NSAttributedString)
    case rule
    case code(Code)
    case table(Table)
    case thinkingHeader(Thinking)
    case thinkingBody(NSAttributedString)
    case tool(Tool)
    /// An attachment: a chip that saves it, and for text or code a card that expands to show it.
    struct File {
        let ref: FileRef
        let key: String
        let canExpand: Bool
        let isExpanded: Bool
        let headerHeight: CGFloat
        let section: Tool.Section?
        /// Loading, error or truncation note, drawn at `noteY`.
        let note: String?
        let noteY: CGFloat
    }

    case image(Image)
    case imageLink(title: String, url: URL)
    case file(File)
    case typing
    case footer(Footer)
    case marker(String)
    case loading

    enum Kind: Hashable {
        case avatar, header, text, quote, thinkingBody, rule, code, table, thinkingHeader, tool, image,
             imageLink, file, typing, footer, marker, loading
    }

    var kind: Kind {
        switch self {
        case .avatar: .avatar
        case .header: .header
        case .text: .text
        case .quote: .quote
        case .thinkingBody: .thinkingBody
        case .rule: .rule
        case .code: .code
        case .table: .table
        case .thinkingHeader: .thinkingHeader
        case .tool: .tool
        case .image: .image
        case .imageLink: .imageLink
        case .file: .file
        case .typing: .typing
        case .footer: .footer
        case .marker: .marker
        case .loading: .loading
        }
    }
}

/// A transcript row laid out at one width: every part's frame, and the row's exact height.
struct TranscriptRowLayout {
    struct Placed {
        let part: TranscriptPart
        let frame: CGRect
    }

    struct CopyItem {
        let title: String
        let text: String
    }

    let id: String
    let width: CGFloat
    var parts: [Placed] = []
    var height: CGFloat = 0
    var alpha: CGFloat = 1
    var copyItems: [CopyItem] = []
    /// Images this row shows, so it can be laid out again when one loads.
    var images: [ImageRef] = []
    /// Expanded file previews this row shows, so it can be laid out again when one loads.
    var files: [FileRef] = []
    /// Subagent runs this row links to, so it can update when the run shows up.
    var runs: [String: TranscriptPart.Tool.Run] = [:]
    var hasSpawns = false
    var accessibilityLabel = ""
    /// Distinct for every layout built, so a view can tell it already shows this one.
    var serial = 0
}

/// Settings that change how rows look. Read from the same defaults the Settings screen writes,
/// plus the session's own `reasoningLevel`.
struct TranscriptSettings: Equatable {
    var thinking: ThinkingDisplay
    /// The session has reasoning turned off on the Gateway, so no reasoning text is shown at all.
    var reasoningOff = false
    /// Colors are baked into layouts (avatars) and drawn by row views, so a theme change redoes them.
    var theme = AppTheme()

    @MainActor static func current(for context: TranscriptContext) -> TranscriptSettings {
        TranscriptSettings(
            thinking: ThinkingDisplay.current,
            reasoningOff: context.gateway.sessions[context.sessionKey]?.reasoningLevel == "off",
            theme: AppTheme.current)
    }
}

/// Natural image sizes, remembered past the image cache so a row keeps its height when its image
/// is evicted and loads again.
@MainActor
enum TranscriptImageSizes {
    private static var sizes: [String: CGSize] = [:]

    static func note(_ image: CGImage, for ref: ImageRef) {
        self.sizes[ref.cacheKey] = CGSize(width: image.width, height: image.height)
    }

    static func size(for ref: ImageRef) -> CGSize? {
        if let size = self.sizes[ref.cacheKey] { return size }
        if let width = ref.width, let height = ref.height, width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return nil
    }
}

/// Lays out transcript rows. Pure function of the row, the width and the current state it reads
/// (disclosure, settings, images, sessions), so the same inputs always give the same height.
@MainActor
struct TranscriptLayoutBuilder {
    let context: TranscriptContext
    let settings: TranscriptSettings

    private var style: TranscriptStyle { TranscriptStyle.shared }

    func layout(_ row: TranscriptRow, width: CGFloat) -> TranscriptRowLayout {
        var layout = TranscriptRowLayout(id: row.id, width: width)
        switch row {
        case .loadingOlder:
            layout.parts = [.init(part: .loading, frame: CGRect(x: 0, y: 0, width: width, height: 36))]
            layout.height = 36
            layout.accessibilityLabel = "Loading earlier messages"
        case let .entry(.marker(_, label)):
            let height = 8 + TranscriptStyle.lineHeight(self.style.caption) + 8
            let frame = CGRect(x: TranscriptMetrics.sidePadding, y: 0,
                               width: max(0, width - TranscriptMetrics.sidePadding * 2), height: height)
            layout.parts = [.init(part: .marker(label), frame: frame)]
            layout.height = height
            layout.accessibilityLabel = label
        case let .entry(.user(item)):
            self.user(item, into: &layout)
        case let .entry(.assistant(turn)):
            self.assistant(turn, into: &layout)
        }
        return layout
    }

    // MARK: Rows

    private func user(_ item: ChatItem, into layout: inout TranscriptRowLayout) {
        let header = TranscriptPart.Header(name: Owner.displayName, badge: item.via.map { "via \($0)" },
                                           time: item.timestamp?.chatTimestamp, isPending: item.isPending)
        let text = item.plainText
        layout.alpha = item.isPending ? 0.7 : 1
        layout.copyItems = [.init(title: "Copy Text", text: text)]
        layout.accessibilityLabel = "\(header.name): \(text)"
        self.scaffold(avatar: .init(text: Owner.initials, emoji: nil, color: TranscriptColors.ownerAvatar),
                      header: header, into: &layout) { stack, layout in
            if !text.isEmpty { self.markdown(text, tone: .primary, into: &stack, layout: &layout) }
            let images = item.blocks.compactMap { block -> ImageRef? in
                if case let .image(ref) = block { return ref }
                return nil
            }
            self.images(images, into: &stack, layout: &layout)
            for block in item.blocks {
                if case let .file(file) = block { self.file(file, into: &stack, layout: &layout) }
            }
            if !item.isPending, !text.isEmpty {
                self.footer(key: "\(item.id):0", copy: text, time: item.timestamp, model: nil, into: &stack)
            }
        }
    }

    private func assistant(_ turn: AssistantTurn, into layout: inout TranscriptRowLayout) {
        let agent = self.context.agent
        let header = TranscriptPart.Header(name: agent.name, badge: nil, time: turn.timestamp?.chatTimestamp, isPending: false)
        let thinking = turn.thinking.joined(separator: "\n\n")
        layout.copyItems = [.init(title: "Copy Reply", text: turn.body)]
        if !thinking.isEmpty { layout.copyItems.append(.init(title: "Copy Thinking", text: thinking)) }
        layout.accessibilityLabel = "\(agent.name): \(turn.body)"
        let reasoning = self.settings.reasoningOff ? "" : thinking
        let hasSteps = !reasoning.isEmpty || !turn.tools.isEmpty
        let hasReply = !turn.text.isEmpty || !turn.images.isEmpty || !turn.files.isEmpty
        let steps: ThinkingSteps = switch self.settings.thinking {
        case _ where !hasSteps: .hidden
        case .none: .hidden
        case _ where turn.isStreaming: .live
        case .all: .grouped
        // A finished turn with nothing else to show keeps its steps, folded, so it isn't blank.
        case .live: hasReply ? .hidden : .grouped
        }
        self.scaffold(avatar: .init(text: String(agent.name.prefix(1)).uppercased(), emoji: agent.emoji, color: TranscriptColors.agentAvatar),
                      header: header, into: &layout) { stack, layout in
            switch steps {
            case .hidden:
                break
            case .live:
                if !reasoning.isEmpty { self.thinking(reasoning, turn: turn, into: &stack) }
                self.tools(turn.tools, into: &stack, layout: &layout)
            case .grouped:
                self.thinkingGroup(reasoning, turn: turn, into: &stack, layout: &layout)
            }
            // Each message gets its own footer, which with the gap after it keeps back-to-back
            // messages apart. The last footer goes under the turn's images and files.
            let showFooters = !turn.isStreaming
            for (index, message) in turn.text.enumerated() {
                if index > 0 { stack.y += TranscriptMetrics.messageSpacing - TranscriptMetrics.blockSpacing }
                self.markdown(message, tone: turn.isError ? .error : .primary, into: &stack, layout: &layout)
                if showFooters, index < turn.text.count - 1 { self.messageFooter(turn, message: index, into: &stack) }
            }
            self.images(turn.images, into: &stack, layout: &layout)
            for file in turn.files { self.file(file, into: &stack, layout: &layout) }
            if showFooters, !turn.text.isEmpty { self.messageFooter(turn, message: turn.text.count - 1, into: &stack) }
            let showsActivity = steps == .live && (!reasoning.isEmpty || turn.tools.contains(where: \.isRunning))
            if turn.isStreaming, turn.text.isEmpty, !showsActivity {
                stack.add(.typing, height: 14, width: 26)
            }
        }
    }

    private enum ThinkingSteps { case hidden, live, grouped }

    /// Avatar on the left, name line on top, content stacked below it.
    private func scaffold(avatar: TranscriptPart.Avatar, header: TranscriptPart.Header,
                          into layout: inout TranscriptRowLayout, content: (inout Stack, inout TranscriptRowLayout) -> Void)
    {
        let metrics = TranscriptMetrics.self
        let x = metrics.contentX
        let contentWidth = max(layout.width - x - metrics.sidePadding, 40)
        let top = metrics.verticalPadding
        let headerHeight = TranscriptStyle.lineHeight(self.style.headline)
        layout.parts.append(.init(part: .avatar(avatar), frame: CGRect(x: metrics.sidePadding, y: top, width: metrics.avatar, height: metrics.avatar)))
        layout.parts.append(.init(part: .header(header), frame: CGRect(x: x, y: top, width: contentWidth, height: headerHeight)))
        var stack = Stack(x: x, y: top + headerHeight + metrics.headerGap, width: contentWidth)
        content(&stack, &layout)
        layout.parts += stack.parts
        let bottom = stack.isEmpty ? top + headerHeight : stack.y
        layout.height = ceil(max(bottom, top + metrics.avatar) + metrics.verticalPadding)
    }

    struct Stack {
        let x: CGFloat
        var y: CGFloat
        let width: CGFloat
        var parts: [TranscriptRowLayout.Placed] = []
        var isEmpty: Bool { self.parts.isEmpty }

        init(x: CGFloat, y: CGFloat, width: CGFloat) {
            self.x = x
            self.y = y
            self.width = width
        }

        /// The y where the next item starts, after the spacing that separates it from the last one.
        mutating func next(spacing: CGFloat = TranscriptMetrics.blockSpacing) -> CGFloat {
            if !self.parts.isEmpty { self.y += spacing }
            return self.y
        }

        mutating func add(_ part: TranscriptPart, height: CGFloat, width: CGFloat? = nil,
                          spacing: CGFloat = TranscriptMetrics.blockSpacing)
        {
            let top = self.next(spacing: spacing)
            self.parts.append(.init(part: part, frame: CGRect(x: self.x, y: top, width: min(width ?? self.width, self.width), height: height)))
            self.y = top + height
        }
    }

    // MARK: Content

    private func markdown(_ source: String, tone: TranscriptText.Tone, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let width = stack.width
        for segment in TranscriptText.markdown(source, tone: tone) {
            switch segment {
            case let .text(text):
                stack.add(.text(text), height: TranscriptText.size(text, width: width).height)
            case let .quote(text):
                stack.add(.quote(text), height: TranscriptText.size(text, width: max(width - 11, 20)).height)
            case .rule:
                stack.add(.rule, height: 1)
            case let .code(language, code, text):
                if let ref = Self.inlineSVG(language: language, code: code),
                   !self.context.gateway.images.hasFailed(ref)
                {
                    self.images([ref], into: &stack, layout: &layout)
                    let key = "svg-source:\(layout.id):\(ref.cacheKey)"
                    let expanded = self.context.disclosure.isExpanded(key, default: false)
                    let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
                    stack.add(.thinkingHeader(.init(key: key, title: "SVG source", isStreaming: false, isExpanded: expanded,
                                                     symbol: "chevron.left.forwardslash.chevron.right")),
                              height: headerHeight, width: min(width, TranscriptMetrics.maxCardWidth), spacing: 6)
                    guard expanded else { continue }
                }
                let headerHeight = 6 + max(TranscriptStyle.lineHeight(self.style.caption), TranscriptMetrics.iconBox) + 6
                let size = TranscriptText.size(text, width: .greatestFiniteMagnitude)
                let part = TranscriptPart.Code(language: language, code: code, text: text, textSize: size, headerHeight: headerHeight)
                stack.add(.code(part), height: headerHeight + 1 + 10 + size.height + 10)
            case let .table(table):
                let part = self.table(table, width: width)
                stack.add(.table(part), height: part.contentSize.height, width: part.contentSize.width)
            }
        }
    }

    /// A complete fenced SVG (```svg, or any fence holding a whole `<svg>…</svg>`) drawn as an image.
    /// Unfinished ones, mid-stream, stay code until their closing tag arrives.
    static func inlineSVG(language: String, code: String) -> ImageRef? {
        let lang = language.lowercased()
        guard lang == "svg" || lang == "xml" || lang == "html" || lang == "code" else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "</svg>", options: [.caseInsensitive, .backwards]) != nil,
              SVGRasterizer.isSVG(Data(trimmed.utf8)),
              lang == "svg" || trimmed.lowercased().hasPrefix("<svg") || trimmed.hasPrefix("<?xml")
        else { return nil }
        return ImageRef(artifactId: nil, base64: Data(trimmed.utf8).base64EncodedString(), url: nil,
                        mimeType: "image/svg+xml", alt: "SVG image", width: nil, height: nil)
    }

    /// Columns share the width when each can keep a readable minimum; otherwise the table keeps
    /// its natural column widths and scrolls sideways.
    private func table(_ table: TranscriptText.Table, width available: CGFloat) -> TranscriptPart.Table {
        let columns = table.cells.first?.count ?? 0
        let minimumColumn: CGFloat = 72, maximumColumn: CGFloat = 320, padding: CGFloat = 20
        var ideals = Array(repeating: CGFloat(0), count: columns)
        for row in table.cells {
            for (column, cell) in row.enumerated() {
                ideals[column] = max(ideals[column], TranscriptText.naturalWidth(cell) + padding)
            }
        }
        ideals = ideals.map { min($0, maximumColumn) }
        let minimums = ideals.map { min($0, minimumColumn) }
        var widths = ideals
        let idealTotal = ideals.reduce(0, +), minimumTotal = minimums.reduce(0, +)
        if idealTotal > available, minimumTotal <= available {
            let slack = available - minimumTotal
            let flexible = idealTotal - minimumTotal
            widths = zip(ideals, minimums).map { ideal, minimum in
                floor(flexible > 0 ? minimum + (ideal - minimum) / flexible * slack : minimum)
            }
        }
        let heights = table.cells.map { row in
            row.enumerated().map { column, cell in
                TranscriptText.size(cell, width: max(widths[column] - padding, 1)).height
            }.max().map { max($0, TranscriptStyle.lineHeight(self.style.body)) + 10 } ?? 0
        }
        return TranscriptPart.Table(cells: table.cells, columnWidths: widths, rowHeights: heights, plainText: table.plainText)
    }

    private func thinking(_ text: String, turn: AssistantTurn, into stack: inout Stack) {
        let key = "thinking:\(turn.id)"
        let streaming = turn.isStreaming && turn.text.isEmpty
        // Thinking opened while it streamed stays open until the turn finishes.
        if streaming { self.context.disclosure.setIfUnset(key, expanded: true) }
        let expanded = self.context.disclosure.isExpanded(key, default: streaming)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
        let title = streaming ? "Thinking…" : "Thinking"
        stack.add(.thinkingHeader(.init(key: key, title: title, isStreaming: streaming, isExpanded: expanded)), height: headerHeight, width: width)
        if expanded { self.thinkingBody(text, width: width, into: &stack) }
    }

    /// A finished turn's reasoning and tool calls as one collapsible "Thinking" item, closed until opened.
    private func thinkingGroup(_ text: String, turn: AssistantTurn, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "steps:\(turn.id)"
        let expanded = self.context.disclosure.isExpanded(key, default: false)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
        var title = "Thinking"
        let count = turn.tools.count
        if count > 0 { title += " · \(count) tool call\(count == 1 ? "" : "s")" }
        stack.add(.thinkingHeader(.init(key: key, title: title, isStreaming: false, isExpanded: expanded)), height: headerHeight, width: width)
        guard expanded else { return }
        if !text.isEmpty { self.thinkingBody(text, width: width, into: &stack) }
        self.tools(turn.tools, into: &stack, layout: &layout)
    }

    private func thinkingBody(_ text: String, width: CGFloat, into stack: inout Stack) {
        let body = TranscriptText.plain(text, font: self.style.callout, color: TranscriptColors.secondary)
        stack.add(.thinkingBody(body), height: TranscriptText.size(body, width: max(width - 10, 20)).height, width: width, spacing: 6)
    }

    private func tools(_ tools: [ToolActivity], into stack: inout Stack, layout: inout TranscriptRowLayout) {
        for (index, tool) in tools.enumerated() {
            self.tool(tool, first: index == 0, into: &stack, layout: &layout)
        }
    }

    private func tool(_ tool: ToolActivity, first: Bool, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "tool:\(tool.id)"
        let expanded = self.context.disclosure.isExpanded(key, default: false)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = 6 + max(TranscriptStyle.lineHeight(self.style.calloutMonoMedium), TranscriptMetrics.iconBox) + 6
        let run = self.spawnedRun(tool)
        if tool.spawnedSessionKey != nil || tool.spawnLabel != nil { layout.hasSpawns = true }
        if let run { layout.runs[tool.id] = run }
        var sections: [TranscriptPart.Tool.Section] = []
        var runningY: CGFloat?
        var height = headerHeight
        if expanded {
            var y = headerHeight + 1 + 10
            let inner = max(width - 20, 20)
            let titleHeight = TranscriptStyle.lineHeight(self.style.captionSemibold)
            var entries: [(String, String)] = []
            if let arguments = tool.arguments, !arguments.isEmpty { entries.append(("Input", arguments)) }
            if let result = tool.result, !result.isEmpty { entries.append((tool.isError ? "Error" : "Output", result)) }
            for (index, (title, body)) in entries.enumerated() {
                if index > 0 { y += 8 }
                let limited = body.count > TranscriptMetrics.toolOutputLimit
                    ? String(body.prefix(TranscriptMetrics.toolOutputLimit)) + "\n…" : body
                let text = TranscriptText.plain(limited, font: self.style.captionMono, color: TranscriptColors.label)
                let contentHeight = TranscriptText.size(text, width: inner).height
                let visible = min(contentHeight, TranscriptMetrics.toolOutputMaxHeight)
                let titleY = y
                y += titleHeight + 4
                sections.append(.init(title: title, titleY: titleY, text: text,
                                      frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight))
                y += visible
            }
            if entries.count < 2, tool.result?.isEmpty ?? true, tool.isRunning {
                if !entries.isEmpty { y += 8 }
                runningY = y
                y += TranscriptStyle.lineHeight(self.style.caption)
            }
            height = y + 10
        }
        let part = TranscriptPart.Tool(tool: tool, key: key, isExpanded: expanded, run: run, headerHeight: headerHeight,
                                       sections: sections, runningY: runningY)
        stack.add(.tool(part), height: height, width: width, spacing: first ? TranscriptMetrics.blockSpacing : TranscriptMetrics.toolSpacing)
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

    private func images(_ refs: [ImageRef], into stack: inout Stack, layout: inout TranscriptRowLayout) {
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
                let title = ref.alt ?? link.host ?? "Open image"
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

    private func file(_ ref: FileRef, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "file:\(layout.id):\(ref.cacheKey)"
        let canExpand = ref.isText && ref.isDownloadable
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
            note = "Loading…"
            y += noteHeight
        case .failed:
            note = "Couldn’t load this file."
            y += noteHeight
        case .binary:
            note = "This file isn’t text. Save it to open it."
            y += noteHeight
        case let .text(content, truncated):
            let text = TranscriptText.plain(content.isEmpty ? "(empty file)" : content, font: self.style.captionMono,
                                            color: content.isEmpty ? TranscriptColors.secondary : TranscriptColors.label)
            let contentHeight = TranscriptText.size(text, width: inner).height
            let visible = min(contentHeight, TranscriptMetrics.filePreviewMaxHeight)
            section = .init(title: ref.name, titleY: 0, text: text,
                            frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight)
            y += visible
            if truncated {
                y += 8
                noteY = y
                note = "Showing the start of the file. Save it to see the rest."
                y += noteHeight
            }
        }
        let part = TranscriptPart.File(ref: ref, key: key, canExpand: true, isExpanded: true, headerHeight: headerHeight,
                                       section: section, note: note, noteY: noteY)
        stack.add(.file(part), height: y + 10, width: width)
    }
}

// MARK: Message footers

extension TranscriptLayoutBuilder {
    fileprivate func messageFooter(_ turn: AssistantTurn, message index: Int, into stack: inout Stack) {
        let time = turn.textTimestamps.indices.contains(index) ? turn.textTimestamps[index] : turn.timestamp
        self.footer(key: "\(turn.id):\(index)", copy: turn.text[index], time: time ?? turn.timestamp,
                    model: self.model(of: turn, message: index), into: &stack)
    }

    /// Model that wrote a message, falling back to the turn's when the message didn't record one.
    fileprivate func model(of turn: AssistantTurn, message index: Int) -> String? {
        let own = turn.textModelNames.indices.contains(index) ? turn.textModelNames[index] : nil
        return own ?? turn.modelName
    }

    fileprivate func footer(key: String, copy text: String, time: Date?, model: String?, into stack: inout Stack) {
        let details = [model, time?.messageDetailTimestamp].compactMap(\.self).joined(separator: " · ")
        let height = max(TranscriptStyle.lineHeight(self.style.caption), 16)
        stack.add(.footer(.init(key: key, copyText: text, details: details)), height: height, spacing: TranscriptMetrics.footerSpacing)
    }
}
