import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Packs compact footer actions once in row layout and uses those exact frames to place the views.
/// The one-entry cache is bounded and keyed by the localized labels and the active style generation.
@MainActor
enum CompactFooterPacking {
    struct Result {
        let frames: [TranscriptPart.Footer.Action: CGRect]
        let rowCount: Int
        let rowHeight: CGFloat
    }

    private struct Metric {
        let width: CGFloat
        let outset: CGFloat
        let height: CGFloat
    }

    private struct Cache {
        let key: String
        let values: [TranscriptPart.Footer.Action: Metric]
    }

    private static var cache: Cache?

    private static func metrics() -> [TranscriptPart.Footer.Action: Metric] {
        let copy = L("Copy"), copied = L("Copied"), reply = L("Reply")
        let listen = L("Listen"), stop = L("Stop"), react = L("React")
        let labels = [copy, copied, reply, listen, stop, react]
        let key = "\(TranscriptStyle.generation)|" + labels.joined(separator: "\u{0}")
        if let cache, cache.key == key { return cache.values }

        #if os(iOS)
        let minimumTarget: CGFloat = 44
        #else
        let minimumTarget: CGFloat = 0
        #endif
        func metric(_ titles: [String], minimumWidth: CGFloat = 0, extraHitOutset: CGFloat = 0) -> Metric {
            let sizes = titles.map(TranscriptLabelButton.size(title:))
            let size = sizes.max { $0.width < $1.width } ?? .zero
            let height = sizes.map(\.height).max() ?? 0
            let width = max(minimumWidth, size.width)
            let outset = max(extraHitOutset, max((minimumTarget - width) / 2, 0))
            return Metric(width: width, outset: outset, height: height)
        }
        let values: [TranscriptPart.Footer.Action: Metric] = [
            .bookmark: metric([""], extraHitOutset: minimumTarget == 0 ? 8 : 0),
            .copy: metric([copy, copied], minimumWidth: 80),
            .reply: metric([reply]),
            .listen: metric([listen, stop], minimumWidth: 80),
            .react: metric([react]),
        ]
        self.cache = Cache(key: key, values: values)
        return values
    }

    /// `branchWidth` is the switcher group's full width, its hit slots included (`TranscriptFooterView.branchSlotWidths`).
    static func pack(width: CGFloat, actions: [TranscriptPart.Footer.Action], rowHeight: CGFloat,
                     branchWidth: CGFloat = 0) -> Result {
        var metrics = self.metrics()
        if actions.contains(.branch) {
            metrics[.branch] = Metric(width: branchWidth, outset: 0, height: TranscriptLabelButton.size(title: "").height)
        }
        let rowHeight = max(rowHeight, actions.compactMap { metrics[$0]?.height }.max() ?? 0)
        var frames: [TranscriptPart.Footer.Action: CGRect] = [:]
        var cursor: CGFloat = 0
        var row = 0
        for action in actions {
            guard let metric = metrics[action] else { continue }
            var x = cursor + metric.outset
            if cursor > 0, x + metric.width + metric.outset > width {
                row += 1
                cursor = 0
                x = metric.outset
            }
            frames[action] = CGRect(x: x, y: CGFloat(row) * rowHeight, width: metric.width, height: rowHeight)
            cursor = x + metric.width + metric.outset + 10
        }
        return Result(frames: frames, rowCount: frames.isEmpty ? 0 : row + 1, rowHeight: rowHeight)
    }

    static func hitOutset(for action: TranscriptPart.Footer.Action) -> CGFloat {
        self.metrics()[action]?.outset ?? 0
    }
}

