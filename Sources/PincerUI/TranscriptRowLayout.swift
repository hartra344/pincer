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
        /// An SF Symbol drawn instead of the initial, for senders that aren't agents.
        var symbol: String?
        /// The agent's companion, drawn instead of the initial when animated avatars are on.
        var creature: AvatarStyle?
        var state = AvatarState.idle
        /// The agent's, not the owner's: the latest reply's can come alive.
        var isAgent = false
        /// Staggers blinks between agents.
        var seed = ""
    }

    struct Header {
        let name: String
        let badge: String?
        let time: String?
        let isPending: Bool
        /// Chat the badge opens when clicked, e.g. the one a forwarded message came from.
        var link: TranscriptRowLayout.SourceChat?
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

        /// The Copy and "Show all lines" controls of a diff, in card coordinates.
        struct Diff {
            let copyText: String
            let copyFrame: CGRect
            /// Disclosure key of the full diff, and the toggle's title and frame when it has one.
            let key: String
            let isExpanded: Bool
            let toggleTitle: String?
            let toggleFrame: CGRect
        }

        let tool: ToolActivity
        let key: String
        let isExpanded: Bool
        let run: Run?
        let headerHeight: CGFloat
        let sections: [Section]
        /// Where "Running…" goes when there's no output yet.
        let runningY: CGFloat?
        /// The call read as a file diff; the card then shows it in place of the raw input.
        var edit: ToolFileEdit?
        var diff: Diff?
    }

    /// The line under a message: a Copy button and details such as when it was sent.
    struct Footer {
        /// Tells a recycled footer it now shows a different message, so "Copied" resets.
        let key: String
        let copyText: String
        let details: String
        /// The message Reply and React act on; nil hides them.
        var messageId: String?
    }

    /// Where an unsent message is: queued, or failed with Retry and Delete.
    struct SendStatus: Equatable {
        /// The outbox entry (the message's idempotency key).
        let id: String
        let text: String
        let isFailed: Bool
        let canRetry: Bool
        let canDelete: Bool
        /// Full reason, for the tooltip.
        var detail: String?
        /// For VoiceOver: "Not sent yet, queued.", "Sending." or "Failed to send: reason."
        var spoken: String = ""
    }

    /// The message a reply quotes, above its text. Tapping it jumps to the original.
    struct ReplyQuote {
        let targetId: String
        let sender: String?
        let preview: NSAttributedString
        let previewHeight: CGFloat
        /// Older history is being paged in to find the original.
        let isLocating: Bool
    }

    /// Emoji reaction chips under a message, wrapping onto more lines as needed.
    struct Reactions {
        struct Chip {
            let emoji: String
            /// Shown next to the emoji when two or more reacted.
            let count: Int
            let includesYou: Bool
            /// The transient 👀 while the agent works on the message: subdued and not tappable.
            let isAck: Bool
            /// In the part's coordinates.
            let frame: CGRect
            let reactors: String
            let accessibilityLabel: String
        }

        let messageId: String
        let chips: [Chip]
        /// The "add reaction" button after the chips, when there are any.
        let addFrame: CGRect?
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
    case replyQuote(ReplyQuote)
    case reactions(Reactions)
    case sendStatus(SendStatus)
    /// A brief tint over the message a quote jumped to.
    case flash

    enum Kind: Hashable {
        case avatar, header, text, quote, thinkingBody, rule, code, table, thinkingHeader, tool, image,
             imageLink, file, typing, footer, marker, loading, replyQuote, reactions, sendStatus, flash
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
        case .replyQuote: .replyQuote
        case .reactions: .reactions
        case .sendStatus: .sendStatus
        case .flash: .flash
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

    /// Where one message of the row sits, for menus and the jump-to-original flash.
    struct MessageSpan {
        let id: String
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// The chat a forwarded message came from, which the row can open.
    struct SourceChat: Equatable {
        let sessionKey: String
        /// "Open Kiko’s Chat", for the badge, menus and VoiceOver.
        let title: String
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
    var sourceChat: SourceChat?
    var accessibilityLabel = ""
    /// Where Find's selected match is, in row coordinates (the bottom of its line), when this row has it.
    var matchY: CGFloat?
    /// The row's messages that replies and reactions can target, top to bottom.
    var messages: [MessageSpan] = []
    /// An unsent message's status, for the row's context menu and accessibility actions.
    var sendStatus: TranscriptPart.SendStatus?
    /// Reply and reaction state this layout was built with, to tell when it's stale.
    var decoration = TranscriptDecoration()
    /// Distinct for every layout built, so a view can tell it already shows this one.
    var serial = 0

    /// The message at `y` (row coordinates), or the row's last one outside them all.
    func message(at y: CGFloat?) -> String? {
        if let y, let span = self.messages.first(where: { y >= $0.minY && y <= $0.maxY }) { return span.id }
        return self.messages.last?.id
    }
}

/// What a row shows besides its own content: its quote card, reaction chips, the 👀 while the
/// agent works, and the flash after a jump. Rows are laid out again when it changes.
struct TranscriptDecoration: Equatable {
    var quote: ReplyQuote?
    var isLocating = false
    var reactions: [String: [ReactionGroup]] = [:]
    var ack: String?
    var flash: String?
}

/// Settings that change how rows look. Read from the same defaults the Settings screen writes,
/// plus the session's own `reasoningLevel`.
struct TranscriptSettings: Equatable {
    var thinking: ThinkingDisplay
    var reactionsEnabled = false
    /// The session has reasoning turned off on the Gateway, so no reasoning text is shown at all.
    var reasoningOff = false
    /// Colors are baked into layouts (avatars) and drawn by row views, so a theme change redoes them.
    var theme = AppTheme()
    /// The agent's companion, when animated avatars are on.
    var avatarStyle: AvatarStyle?
    /// Every agent's companion by id, for messages other agents sent here.
    var agentStyles: [String: AvatarStyle] = [:]

    @MainActor static func current(for context: TranscriptContext) -> TranscriptSettings {
        let animated = AvatarSettings.isEnabled
        return TranscriptSettings(
            thinking: ThinkingDisplay.current,
            reactionsEnabled: ReactionFeature.isEnabled,
            reasoningOff: context.gateway.sessions[context.sessionKey]?.reasoningLevel == "off",
            theme: AppTheme.current,
            avatarStyle: animated ? AvatarSettings.style(for: context.agent) : nil,
            agentStyles: animated
                ? Dictionary(context.gateway.agents.map { ($0.id, AvatarSettings.style(for: $0)) }) { first, _ in first }
                : [:])
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
    var highlight = TranscriptHighlight()
    /// The message to flash, after jumping to it from a quote.
    var flash: String?
    /// Find matches counted so far in the row being laid out, per section.
    let marks = TranscriptFindMarks()

    private var style: TranscriptStyle { TranscriptStyle.shared }

    func layout(_ row: TranscriptRow, width: CGFloat) -> TranscriptRowLayout {
        var layout = TranscriptRowLayout(id: row.id, width: width)
        var streamingReply = false
        if case let .entry(.assistant(turn)) = row { streamingReply = turn.isStreaming }
        if let chat = self.context.chat, !streamingReply {
            // A reply that commits (or a run that ends) leaves its live memo behind: drop what this chat no longer streams.
            TranscriptText.endLive(owner: ObjectIdentifier(chat), keeping: chat.liveRunId.map { "live-\($0)" })
        }
        layout.decoration = self.decoration(for: row)
        self.marks.reset(row: row.id, highlight: self.highlight)
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
        if let flash = layout.decoration.flash, let span = layout.messages.first(where: { $0.id == flash }) {
            let x = TranscriptMetrics.contentX - 6
            let frame = CGRect(x: x, y: max(span.minY - 4, 0), width: max(width - x - TranscriptMetrics.sidePadding + 12, 1),
                               height: span.maxY - span.minY + 8)
            layout.parts.append(.init(part: .flash, frame: frame))
            layout.matchY = span.minY + min(span.maxY - span.minY, 20)
        }
        return layout
    }

    /// Reply and reaction state for a row, read from the chat.
    func decoration(for row: TranscriptRow) -> TranscriptDecoration {
        var decoration = TranscriptDecoration()
        guard case let .entry(entry) = row, let chat = self.context.chat else { return decoration }
        var agent = self.context.agent.name
        var ids: [String] = []
        switch entry {
        case let .user(item):
            if let quote = chat.quote(for: item) {
                decoration.quote = quote
                decoration.isLocating = chat.locatingReplyId == quote.targetId
            }
            if item.isReplyable, let id = item.transcriptId {
                ids = [id]
                if self.settings.reactionsEnabled, chat.ackMessageId == id { decoration.ack = id }
            }
        case let .assistant(turn):
            ids = turn.textIds.compactMap(\.self)
            if let sender = turn.sender { agent = sender.displayName(agents: self.context.gateway.agents) }
        case .marker:
            break
        }
        for id in ids {
            if self.settings.reactionsEnabled {
                let groups = chat.reactionGroups(for: id, agentName: agent)
                if !groups.isEmpty { decoration.reactions[id] = groups }
            }
            if id == self.flash { decoration.flash = id }
        }
        return decoration
    }

    // MARK: Rows

    private func user(_ item: ChatItem, into layout: inout TranscriptRowLayout) {
        let header = TranscriptPart.Header(name: Owner.displayName, badge: item.via.map { "via \($0)" },
                                           time: item.timestamp?.chatTimestamp, isPending: item.isAwaitingDelivery)
        let text = item.plainText
        let messageId = item.isReplyable ? item.transcriptId : nil
        let contentWidth = max(layout.width - TranscriptMetrics.contentX - TranscriptMetrics.sidePadding, 40)
        let quote = layout.decoration.quote.map {
            self.replyQuote($0, isLocating: layout.decoration.isLocating, width: min(contentWidth, TranscriptMetrics.maxCardWidth))
        }
        let sendStatus = Self.sendStatus(item)
        layout.sendStatus = sendStatus
        layout.alpha = item.isPending && sendStatus?.isFailed != true ? 0.7 : 1
        layout.copyItems = [.init(title: "Copy Text", text: text)]
        let attachments = item.blocks.filter { if case .image = $0 { true } else if case .file = $0 { true } else { false } }.count
        layout.accessibilityLabel = AccessibilityText.messageRow(
            role: .user, text: text, timestamp: header.time, attachmentCount: attachments,
            isPending: item.isPending && sendStatus == nil, via: item.via, summaryLimit: 0)
        if let sendStatus { layout.accessibilityLabel += ". \(sendStatus.spoken)" }
        if let quote {
            layout.accessibilityLabel = "In reply to \(quote.sender ?? "a message"): \(quote.preview.string). " + layout.accessibilityLabel
        }
        self.scaffold(avatar: .init(text: Owner.initials, emoji: nil, color: TranscriptColors.ownerAvatar),
                      header: header, into: &layout) { stack, layout in
            if let quote {
                stack.add(.replyQuote(quote), height: Self.quoteHeight(quote), width: min(stack.width, TranscriptMetrics.maxCardWidth))
            }
            if !text.isEmpty { self.markdown(text, tone: .primary, section: .message(0), into: &stack, layout: &layout) }
            let images = item.blocks.compactMap { block -> ImageRef? in
                if case let .image(ref) = block { return ref }
                return nil
            }
            self.images(images, into: &stack, layout: &layout)
            for block in item.blocks {
                if case let .file(file) = block { self.file(file, into: &stack, layout: &layout) }
            }
            if let messageId { self.reactions(on: messageId, into: &stack, layout: layout) }
            if let sendStatus {
                stack.add(.sendStatus(sendStatus), height: max(TranscriptStyle.lineHeight(self.style.caption), 16),
                          spacing: TranscriptMetrics.footerSpacing)
            }
            if !item.isPending, !text.isEmpty || messageId != nil {
                self.footer(key: "\(item.id):0", copy: text, time: item.timestamp, model: nil, messageId: messageId, into: &stack)
            }
            if let messageId {
                layout.messages.append(.init(id: messageId, minY: TranscriptMetrics.verticalPadding, maxY: stack.y))
            }
        }
    }

    /// The status line of a queued or failed message; nil while sending and once accepted.
    static func sendStatus(_ item: ChatItem) -> TranscriptPart.SendStatus? {
        guard item.isPending, let state = item.outboxState, let id = item.idempotencyKey else { return nil }
        switch state {
        case .queued:
            return .init(id: id, text: "Queued", isFailed: false, canRetry: false, canDelete: true, spoken: "Not sent yet, queued.")
        case .sending:
            return .init(id: id, text: "Sending…", isFailed: false, canRetry: false, canDelete: false, spoken: "Sending.")
        case let .failed(failure):
            let prefix = "Couldn’t send: "
            let reason = failure.message.hasPrefix(prefix) ? String(failure.message.dropFirst(prefix.count)) : failure.message
            let sentence = reason.hasSuffix(".") ? reason : reason + "."
            return .init(id: id, text: reason.isEmpty ? "Failed" : "Failed — \(reason)", isFailed: true,
                         canRetry: failure.retryable, canDelete: true, detail: failure.message,
                         spoken: reason.isEmpty ? "Failed to send." : "Failed to send: \(sentence)")
        }
    }

    /// The end of a streaming reply, so the spoken label costs the same however long the reply has grown.
    private static func spokenTail(of body: String, limit: Int = 1200) -> String {
        guard body.utf8.count > limit else { return body }
        let start = body.utf8.index(body.endIndex, offsetBy: -limit, limitedBy: body.startIndex) ?? body.startIndex
        return String(body[start...].drop { !$0.isNewline && $0 != " " })
    }

    private func assistant(_ turn: AssistantTurn, into layout: inout TranscriptRowLayout) {
        let agent = self.context.agent
        let from = turn.sender.map { self.sender($0) }
        layout.sourceChat = from?.source
        var header = TranscriptPart.Header(name: from?.name ?? agent.name, badge: from?.marker,
                                           time: turn.timestamp?.chatTimestamp, isPending: false)
        header.link = from?.source
        let thinking = turn.thinking.joined(separator: "\n\n")
        let body = turn.body
        layout.copyItems = [.init(title: "Copy Reply", text: body)]
        if !thinking.isEmpty { layout.copyItems.append(.init(title: "Copy Thinking", text: thinking)) }
        layout.accessibilityLabel = AccessibilityText.messageRow(
            role: .assistant, author: AccessibilityText.join([header.name, from?.marker]),
            text: turn.isStreaming ? Self.spokenTail(of: body) : body, timestamp: header.time,
            toolCount: turn.tools.count, attachmentCount: turn.images.count + turn.files.count,
            isStreaming: turn.isStreaming, isError: turn.isError, summaryLimit: 0)
        let reasoning = self.settings.reasoningOff ? "" : thinking
        let hasSteps = !reasoning.isEmpty || !turn.tools.isEmpty
        let hasReply = !turn.text.isEmpty || !turn.images.isEmpty || !turn.files.isEmpty
        let steps: ThinkingSteps = switch self.settings.thinking {
        case _ where !hasSteps: .hidden
        // Find's selected match is in the steps, which this setting would hide: show them for now.
        case _ where !turn.isStreaming && self.highlight.revealsSteps(of: layout.id): .grouped
        case .none: .hidden
        case _ where turn.isStreaming: .live
        case .all: .grouped
        // A finished turn with nothing else to show keeps its steps, folded, so it isn't blank.
        case .live: hasReply ? .hidden : .grouped
        }
        let avatar = from?.avatar ?? TranscriptPart.Avatar(
            text: String(agent.name.prefix(1)).uppercased(), emoji: agent.emoji,
            color: TranscriptColors.agentAvatar, creature: self.settings.avatarStyle,
            state: turn.isStreaming ? .streaming : .idle, isAgent: true, seed: agent.id)
        self.scaffold(avatar: avatar,
                      header: header, into: &layout) { stack, layout in
            switch steps {
            case .hidden:
                break
            case .live:
                if !reasoning.isEmpty { self.thinking(reasoning, turn: turn, into: &stack, layout: &layout) }
                self.tools(turn.tools, into: &stack, layout: &layout)
            case .grouped:
                self.thinkingGroup(reasoning, turn: turn, into: &stack, layout: &layout)
            }
            // Each message gets its own footer, which with the gap after it keeps back-to-back
            // messages apart. The last footer goes under the turn's images and files.
            let showFooters = !turn.isStreaming
            let last = turn.text.count - 1
            var start: CGFloat = 0
            for (index, message) in turn.text.enumerated() {
                if index > 0 { stack.y += TranscriptMetrics.messageSpacing - TranscriptMetrics.blockSpacing }
                start = stack.isEmpty ? stack.y : stack.y + TranscriptMetrics.blockSpacing
                self.markdown(message, tone: turn.isError ? .error : .primary, section: .message(index), live: turn.isStreaming,
                              into: &stack, layout: &layout)
                guard index < last else { continue }
                let id = Self.messageId(turn, index)
                if let chipId = Self.chipId(turn, index) {
                    self.reactions(on: chipId, canAdd: id != nil, into: &stack, layout: layout)
                }
                if showFooters { self.messageFooter(turn, message: index, into: &stack) }
                if let id { layout.messages.append(.init(id: id, minY: start, maxY: stack.y)) }
            }
            self.images(turn.images, into: &stack, layout: &layout)
            for file in turn.files { self.file(file, into: &stack, layout: &layout) }
            if !turn.text.isEmpty {
                let id = Self.messageId(turn, last)
                if let chipId = Self.chipId(turn, last) {
                    self.reactions(on: chipId, canAdd: id != nil, into: &stack, layout: layout)
                }
                if showFooters { self.messageFooter(turn, message: last, into: &stack) }
                if let id { layout.messages.append(.init(id: id, minY: start, maxY: stack.y)) }
            }
            let showsActivity = steps == .live && (!reasoning.isEmpty || turn.tools.contains(where: \.isRunning))
            if turn.isStreaming, turn.text.isEmpty, !showsActivity {
                stack.add(.typing, height: 14, width: 26)
            }
        }
    }

    private enum ThinkingSteps { case hidden, live, grouped }

    /// How a message another agent, an automation or a helper sent here is shown: as theirs.
    private func sender(_ sender: MessageSender) -> (name: String, marker: String, avatar: TranscriptPart.Avatar,
                                                     source: TranscriptRowLayout.SourceChat?)
    {
        let agents = self.context.gateway.agents
        let name = sender.displayName(agents: agents)
        let marker = sender.marker(agents: agents, receivingAgentId: self.context.agent.id)
        let agent = sender.agent(in: agents)
        // Never live: the companion on the latest reply shows what this chat's agent is doing.
        var avatar = TranscriptPart.Avatar(text: String(name.prefix(1)).uppercased(), emoji: agent?.emoji,
                                           color: TranscriptColors.agentAvatar, seed: sender.agentId ?? name)
        switch sender.kind {
        case .agent: avatar.creature = agent.flatMap { self.settings.agentStyles[$0.id] }
        case .automation: avatar.symbol = "clock.arrow.circlepath"
        case .helper: avatar.symbol = "sparkles"
        }
        let source = sender.sessionKey.flatMap { key in
            sender.canOpenSource && key != self.context.sessionKey
                ? TranscriptRowLayout.SourceChat(sessionKey: key, title: L("Open \(name)’s Chat")) : nil
        }
        return (name, marker, avatar, source)
    }

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

    private func markdown(_ source: String, tone: TranscriptText.Tone, section: TranscriptSearch.Section, live: Bool = false,
                          into stack: inout Stack, layout: inout TranscriptRowLayout)
    {
        let width = stack.width
        // A streaming message is split into frozen chunks and a tail; a committed one is one cached list.
        let pieces: [TranscriptText.LiveSegment] = live
            ? TranscriptText.liveMarkdown(source, tone: tone, row: layout.id, owner: self.context.chat.map(ObjectIdentifier.init))
            : TranscriptText.markdown(source, tone: tone).map { .init(segment: $0, isFrozen: false, extraSpacing: 0) }
        for piece in pieces {
            let spacing = TranscriptMetrics.blockSpacing + piece.extraSpacing
            switch piece.segment {
            case let .text(source):
                let (text, match) = self.marks.mark(source, section)
                let size = live ? TranscriptText.liveSize(text, width: width, frozen: piece.isFrozen && text === source, exact: true)
                    : TranscriptText.size(text, width: width)
                stack.add(.text(text), height: size.height, spacing: spacing)
                self.marks.place(match, in: text, width: width, stack: stack, into: &layout)
            case let .quote(source):
                let (text, match) = self.marks.mark(source, section)
                let quoteWidth = max(width - 11, 20)
                let size = live ? TranscriptText.liveSize(text, width: quoteWidth, frozen: piece.isFrozen && text === source, exact: false)
                    : TranscriptText.size(text, width: quoteWidth)
                stack.add(.quote(text), height: size.height, spacing: spacing)
                self.marks.place(match, in: text, width: max(width - 11, 20), stack: stack, into: &layout)
            case .rule:
                stack.add(.rule, height: 1)
            case let .code(language, code, source):
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
                // Find skips SVG source, which is usually shown as the image.
                let isSVG = SVGSource.inlineSource(language: language, code: code) != nil
                let (text, match) = isSVG ? (source, nil) : self.marks.mark(source, section)
                let size = live ? TranscriptText.liveSize(text, width: .greatestFiniteMagnitude, frozen: piece.isFrozen && text === source, exact: false)
                    : TranscriptText.size(text, width: .greatestFiniteMagnitude)
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
                let part = self.table(table, width: width)
                stack.add(.table(part), height: part.contentSize.height, width: part.contentSize.width)
                if found, let frame = stack.parts.last?.frame { layout.matchY = frame.minY + min(frame.height, 40) }
            }
        }
    }

    /// A complete fenced SVG (```svg, or any fence holding a whole `<svg>…</svg>`) drawn as an image.
    /// Unfinished ones, mid-stream, stay code until their closing tag arrives.
    static func inlineSVG(language: String, code: String) -> ImageRef? {
        guard let trimmed = SVGSource.inlineSource(language: language, code: code) else { return nil }
        return InlineSVGCache.ref(for: trimmed)
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

    private func thinking(_ text: String, turn: AssistantTurn, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let key = "thinking:\(turn.id)"
        let streaming = turn.isStreaming && turn.text.isEmpty
        // Thinking opened while it streamed stays open until the turn finishes.
        if streaming { self.context.disclosure.setIfUnset(key, expanded: true) }
        let expanded = self.context.disclosure.isExpanded(key, default: streaming)
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        let headerHeight = max(TranscriptStyle.lineHeight(self.style.calloutMedium), TranscriptMetrics.iconBox)
        let title = streaming ? "Thinking…" : "Thinking"
        stack.add(.thinkingHeader(.init(key: key, title: title, isStreaming: streaming, isExpanded: expanded)), height: headerHeight, width: width)
        if expanded { self.thinkingBody(text, width: width, into: &stack, layout: &layout) }
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
        if !text.isEmpty { self.thinkingBody(text, width: width, into: &stack, layout: &layout) }
        self.tools(turn.tools, into: &stack, layout: &layout)
    }

    private func thinkingBody(_ text: String, width: CGFloat, into stack: inout Stack, layout: inout TranscriptRowLayout) {
        let (body, match) = self.marks.mark(TranscriptText.plain(text, font: self.style.callout, color: TranscriptColors.secondary), .thinking)
        stack.add(.thinkingBody(body), height: TranscriptText.size(body, width: max(width - 10, 20)).height, width: width, spacing: 6)
        self.marks.place(match, in: body, width: max(width - 10, 20), stack: stack, into: &layout)
    }

    private func tools(_ tools: [ToolActivity], into stack: inout Stack, layout: inout TranscriptRowLayout) {
        for (index, tool) in tools.enumerated() {
            self.tool(tool, first: index == 0, into: &stack, layout: &layout)
        }
    }

    private func tool(_ tool: ToolActivity, first: Bool, into stack: inout Stack, layout: inout TranscriptRowLayout) {
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
        var height = headerHeight
        if expanded {
            var y = headerHeight + 1 + 10
            let inner = max(width - 20, 20)
            let titleHeight = TranscriptStyle.lineHeight(self.style.captionSemibold)
            var entries: [(String, String)] = []
            if let edit {
                let placed = self.diff(edit, tool: tool, row: layout.id, width: width, y: y)
                sections.append(placed.section)
                diff = placed.diff
                if let match = placed.match {
                    toolMatchY = placed.section.frame.minY
                        + min(self.marks.lineBottom(of: match, in: placed.section.text, width: inner), placed.section.frame.height)
                }
                y = placed.bottom
            } else if let arguments = tool.arguments, !arguments.isEmpty {
                entries.append(("Input", arguments))
            }
            if let result = tool.result, !result.isEmpty { entries.append((tool.isError ? "Error" : "Output", result)) }
            for (index, (title, body)) in entries.enumerated() {
                if index > 0 || edit != nil { y += 8 }
                let limited = body.count > TranscriptMetrics.toolOutputLimit
                    ? String(body.prefix(TranscriptMetrics.toolOutputLimit)) + "\n…" : body
                let (text, match) = self.marks.mark(
                    TranscriptText.plain(limited, font: self.style.captionMono, color: TranscriptColors.label), .tool(tool.id))
                let contentHeight = TranscriptText.size(text, width: inner).height
                let visible = min(contentHeight, TranscriptMetrics.toolOutputMaxHeight)
                let titleY = y
                y += titleHeight + 4
                if let match {
                    // Relative to the card for now; moved into row coordinates once the card is placed.
                    toolMatchY = y + min(self.marks.lineBottom(of: match, in: text, width: inner), visible)
                }
                sections.append(.init(title: title, titleY: titleY, text: text,
                                      frame: CGRect(x: 10, y: y, width: inner, height: visible), contentHeight: contentHeight))
                y += visible
            }
            if entries.count < 2, tool.result?.isEmpty ?? true, tool.isRunning {
                if !entries.isEmpty || edit != nil { y += 8 }
                runningY = y
                y += TranscriptStyle.lineHeight(self.style.caption)
            }
            height = y + 10
        }
        let part = TranscriptPart.Tool(tool: tool, key: key, isExpanded: expanded, run: run, headerHeight: headerHeight,
                                       sections: sections, runningY: runningY, edit: edit, diff: diff)
        stack.add(.tool(part), height: height, width: width, spacing: first ? TranscriptMetrics.blockSpacing : TranscriptMetrics.toolSpacing)
        if let toolMatchY, let frame = stack.parts.last?.frame { layout.matchY = frame.minY + toolMatchY }
    }

    /// An edit card's diff: a "Changes" title with Copy, the colored lines (the first few when it's
    /// long and not opened in full), and a toggle to show all or fewer lines.
    private func diff(_ edit: ToolFileEdit, tool: ToolActivity, row: String, width: CGFloat, y top: CGFloat)
        -> (section: TranscriptPart.Tool.Section, diff: TranscriptPart.Tool.Diff, match: NSRange?, bottom: CGFloat)
    {
        let key = "diff:\(tool.id)"
        // Find counts every line of the diff, so while it has matches in this row nothing is hidden.
        let finding = self.highlight.isActive && self.highlight.options.includeTools && self.highlight.rows.contains(row)
        let showsAll = finding || self.context.disclosure.isExpanded(key, default: false)
        let (rows, hidden) = edit.rows(collapsed: !showsAll)
        let inner = max(width - 20, 20)
        let copySize = TranscriptLabelButton.size(title: "Copied")
        let titleRow = max(TranscriptStyle.lineHeight(self.style.captionSemibold), copySize.height)
        var y = top
        let copyFrame = CGRect(x: width - 10 - copySize.width, y: y + (titleRow - copySize.height) / 2,
                               width: copySize.width, height: copySize.height)
        let titleY = y + (titleRow - TranscriptStyle.lineHeight(self.style.captionSemibold)) / 2
        y += titleRow + 4
        let (text, match) = self.marks.mark(TranscriptDiffText.text(rows), .tool(tool.id))
        let contentHeight = TranscriptText.size(text, width: inner).height
        let visible = min(contentHeight, TranscriptMetrics.diffMaxHeight)
        let section = TranscriptPart.Tool.Section(title: "Changes", titleY: titleY, text: text,
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
                    model: self.model(of: turn, message: index), messageId: Self.messageId(turn, index), into: &stack)
    }

    /// Transcript id of one message of a turn, when replies and reactions can target it.
    fileprivate static func messageId(_ turn: AssistantTurn, _ index: Int) -> String? {
        guard !turn.isStreaming, turn.textIds.indices.contains(index) else { return nil }
        return turn.textIds[index]
    }

    /// Transcript id of one message of a turn whose reactions show. Committed messages keep their
    /// chips while the rest of the turn streams, though Reply and React wait for it to finish.
    fileprivate static func chipId(_ turn: AssistantTurn, _ index: Int) -> String? {
        turn.textIds.indices.contains(index) ? turn.textIds[index] : nil
    }

    /// Model that wrote a message, falling back to the turn's when the message didn't record one.
    fileprivate func model(of turn: AssistantTurn, message index: Int) -> String? {
        // Someone else's model, which this chat doesn't know.
        guard turn.sender == nil else { return nil }
        let own = turn.textModelNames.indices.contains(index) ? turn.textModelNames[index] : nil
        return own ?? turn.modelName
    }

    fileprivate func footer(key: String, copy text: String, time: Date?, model: String?, messageId: String?,
                            into stack: inout Stack)
    {
        let details = [model, time?.messageDetailTimestamp].compactMap(\.self).joined(separator: " · ")
        let height = max(TranscriptStyle.lineHeight(self.style.caption), 16)
        stack.add(.footer(.init(key: key, copyText: text, details: details, messageId: messageId)), height: height,
                  spacing: TranscriptMetrics.footerSpacing)
    }
}

// MARK: Replies and reactions

extension TranscriptLayoutBuilder {
    static let quoteInset: CGFloat = 10
    static let quotePadding: CGFloat = 6
    static let quoteSpinner: CGFloat = 18

    fileprivate func replyQuote(_ quote: ReplyQuote, isLocating: Bool, width: CGFloat) -> TranscriptPart.ReplyQuote {
        let sender: String? = switch quote.sender {
        case .you: Owner.displayName
        case .agent: self.context.agent.name
        case let .label(label): label
        case nil: nil
        }
        let style = self.style
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let preview = NSAttributedString(string: quote.text ?? "Original message", attributes: [
            .font: style.callout, .foregroundColor: TranscriptColors.secondary, .paragraphStyle: paragraph,
        ])
        let lineHeight = TranscriptStyle.lineHeight(style.callout)
        let natural = TranscriptText.size(preview, width: Self.quoteTextWidth(width)).height
        return TranscriptPart.ReplyQuote(targetId: quote.targetId, sender: sender, preview: preview,
                                         previewHeight: min(max(natural, lineHeight), lineHeight * 2), isLocating: isLocating)
    }

    static func quoteTextWidth(_ cardWidth: CGFloat) -> CGFloat {
        max(cardWidth - self.quoteInset - self.quotePadding, 20)
    }

    static var quoteSenderHeight: CGFloat { TranscriptStyle.lineHeight(TranscriptStyle.shared.captionSemibold) }

    /// Accent bar, sender line and at most two lines of preview.
    fileprivate static func quoteHeight(_ quote: TranscriptPart.ReplyQuote) -> CGFloat {
        self.quotePadding + self.quoteSenderHeight + 2 + quote.previewHeight + self.quotePadding
    }

    static var chipHeight: CGFloat { TranscriptStyle.lineHeight(TranscriptStyle.shared.callout) + 6 }
    static let chipSpacing: CGFloat = 6

    static func chipWidth(emoji: String, count: Int) -> CGFloat {
        let style = TranscriptStyle.shared
        var width = 8 + ceil(NSAttributedString(string: emoji, attributes: [.font: style.callout]).size().width) + 8
        if count >= 2 {
            width += 4 + ceil(NSAttributedString(string: "\(count)", attributes: [.font: style.captionSemibold]).size().width)
        }
        return width
    }

    /// Chips for a message's reactions (and the 👀 while the agent works on it), wrapped to the width.
    fileprivate func reactions(on messageId: String, canAdd: Bool = true, into stack: inout Stack, layout: TranscriptRowLayout) {
        guard self.settings.reactionsEnabled else { return }
        let groups = layout.decoration.reactions[messageId] ?? []
        let showsAck = layout.decoration.ack == messageId && !groups.contains { $0.emoji == Reactions.ackEmoji }
        guard !groups.isEmpty || showsAck else { return }
        let height = Self.chipHeight, spacing = Self.chipSpacing
        let width = min(stack.width, TranscriptMetrics.maxCardWidth)
        var x: CGFloat = 0, y: CGFloat = 0
        func place(_ chipWidth: CGFloat) -> CGRect {
            if x > 0, x + chipWidth > width {
                x = 0
                y += height + spacing
            }
            let frame = CGRect(x: x, y: y, width: min(chipWidth, width), height: height)
            x += chipWidth + spacing
            return frame
        }
        var chips = groups.map { group in
            TranscriptPart.Reactions.Chip(
                emoji: group.emoji, count: group.count, includesYou: group.includesYou, isAck: false,
                frame: place(Self.chipWidth(emoji: group.emoji, count: group.count)),
                reactors: group.reactorsText, accessibilityLabel: group.accessibilityLabel)
        }
        if showsAck {
            let working = "\(self.context.agent.name) is working on this"
            chips.append(.init(emoji: Reactions.ackEmoji, count: 1, includesYou: false, isAck: true,
                               frame: place(Self.chipWidth(emoji: Reactions.ackEmoji, count: 1)),
                               reactors: working, accessibilityLabel: working))
        }
        let addFrame = groups.isEmpty || !canAdd ? nil : place(height + 14)
        stack.add(.reactions(.init(messageId: messageId, chips: chips, addFrame: addFrame)), height: y + height, width: width,
                  spacing: 6)
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
                           mimeType: "image/svg+xml", alt: "SVG image", width: nil, height: nil)
        if refs.count >= limit { refs.removeAll(keepingCapacity: true) }
        refs[source] = ref
        return ref
    }
}
