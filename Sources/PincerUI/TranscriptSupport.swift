import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif


/// One row of the native transcript list (`TranscriptList`): a message, or the spinner shown while
/// older history is still streaming in above.
enum TranscriptRow: Equatable, Sendable {
    case loadingOlder
    case entry(TranscriptEntry)

    var id: String {
        switch self {
        case .loadingOlder: "loading-older"
        case let .entry(entry): entry.id
        }
    }

    /// A message the owner just sent that the Gateway hasn't committed yet. The list jumps to it,
    /// even if the reader had scrolled up, and then follows the reply.
    var isPendingSend: Bool {
        if case let .entry(.user(item)) = self { item.isPending } else { false }
    }

    @MainActor static func rows(for chat: ChatStore) -> [TranscriptRow] {
        (chat.hasOlderItems ? [.loadingOlder] : []) + chat.entries.map(TranscriptRow.entry)
    }
}

/// Which thinking blocks and tool cards are open. Kept outside the rows because the list recycles
/// row views: state stored in a row view would follow it to another message.
@MainActor
final class TranscriptDisclosure {
    private var expanded: [String: Bool] = [:]
    /// Queries and current matches of the search within a tool card.
    let toolSearch = ToolCardSearchStore()

    func isExpanded(_ id: String, default value: Bool) -> Bool {
        self.expanded[id] ?? value
    }

    func set(_ id: String, expanded: Bool) {
        self.expanded[id] = expanded
    }

    /// Records a default once, so it sticks when the condition that chose it (a live stream) ends.
    func setIfUnset(_ id: String, expanded: Bool) {
        if self.expanded[id] == nil { self.expanded[id] = expanded }
    }
}

/// Everything a transcript row needs besides its own content.
@MainActor
struct TranscriptContext {
    let gateway: GatewayStore
    let disclosure: TranscriptDisclosure
    let agent: AgentSummary
    let sessionKey: String
    /// Opens an image full size. Provided by `ChatView`, which owns the sheet.
    let previewImage: (ImageRef) -> Void
    /// Offers a downloaded attachment to the user to save. Provided by `ChatView`.
    let saveFile: (FileRef, Data) -> Void
    /// The chat's replies and reactions.
    var chat: ChatStore?
    /// Starts a reply to a message in the composer. Provided by `ChatView`.
    var reply: (String) -> Void = { _ in }
    /// Copies a `pincer://` link to a message. Provided by `ChatView`.
    var copyLink: (String) -> Void = { _ in }
    /// Stars or un-stars a message. Provided by `ChatView`.
    var toggleBookmark: (String) -> Void = { _ in }
    var isBookmarked: (String) -> Bool = { _ in false }
    /// Opens an ```html fence in the sandboxed preview. Provided by `ChatView`, which owns the sheet.
    var previewHTML: (String) -> Void = { _ in }
    /// Shows a downloaded attachment in Quick Look. Provided by `ChatView`, which owns the preview.
    var quickLook: (URL) -> Void = { _ in }
    /// Opens an MCP server in Gateway Settings. Provided by `ChatView`.
    var openMCPServer: (String) -> Void = { _ in }
    /// Opens a browser tool's page card. Return true when handled (e.g. in an in-app browser panel);
    /// otherwise the page opens in the system browser.
    var openBrowserPage: (BrowserPagePreview) -> Bool = { _ in false }

    func differs(from other: TranscriptContext) -> Bool {
        self.agent != other.agent || self.sessionKey != other.sessionKey || self.disclosure !== other.disclosure
            || self.chat !== other.chat
    }

    /// Whether a message has reaction chips (the agent's or yours), for height estimates.
    @MainActor func hasReactions(_ messageId: String) -> Bool {
        guard ReactionFeature.isEnabled else { return false }
        if self.chat?.agentReactions[messageId]?.isEmpty == false { return true }
        if self.chat?.sharedReactions[messageId]?.isEmpty == false { return true }
        return !self.gateway.myReactions(sessionKey: self.sessionKey, messageId: messageId).isEmpty
    }
}

/// One line of the branch switcher's menu.
struct TranscriptBranchEntry {
    let leafEntryId: String
    let title: String
    let isActive: Bool
}