/// The line under a message: the branch switcher when its branches fork here, Copy, Reply and React, then details such as the time it was sent
/// and its model.
final class TranscriptFooterView: TranscriptBaseView {
    private var footer: TranscriptPart.Footer?
    private var rowID: String?
    private let copyButton = TranscriptLabelButton()
    private let replyButton = TranscriptLabelButton()
    private let reactButton = TranscriptLabelButton()
    private let listenButton = TranscriptLabelButton()
    private let bookmarkButton = TranscriptLabelButton()
    private let previousBranchButton = TranscriptLabelButton()
    private let branchLabel = TranscriptLabelButton()
    private let nextBranchButton = TranscriptLabelButton()
    private weak var actions: TranscriptRowActions?
    private var copiedToken = 0

    private var branchControls: [TranscriptLabelButton] { [self.previousBranchButton, self.branchLabel, self.nextBranchButton] }

    /// Smallest comfortable touch or click target for the branch controls.
    private static var minimumTarget: CGSize {
        #if os(iOS)
        CGSize(width: 44, height: 44)
        #else
        CGSize(width: 28, height: 28)
        #endif
    }

    private static var branchDigitsFont: PFont {
        let caption = TranscriptStyle.shared.caption
        #if os(macOS)
        return NSFont.monospacedDigitSystemFont(ofSize: caption.pointSize, weight: .regular)
        #else
        return UIFont.monospacedDigitSystemFont(ofSize: caption.pointSize, weight: .regular)
        #endif
    }

    private static let chevronPadding: CGFloat = 3
    private static let labelPadding: CGFloat = 4

    /// Widths of the compact switcher's three slots (‹, "2 / 2", ›), each at least the minimum target
    /// wide, so the group packs into the action row with its touch targets intact. Layout and view share it.
    static func branchSlotWidths(label: String) -> [CGFloat] {
        let chevron = 14 + 2 * self.chevronPadding
        let text = singleLine(label, self.branchDigitsFont, TranscriptColors.tint).lineWidth + 2 * self.labelPadding
        return [chevron, text, chevron].map { max($0, self.minimumTarget.width) }
    }

    private func setUpBranchControls() {
        self.previousBranchButton.set(title: "", symbol: "chevron.left")
        self.nextBranchButton.set(title: "", symbol: "chevron.right")
        self.previousBranchButton.accessibilityText = L("Previous branch")
        self.nextBranchButton.accessibilityText = L("Next branch")
        self.branchLabel.titleFont = Self.branchDigitsFont
        for button in self.branchControls {
            button.isSubdued = true
            button.isCompact = true
            button.padding = button === self.branchLabel ? Self.labelPadding : Self.chevronPadding
            button.isHidden = true
            #if os(macOS)
            button.showsHover = true
            #endif
            self.addSubview(button)
        }
        self.previousBranchButton.onTap = { [weak self] in self?.stepBranch(-1) }
        self.nextBranchButton.onTap = { [weak self] in self?.stepBranch(1) }
        #if os(macOS)
        self.branchLabel.onTap = { [weak self] in self?.showBranchMenu() }
        #endif
        self.branchLabel.onIncrement = { [weak self] in self?.stepBranch(1) }
        self.branchLabel.onDecrement = { [weak self] in self?.stepBranch(-1) }
        self.branchLabel.accessibilityHintText = L("Choose a branch")
        #if os(iOS)
        self.branchLabel.accessibilityTraits = .adjustable
        #endif
        #if os(iOS)
        self.branchLabel.showsMenuAsPrimaryAction = true
        self.branchLabel.isContextMenuInteractionEnabled = true
        self.branchLabel.menuProvider = { [weak self] in self?.branchMenuElements() ?? [] }
        #endif
    }

    private func stepBranch(_ offset: Int) {
        guard let branch = footer?.branch, branch.canSwitch else { return }
        self.actions?.stepBranch(offset)
    }

    #if os(macOS)
    private func showBranchMenu() {
        guard let branch = footer?.branch, branch.canSwitch, let actions else { return }
        let menu = NSMenu()
        for entry in actions.branchEntries {
            let item = NSMenuItem(title: entry.title, action: #selector(self.pickBranch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.leafEntryId
            item.state = entry.isActive ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: self.branchLabel.bounds.height + 2), in: self.branchLabel)
    }

