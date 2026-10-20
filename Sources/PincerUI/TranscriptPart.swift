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
            /// Optional native TextKit line cap for a compact preview; the stored source stays complete.
            var visibleLineLimit: Int? = nil
            /// Identifies the text view's content when the title is empty.
            var id: String?
            /// Bottom of the line holding the current card-search match, from the top of the text.
            var searchMatchBottom: CGFloat?
        }

        /// The search field of a card whose output search is open, in card coordinates.
        struct Search: Equatable {
            let frame: CGRect
            let query: String
            let total: Int
            /// Index of the current match among `total`.
            let current: Int
        }

        enum Tone { case label, secondary, tertiary, ok, failure, fill, strongFill, terminal }
        enum Face { case caption, captionSemibold, captionMono, caption2Medium, code }

        /// Non-selectable drawing of an expanded card (badges, chips, titles, block backgrounds),
        /// in card coordinates and draw order.
        enum Decor {
            /// `stroke` outlines it in that tone instead of the neutral stroke.
            case block(CGRect, Tone, stroke: Tone?)
            case pill(CGRect, Tone)
            case label(String, CGPoint, width: CGFloat, Face, Tone, truncation: NSLineBreakMode)
            case symbol(String, CGRect, Tone)
        }

        struct Note {
            let frame: CGRect
            let text: String
        }

        /// A Copy or toggle button inside an expanded card.
        struct Control {
            enum Action {
                case copy(String)
                case toggle(key: String, to: Bool)
                case openMCPServer(String, toolName: String)
            }

            let id: String
            let title: String
            let symbol: String
            let frame: CGRect
            let action: Action
            let spoken: String
            /// Pinned to the frame's trailing edge (the button's width can differ from the reserved one).
            var trailing = false
            var iconOnly = false
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
        var decor: [Decor] = []
        var controls: [Control] = []
        /// What VoiceOver reads for the chips, badges and captions drawn in the body.
        var notes: [Note] = []
        var search: Search?
        /// MCP row actions are present even while the card body is collapsed.
        var mcpContextMenu: TranscriptToolContextMenu? = nil
    }

    /// The line under a message: a Copy button and details such as when it was sent.
    struct Footer {
        enum Action: Hashable { case branch, bookmark, copy, reply, listen, react }

        /// Tells a recycled footer it now shows a different message, so "Copied" resets.
        let key: String
        let copyText: String
        let details: String
        /// Compact rows pack the branch switcher and actions into wrapped action lines before drawing
        /// metadata across the content width.
        let compact: Bool
        let actionRowHeight: CGFloat
        let controlHeight: CGFloat
        let detailsFrame: CGRect
        let detailLines: [String]
        /// Compact action frames in footer coordinates. The view uses the same packed result that
        /// sized this row, so controls and metadata cannot disagree about how many rows are needed.
        let actionFrames: [Action: CGRect]
        /// The message Reply and React act on; nil hides them.
        var messageId: String?
        /// Shows the filled star (#384), which removes the bookmark when tapped.
        var isBookmarked = false
        /// The `‹ 2 / 2 ›` switcher, on the message where the chat's branches fork.
        var branch: BranchPosition?
    }

    /// Where an unsent message is: queued, or failed with Retry and Delete.
    struct SendStatus: Equatable {
        enum Kind: Equatable { case queued, held, sending, failed }
        var kind: Kind = .queued
        /// The outbox entry (the message's idempotency key).
        let id: String
        let text: String
        let isFailed: Bool
        let canRetry: Bool
        let canDelete: Bool
        /// A large upload held for Wi‑Fi can be sent over this network anyway.
        var canSendNow = false
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
        /// Drawn without the photo frame (border, rounded clip): rendered math.
        var plain = false
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
    case pagePreview(PagePreview)
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
             imageLink, pagePreview, file, typing, footer, marker, loading, replyQuote, reactions, sendStatus, flash
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
        case .pagePreview: .pagePreview
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
