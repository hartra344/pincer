import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        /// Bounded raw prefix key only; the plain-text excerpt is prepared off-main on demand.
        var openingExcerptSource: MessagePartExcerptSource?
    }

    /// The chat a forwarded message came from, which the row can open.
    struct SourceChat: Equatable {
        let sessionKey: String
        /// "Open Kiko’s Chat", for the badge, menus and VoiceOver.
        let title: String
    }

    /// What a page card was built from: the preview's and screenshot's image refs at layout time.
    struct PageSource: Equatable {
        let url: URL
        let tabKey: String
        var imageKey: String?
        var faviconKey: String?
        var screenshotKey: String?
        /// Whether this is the latest turn for its tab, the only card the screenshot hook applies to.
        var screenshotEligible = false
        let turnId: String
    }

    let id: String
    let width: CGFloat
    var parts: [Placed] = []
    var height: CGFloat = 0
    var alpha: CGFloat = 1
    var copyItems: [CopyItem] = []
    /// Images this row shows, so it can be laid out again when one loads.
    var images: [ImageRef] = []
    /// Browser page cards this row shows, so it can be laid out again when their images arrive.
    var pages: [PageSource] = []
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

/// "2 / 2" in a message's footer: the active branch's 1-based number, how many there are, and
/// whether they can be switched right now (the controls stay, dimmed, when not).
struct BranchPosition: Equatable {
    let number: Int
    let count: Int
    let canSwitch: Bool

    var label: String { "\(self.number) / \(self.count)" }
}

/// What a row shows besides its own content: its quote card, reaction chips, the 👀 while the
/// agent works, and the flash after a jump. Rows are laid out again when it changes.
struct TranscriptDecoration: Equatable {
    var quote: ReplyQuote?
    var isLocating = false
    /// Quotes on an assistant row's messages, by message id.
    var messageQuotes: [String: ReplyQuote] = [:]
    var reactions: [String: [ReactionGroup]] = [:]
    /// The row's messages you've bookmarked.
    var bookmarks: Set<String> = []
    /// The active branch's place among the chat's branches, on the message they fork at.
    var branch: BranchPosition?
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
    /// Dark Mode, for the palette baked into rendered diagrams and math.
    var dark = false
    /// Explicit accessibility snapshot: AppKit can canonicalize dynamic color appearances to Aqua.
    var increasedContrast = false
    /// The agent's companion, when animated avatars are on.
    var avatarStyle: AvatarStyle?
    /// Every agent's companion by id, for messages other agents sent here.
    var agentStyles: [String: AvatarStyle] = [:]
    /// MCP tool cards offer "Open MCP Server", so their layouts depend on it.
    var supportsMCPServers = false
    /// Names (and their transcript spellings) of the configured MCP servers; nil until the config has loaded.
    var mcpServerNames: Set<String>?

    @MainActor static func current(for context: TranscriptContext) -> TranscriptSettings {
        let animated = AvatarSettings.isEnabled
        #if os(macOS)
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #else
        let increasedContrast = false // UIKit dynamic colors resolve their accessibilityContrast trait.
        #endif
        return TranscriptSettings(
            thinking: ThinkingDisplay.current,
            reactionsEnabled: ReactionFeature.isEnabled,
            reasoningOff: context.gateway.sessions[context.sessionKey]?.reasoningLevel == "off",
            theme: AppTheme.current,
            dark: RichBlock.isDark,
            increasedContrast: increasedContrast,
            avatarStyle: animated ? AvatarSettings.style(for: context.agent, in: context.gateway) : nil,
            agentStyles: animated
                ? Dictionary(context.gateway.agents.map { ($0.id, AvatarSettings.style(for: $0, in: context.gateway)) }) { first, _ in first }
                : [:],
            supportsMCPServers: context.gateway.canOpenMCPServers,
            mcpServerNames: context.gateway.settings.hasLoaded ? Set(context.gateway.mcp.servers.flatMap {
                [$0.name, MCPToolName.safeServerName($0.name)]
            }) : nil)
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
    /// For each browser tab, the id of the latest turn that shows its card (`BrowserPagePreview.latestTurnIds`).
    var pageTurns: [String: String] = [:]
    var messagePartExcerptCache: MessagePartExcerptCache = .shared
    /// Find matches counted so far in the row being laid out, per section.
    let marks = TranscriptFindMarks()

    var style: TranscriptStyle { TranscriptStyle.shared }

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
            layout.accessibilityLabel = L("Loading earlier messages")
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
                if chat.hasBranches, chat.branchAnchorId == id, let number = chat.activeBranchNumber {
                    decoration.branch = BranchPosition(number: number, count: chat.branches.count,
                                                       canSwitch: chat.canSwitchBranches && !chat.isRunning)
                }
            }
        case let .assistant(turn):
            ids = turn.textIds.compactMap(\.self)
            for id in ids {
                if let item = chat.message(withId: id), let quote = chat.quote(for: item) { decoration.messageQuotes[id] = quote }
            }
            decoration.isLocating = decoration.messageQuotes.values.contains { chat.locatingReplyId == $0.targetId }
            if let sender = turn.sender { agent = sender.displayName(agents: self.context.gateway.agents) }
        case .marker:
            break
        }
        let bookmarks = BookmarkStore.shared(gatewayId: self.context.gateway.id)
        for id in ids {
            if bookmarks.isBookmarked(sessionKey: self.context.sessionKey, messageId: id) { decoration.bookmarks.insert(id) }
            if self.settings.reactionsEnabled {
                let groups = chat.reactionGroups(for: id, agentName: agent)
                if !groups.isEmpty { decoration.reactions[id] = groups }
            }
            if id == self.flash { decoration.flash = id }
        }
        return decoration
    }

}