    @objc private func pickBranch(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        self.actions?.switchBranch(to: id)
    }
    #else
    private func branchMenuElements() -> [UIMenuElement] {
        guard footer?.branch?.canSwitch == true, let actions else { return [] }
        return actions.branchEntries.map { entry in
            UIAction(title: entry.title, image: entry.isActive ? UIImage(systemName: "checkmark") : nil,
                     state: entry.isActive ? .on : .off) { [weak actions] _ in actions?.switchBranch(to: entry.leafEntryId) }
        }
    }
    #endif

    /// Where each visible branch control takes taps: its frame grown to the minimum target (never
    /// left of the footer), with overlaps between neighbours, and with the next button, split at the midpoint.
    private func branchHitFrames() -> [(control: TranscriptLabelButton, frame: CGRect)] {
        let controls = self.branchControls.filter { !$0.isHidden }
        guard !controls.isEmpty else { return [] }
        let target = Self.minimumTarget
        var frames = controls.map { control -> CGRect in
            let f = control.frame
            let grown = f.insetBy(dx: -max((target.width - f.width) / 2, 0), dy: -max((target.height - f.height) / 2, 0))
            return grown.minX < 0 ? CGRect(x: 0, y: grown.minY, width: grown.maxX, height: grown.height) : grown
        }
        for index in frames.indices {
            let next: CGRect? = index + 1 < controls.count
                ? controls[index + 1].frame
                : [self.bookmarkButton, self.copyButton, self.replyButton, self.reactButton].first { !$0.isHidden }?.frame
            guard let next else { continue }
            // Do not split a touch target at the midpoint of a control on another (wrapped) action row.
            guard abs(controls[index].frame.midY - next.midY) < max(controls[index].frame.height, next.height) / 2 else { continue }
            let mid = (controls[index].frame.maxX + next.minX) / 2
            frames[index].size.width = max(min(frames[index].maxX, mid) - frames[index].minX, 0)
            if index + 1 < controls.count {
                let right = frames[index + 1]
                frames[index + 1] = CGRect(x: max(right.minX, mid), y: right.minY, width: max(right.maxX - max(right.minX, mid), 0),
                                           height: right.height)
            }
        }
        return Array(zip(controls, frames))
    }

