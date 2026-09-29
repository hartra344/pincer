import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif


// MARK: - Replies and reactions

/// The quoted original above a reply. Tapping it jumps to the original message.
final class TranscriptReplyQuoteView: TranscriptTapView {
    private var quote: TranscriptPart.ReplyQuote?
    private let spinner = TranscriptSpinner(size: 10)
    private weak var actions: TranscriptRowActions?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
        self.onTap = { [weak self] in
            guard let self, let id = self.quote?.targetId else { return }
            self.actions?.showOriginal(id)
        }
        self.accessibilityText = L("Show original message")
        #if os(macOS)
        self.toolTip = L("Show original message")
        #else
        self.accessibilityHint = L("Jumps to the message this replies to")
        #endif
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .replyQuote(quote) = part else { return }
        self.actions = actions
        self.quote = quote
        self.spinner.setAnimating(quote.isLocating)
        self.spinner.isHidden = !quote.isLocating
        self.layoutContent()
        self.redraw()
    }

    override func didHide() {
        self.spinner.setAnimating(false)
    }

    override func layoutContent() {
        let lineHeight = TranscriptLayoutBuilder.quoteSenderHeight
        self.spinner.place(center: CGPoint(x: self.bounds.width - TranscriptLayoutBuilder.quotePadding - 5,
                                           y: TranscriptLayoutBuilder.quotePadding + lineHeight / 2))
    }

    override func draw(_ rect: CGRect) {
        guard let quote else { return }
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        (self.isPressed ? TranscriptColors.strongFill : TranscriptColors.fill).setFill()
        PBezierPath.rounded(bounds, radius: 6).fill()
        TranscriptColors.tint.setFill()
        PBezierPath.rounded(CGRect(x: 0, y: 0, width: 2, height: bounds.height), radius: 1).fill()
        let inset = TranscriptLayoutBuilder.quoteInset, padding = TranscriptLayoutBuilder.quotePadding
        let trailing = quote.isLocating ? 16 : 0
        if let sender = quote.sender {
            singleLine(sender, style.captionSemibold, TranscriptColors.tint)
                .drawLine(at: CGPoint(x: inset, y: padding), width: bounds.width - inset - padding - CGFloat(trailing), font: style.captionSemibold)
        }
        let previewRect = CGRect(x: inset, y: padding + TranscriptLayoutBuilder.quoteSenderHeight + 2,
                                 width: TranscriptLayoutBuilder.quoteTextWidth(bounds.width), height: quote.previewHeight)
        quote.preview.draw(with: previewRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

/// One reaction: the emoji and, when two or more reacted, the count. Tapping toggles yours.
final class TranscriptReactionChipView: TranscriptTapView {
    fileprivate var chip: TranscriptPart.Reactions.Chip?
    fileprivate var onRemove: (() -> Void)?

    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isContextMenuInteractionEnabled = true
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
        guard let chip, !chip.isAck else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var children: [UIMenuElement] = []
            if chip.includesYou {
                children.append(UIAction(title: L("Remove My Reaction"), image: UIImage(systemName: "minus.circle"),
                                         attributes: .destructive) { _ in self?.onRemove?() })
            }
            return UIMenu(title: "\(chip.emoji) \(chip.reactors)", children: children)
        }
    }
    #endif

    func set(_ chip: TranscriptPart.Reactions.Chip) {
        self.chip = chip
        self.accessibilityText = chip.accessibilityLabel
        #if os(macOS)
        self.toolTip = chip.reactors
        #else
        self.accessibilityTraits = chip.isAck ? .staticText : (chip.includesYou ? [.button, .selected] : .button)
        self.isUserInteractionEnabled = !chip.isAck
        #endif
        self.redraw()
    }

    #if os(macOS)
    // The 👀 chip has no action but still reads, as static text.
    override func isAccessibilityElement() -> Bool { self.chip != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { self.chip?.isAck == true ? .staticText : .button }
    #endif

    override func draw(_ rect: CGRect) {
        guard let chip else { return }
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: bounds.height / 2)
        if chip.includesYou {
            TranscriptColors.tint.withAlphaComponent(self.isPressed ? 0.3 : 0.15).setFill()
        } else {
            (self.isPressed ? TranscriptColors.strongFill : TranscriptColors.fill).setFill()
        }
        shape.fill()
        (chip.includesYou ? TranscriptColors.tint.withAlphaComponent(0.6) : TranscriptColors.stroke).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let emoji = NSAttributedString(string: chip.emoji, attributes: [.font: style.callout])
        let emojiHeight = TranscriptStyle.lineHeight(style.callout)
        let emojiWidth = ceil(emoji.size().width)
        let alpha: CGFloat = chip.isAck ? 0.6 : 1
        let context = self.drawingContext
        context?.saveGState()
        context?.setAlpha(alpha)
        emoji.draw(with: CGRect(x: 8, y: (bounds.height - emojiHeight) / 2, width: emojiWidth + 1, height: emojiHeight),
                   options: [.usesLineFragmentOrigin], context: nil)
        context?.restoreGState()
        guard chip.count >= 2 else { return }
        let color = chip.includesYou ? TranscriptColors.tint : TranscriptColors.secondary
        let countHeight = TranscriptStyle.lineHeight(style.captionSemibold)
        singleLine("\(chip.count)", style.captionSemibold, color)
            .drawLine(at: CGPoint(x: 8 + emojiWidth + 4, y: (bounds.height - countHeight) / 2),
                      width: bounds.width - emojiWidth - 12, font: style.captionSemibold)
    }
}