/// What row views can ask of the list they're in.
@MainActor
protocol TranscriptRowActions: AnyObject {
    var messagePartExcerptCache: MessagePartExcerptCache { get }
    func setExpanded(_ key: String, _ expanded: Bool, row: String)
    func openRun(_ sessionKey: String)
    /// Opens another chat, e.g. the one a forwarded message came from.
    func openChat(_ sessionKey: String)
    /// Opens the MCP server a tool card called in Gateway Settings.
    func openMCPServer(_ name: String)
    func preview(_ ref: ImageRef)
    /// Shows an ```html fence as a page in the sandboxed preview.
    func previewHTML(_ html: String)
    func open(_ url: URL)
    /// A browser page card was tapped.
    func openBrowserPage(_ page: BrowserPagePreview)
    /// Asks for the page's image and favicon when the card is shown.
    func loadPagePreview(_ url: URL)
    func loadImage(_ ref: ImageRef)
    func loadFilePreview(_ file: FileRef)
    /// Downloads HTML/SVG and opens it in the sandboxed preview; false when it couldn't be loaded as text.
    func previewHTML(_ file: FileRef) async -> Bool
    /// Downloads the file and offers to save it; false when it couldn't be downloaded.
    func saveFile(_ file: FileRef) async -> Bool
    /// Downloads the file and shows it in Quick Look; false when it couldn't be downloaded.
    func quickLook(_ file: FileRef) async -> Bool
    /// Starts a reply to the message in the composer.
    func reply(to messageId: String)
    /// Branch from Here, Edit & Resend and Regenerate (each only offered when the chat can do it).
    func canBranch(from messageId: String) -> Bool
    func canEdit(_ messageId: String) -> Bool
    func canRegenerate(_ messageId: String) -> Bool
    func branch(from messageId: String)
    func edit(_ messageId: String)
    func regenerate(_ messageId: String)
    /// Copies a link that opens the chat scrolled to the message.
    func copyLink(to messageId: String)
    /// Bookmarks the message, or removes its bookmark.
    func toggleBookmark(_ messageId: String)
    func isBookmarked(_ messageId: String) -> Bool
    /// Read Aloud: speaks the message (or stops it when it's already being read).
    func readAloud(_ messageId: String)
    func isReadingAloud(_ messageId: String) -> Bool
    /// Whether the message has anything worth speaking.
    func canReadAloud(_ messageId: String) -> Bool
    /// Row-aware Read Aloud lookup used by native controls so a completed preparation can refresh
    /// only the transcript row that owns the message.
    func canReadAloud(_ messageId: String, rowID: String) -> Bool
    func readAloud(_ messageId: String, rowID: String)
    /// Adds your reaction, or removes it when it's already there.
    var reactionsEnabled: Bool { get }
    func toggleReaction(_ emoji: String, on messageId: String)
    /// Opens the emoji picker for a message, anchored to `rect` in `view`.
    func pickReaction(for messageId: String, from view: PView, rect: CGRect)
    /// The chat's branches, oldest first, for the switcher's menu.
    var branchEntries: [TranscriptBranchEntry] { get }
    /// Switches to the branch `offset` places from the active one (-1 previous, 1 next).
    func stepBranch(_ offset: Int)
    func switchBranch(to leafEntryId: String)
    /// Scrolls to the message a reply quotes (loading older history if needed) and flashes it.
    func showOriginal(_ messageId: String)
    /// Animates the latest reply's avatar.
    var liveAvatar: TranscriptLiveAvatar? { get }
    /// Sends an unsent (failed) message again, with its original idempotency key.
    func retrySend(_ id: String)
    /// Uploads a held large message over the current (expensive or constrained) network.
    func sendNow(_ id: String)
    /// Deletes a queued or failed message.
    func deleteSend(_ id: String)
}

extension TranscriptRowActions {
    func openBrowserPage(_ page: BrowserPagePreview) { self.open(page.url) }
    func loadPagePreview(_ url: URL) {}
    var messagePartExcerptCache: MessagePartExcerptCache { .shared }
    func canReadAloud(_ messageId: String, rowID: String) -> Bool { self.canReadAloud(messageId) }
    func readAloud(_ messageId: String, rowID: String) { self.readAloud(messageId) }
}


/// Scroll behavior shared by the AppKit and UIKit transcripts.
enum TranscriptLayout {
    /// Within this distance of the end, new content keeps the transcript scrolled to the bottom.
    static let stickToBottomDistance: CGFloat = 80
    static let rowSpacing: CGFloat = 2
    static let verticalInset: CGFloat = 12

    /// Rough height for a row that hasn't been laid out yet, so the scroll bar and off-screen
    /// positions are close before the row is laid out for real.
    @MainActor static func estimatedHeight(_ row: TranscriptRow, width: CGFloat,
                                hasReactions: (String) -> Bool = { _ in false }) -> CGFloat {
        let textWidth = max(width - TranscriptMetrics.contentX - TranscriptMetrics.sidePadding, 120)
        let charactersPerLine = max(textWidth / 7, 10)
        let scaffold: CGFloat = 12 + 22
        let footer: CGFloat = TranscriptMetrics.footerSpacing + 16
        let chips = TranscriptLayoutBuilder.chipHeight + 6
        switch row {
        case .loadingOlder:
            return 36
        case .entry(.marker):
            return 32
        case let .entry(.user(item)):
            let footprint = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: Double(charactersPerLine), hasReactions: hasReactions)
            #if DEBUG
            ColdTranscriptHeightEstimateProbe.recordWork(row.id, bytes: footprint.inspectedBytes, visits: footprint.metadataVisits)
            #endif
            return scaffold + CGFloat(footprint.lines) * 18 + (footprint.hasImages ? 240 : 0) + CGFloat(footprint.fileCount) * 36
                + (!footprint.hasRawText && item.outboxState == nil ? 0 : footer) + (item.replyToId != nil ? 50 : 0)
                + CGFloat(footprint.reactionCount) * chips + CGFloat(footprint.extraHeight)
        case let .entry(.assistant(turn)):
            let footprint = ColdTranscriptFootprint.estimate(.assistant(turn), charactersPerLine: Double(charactersPerLine), hasReactions: hasReactions)
            #if DEBUG
            ColdTranscriptHeightEstimateProbe.recordWork(row.id, bytes: footprint.inspectedBytes, visits: footprint.metadataVisits)
            #endif
            var height = scaffold
            if turn.isStreaming, ThinkingDisplay.current != .none {
                if !turn.thinking.isEmpty { height += 26 }
                height += CGFloat(turn.tools.count) * 34
            } else if ThinkingDisplay.current == .all, !turn.thinking.isEmpty || !turn.tools.isEmpty {
                height += 26
            }
            if footprint.textSourceCount > 0 { height += CGFloat(footprint.lines) * 18 + CGFloat(footprint.textSourceCount) * footer }
            if !turn.images.isEmpty { height += 240 }
            height += CGFloat(turn.files.count) * 36
            height += CGFloat(footprint.reactionCount) * chips + CGFloat(footprint.extraHeight)
            return height
        }
    }
}
