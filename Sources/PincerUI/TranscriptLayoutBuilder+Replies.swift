import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Replies and reactions

extension TranscriptLayoutBuilder {
    static let quoteInset: CGFloat = 10
    static let quotePadding: CGFloat = 6
    static let quoteSpinner: CGFloat = 18

    func replyQuote(_ quote: ReplyQuote, isLocating: Bool, width: CGFloat) -> TranscriptPart.ReplyQuote {
        let sender: String? = switch quote.sender {
        case .you: Owner.displayName
        case .agent: self.context.agent.name
        case let .label(label): label
        case nil: nil
        }
        let style = self.style
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let preview = NSAttributedString(string: quote.text ?? L("Original message"), attributes: [
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
    static func quoteHeight(_ quote: TranscriptPart.ReplyQuote) -> CGFloat {
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
    func reactions(on messageId: String, canAdd: Bool = true, into stack: inout Stack, layout: TranscriptRowLayout) {
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
            let working = L("\(self.context.agent.name) is working on this")
            chips.append(.init(emoji: Reactions.ackEmoji, count: 1, includesYou: false, isAck: true,
                               frame: place(Self.chipWidth(emoji: Reactions.ackEmoji, count: 1)),
                               reactors: working, accessibilityLabel: working))
        }
        let addFrame = groups.isEmpty || !canAdd ? nil : place(height + 14)
        stack.add(.reactions(.init(messageId: messageId, chips: chips, addFrame: addFrame)), height: y + height, width: width,
                  spacing: 6)
    }
}