/// The add-reaction button after a message's chips.
final class TranscriptAddReactionView: TranscriptTapView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.accessibilityText = L("Add Reaction")
        #if os(macOS)
        self.toolTip = L("Add Reaction")
        #endif
    }

    override func draw(_ rect: CGRect) {
        let bounds = self.bounds
        let shape = PBezierPath.rounded(bounds.insetBy(dx: 0.5, dy: 0.5), radius: bounds.height / 2)
        (self.isPressed ? TranscriptColors.strongFill : TranscriptColors.fill).setFill()
        shape.fill()
        TranscriptColors.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let size = TranscriptStyle.shared.caption.pointSize
        TranscriptSymbols.draw("face.smiling", in: CGRect(x: 6, y: 0, width: 16, height: bounds.height), size: size + 1,
                               color: TranscriptColors.secondary)
        TranscriptSymbols.draw("plus", in: CGRect(x: bounds.width - 16, y: 0, width: 10, height: bounds.height),
                               size: size - 3, color: TranscriptColors.secondary)
    }
}

/// A message's reaction chips and the add-reaction button.
final class TranscriptReactionsView: TranscriptBaseView {
    private var chipViews: [TranscriptReactionChipView] = []
    private let addView = TranscriptAddReactionView()
    private var part: TranscriptPart.Reactions?
    private weak var actions: TranscriptRowActions?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.addView)
        self.addView.onTap = { [weak self] in
            guard let self, let id = self.part?.messageId else { return }
            self.actions?.pickReaction(for: id, from: self.addView, rect: self.addView.bounds)
        }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .reactions(reactions) = part else { return }
        self.part = reactions
        self.actions = actions
        while self.chipViews.count < reactions.chips.count {
            let view = TranscriptReactionChipView()
            self.addSubview(view)
            self.chipViews.append(view)
        }
        for (index, view) in self.chipViews.enumerated() {
            guard index < reactions.chips.count else {
                view.isHidden = true
                continue
            }
            let chip = reactions.chips[index]
            view.isHidden = false
            view.set(chip)
            let toggle: () -> Void = { [weak self] in
                guard let self, let id = self.part?.messageId else { return }
                self.actions?.toggleReaction(chip.emoji, on: id)
            }
            view.onTap = chip.isAck ? nil : toggle
            view.onRemove = toggle
        }
        self.addView.isHidden = reactions.addFrame == nil
        self.layoutContent()
    }

    override func layoutContent() {
        guard let part else { return }
        for (view, chip) in zip(self.chipViews, part.chips) where view.frame != chip.frame {
            view.frame = chip.frame
            view.redraw()
        }
        if let frame = part.addFrame, self.addView.frame != frame {
            self.addView.frame = frame
            self.addView.redraw()
        }
    }
}

/// The brief highlight over a message after jumping to it. Never takes clicks or taps.
final class TranscriptFlashView: TranscriptBaseView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        self.isUserInteractionEnabled = false
        #endif
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        TranscriptColors.tint.withAlphaComponent(0.15).setFill()
        PBezierPath.rounded(self.bounds, radius: 8).fill()
    }
}