    private func branchControl(at point: CGPoint) -> TranscriptLabelButton? {
        self.branchHitFrames().first { $0.frame.contains(point) }?.control
    }

    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.convert(point, from: self.superview)
        if let control = self.branchControl(at: local) { return control }
        return super.hitTest(point)
    }
    #else
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        self.branchControl(at: point) != nil || super.point(inside: point, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let control = self.branchControl(at: point) { return control }
        return super.hitTest(point, with: event)
    }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setUpBranchControls()
        for button in [self.copyButton, self.replyButton, self.reactButton, self.listenButton] {
            button.isSubdued = true
            self.addSubview(button)
        }
        self.bookmarkButton.set(title: "", symbol: "star.fill")
        self.bookmarkButton.accessibilityText = L("Remove Bookmark")
        self.bookmarkButton.hitOutset = CGSize(width: 8, height: 8)
        self.bookmarkButton.isHidden = true
        self.addSubview(self.bookmarkButton)
        self.bookmarkButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.toggleBookmark(id)
        }
        self.showCopy()
        self.copyButton.onTap = { [weak self] in self?.copy() }
        self.replyButton.set(title: L("Reply"), symbol: "arrowshape.turn.up.left")
        self.replyButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.reply(to: id)
        }
        self.listenButton.isHidden = true
        self.listenButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId, let rowID = self.rowID else { return }
            self.actions?.readAloud(id, rowID: rowID)
        }
        self.reactButton.set(title: L("React"), symbol: "face.smiling")
        self.reactButton.accessibilityText = L("Add Reaction")
        self.reactButton.onTap = { [weak self] in
            guard let self, let id = self.footer?.messageId else { return }
            self.actions?.pickReaction(for: id, from: self.reactButton, rect: self.reactButton.bounds)
        }
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .footer(footer) = part else { return }
        let old = self.footer
        self.footer = footer
        self.rowID = row.id
        self.actions = actions
        self.copyButton.isHidden = footer.copyText.isEmpty || (footer.compact && footer.actionFrames[.copy] == nil)
        self.replyButton.isHidden = footer.messageId == nil || (footer.compact && footer.actionFrames[.reply] == nil)
        self.reactButton.isHidden = footer.messageId == nil || !actions.reactionsEnabled
            || (footer.compact && footer.actionFrames[.react] == nil)
        self.bookmarkButton.isHidden = footer.messageId == nil || !footer.isBookmarked
            || (footer.compact && footer.actionFrames[.bookmark] == nil)
        self.updateListenButton()
        if old?.branch != footer.branch {
            let branch = footer.branch
            for button in self.branchControls { button.isHidden = branch == nil }
            if let branch {
                self.branchLabel.set(title: branch.label, symbol: "")
                self.branchLabel.accessibilityText = L("Branch \(branch.number) of \(branch.count)")
                self.previousBranchButton.isDisabled = !branch.canSwitch || branch.number <= 1
                self.nextBranchButton.isDisabled = !branch.canSwitch || branch.number >= branch.count
                self.branchLabel.isDisabled = !branch.canSwitch
            }
        }
        if old?.isBookmarked != footer.isBookmarked || old?.branch != footer.branch {
            #if os(macOS)
            self.needsLayout = true
            #else
            self.setNeedsLayout()
            #endif
        }
        if old?.key != footer.key {
            self.copiedToken += 1
            self.showCopy()
        }
        if old?.details != footer.details || old?.compact != footer.compact || old?.detailsFrame != footer.detailsFrame {
            self.redraw()
        }
        #if os(macOS)
        self.toolTip = footer.details.isEmpty ? nil : footer.details
        #endif
    }

    /// Read Aloud / Stop Reading Aloud for this message; re-runs when the controller's phase changes.
    private func updateListenButton() {
        guard let footer, !footer.compact || footer.actionFrames[.listen] != nil,
              let id = footer.messageId, let rowID = self.rowID, let actions,
              actions.canReadAloud(id, rowID: rowID) else {
            if !self.listenButton.isHidden { self.listenButton.isHidden = true; self.relayoutFooter() }
            return
        }
        let reading = withObservationTracking {
            actions.isReadingAloud(id)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateListenButton() }
        }
        self.listenButton.set(title: reading ? L("Stop") : L("Listen"), symbol: reading ? "stop.fill" : "speaker.wave.2")
        self.listenButton.accessibilityText = reading ? L("Stop Reading Aloud") : L("Read Aloud")
        if self.listenButton.isHidden { self.listenButton.isHidden = false }
        self.relayoutFooter()
    }

    private func relayoutFooter() {
        #if os(macOS)
        self.needsLayout = true
        #else
        self.setNeedsLayout()
        #endif
    }

    private func showCopy() {
        self.copyButton.set(title: L("Copy"), symbol: "doc.on.doc")
        self.copyButton.accessibilityText = L("Copy message")
    }

    private func copy() {
        guard let footer else { return }
        Clipboard.copy(footer.copyText)
        self.copyButton.set(title: L("Copied"), symbol: "checkmark")
        self.copiedToken += 1
        let token = self.copiedToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedToken == token else { return }
            self.showCopy()
        }
    }

    /// Where the details start, after the buttons showing.
    private var detailsX: CGFloat = 0

    /// Exact metadata bounds used by `draw(_:)`; exposed internally for hosted layout tests.
    var detailsDrawFrame: CGRect {
        guard let footer else { return .zero }
        if footer.compact { return footer.detailsFrame }
        let font = TranscriptStyle.shared.caption
        return CGRect(x: self.detailsX, y: (self.bounds.height - TranscriptStyle.lineHeight(font)) / 2,
                      width: max(self.bounds.width - self.detailsX, 0), height: TranscriptStyle.lineHeight(font))
    }

    override func layoutContent() {
        guard let footer else { return }
        if footer.compact {
            self.layoutCompact(footer)
            return
        }
        self.bookmarkButton.hitOutset = CGSize(width: 8, height: 8)
        for button in [self.copyButton, self.replyButton, self.listenButton, self.reactButton] {
            button.hitOutset = .zero
        }
        // The chevron's glyph is narrower than its box; this lines its ink up with the icons above and below.
        var x: CGFloat = self.previousBranchButton.isHidden ? 0 : -4
        var moved = false
        for button in self.branchControls + [self.bookmarkButton, self.copyButton, self.replyButton, self.listenButton, self.reactButton]
        where !button.isHidden {
            let size = button.buttonSize
            let frame = CGRect(x: x, y: (self.bounds.height - size.height) / 2, width: size.width, height: size.height)
            if self.branchControls.contains(where: { $0 === button }) {
                let target = Self.minimumTarget
                button.hitOutset = CGSize(width: max((target.width - size.width) / 2, 0), height: max((target.height - size.height) / 2, 0))
            }
            if button.frame != frame {
                button.frame = frame
                moved = true
            }
            x = frame.maxX + (button === self.previousBranchButton || button === self.branchLabel ? 0
                : button === self.nextBranchButton ? 3 : 10)
        }
        if moved || x != self.detailsX {
            self.detailsX = x
            self.redraw()
        }
    }

    private func layoutCompact(_ footer: TranscriptPart.Footer) {
        var moved = false
        if let group = footer.actionFrames[.branch], let branch = footer.branch {
            // Each control is centred in its slot; the slots are its touch targets.
            var slotX = group.minX
            for (button, slot) in zip(self.branchControls, Self.branchSlotWidths(label: branch.label)) where !button.isHidden {
                let size = button.buttonSize
                let frame = CGRect(x: slotX + (slot - size.width) / 2, y: group.minY + (group.height - size.height) / 2,
                                   width: size.width, height: size.height)
                button.hitOutset = CGSize(width: max((slot - size.width) / 2, 0),
                                          height: max((Self.minimumTarget.height - size.height) / 2, 0))
                if button.frame != frame { button.frame = frame; moved = true }
                slotX += slot
            }
        }

        let buttons: [(TranscriptPart.Footer.Action, TranscriptLabelButton)] = [
            (.bookmark, self.bookmarkButton), (.copy, self.copyButton), (.reply, self.replyButton),
            (.listen, self.listenButton), (.react, self.reactButton),
        ]
        for (action, button) in buttons where !button.isHidden {
            guard let planned = footer.actionFrames[action] else { continue }
            button.hitOutset = CGSize(width: CompactFooterPacking.hitOutset(for: action), height: 0)
            let frame = planned
            if button.frame != frame { button.frame = frame; moved = true }
        }
        if moved { self.redraw() }
    }

    override func draw(_ rect: CGRect) {
        guard let footer, !footer.details.isEmpty else { return }
        let font = TranscriptStyle.shared.caption
        if footer.compact {
            let lineHeight = TranscriptStyle.lineHeight(font)
            for (index, line) in footer.detailLines.prefix(2).enumerated() {
                singleLine(line, font, TranscriptColors.tertiary)
                    .drawLine(at: CGPoint(x: footer.detailsFrame.minX,
                                          y: footer.detailsFrame.minY + CGFloat(index) * lineHeight),
                              width: footer.detailsFrame.width, font: font)
            }
        } else {
            let frame = self.detailsDrawFrame
            singleLine(footer.details, font, TranscriptColors.tertiary)
                .drawLine(at: frame.origin, width: frame.width, font: font)
        }
    }

    #if os(macOS)
    override func isAccessibilityElement() -> Bool { false }
    #endif
}
