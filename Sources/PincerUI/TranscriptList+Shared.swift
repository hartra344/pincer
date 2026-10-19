import CoreGraphics
import PincerKit
import SwiftUI

/// Chat transcript drawn natively from layouts computed by `TranscriptRenderer`: an `NSTableView`
/// on macOS (`TranscriptList+AppKit.swift`) and a `UICollectionView` on iOS
/// (`TranscriptList+UIKit.swift`). Each platform adds the representable conformance and its
/// `Coordinator`; the inputs and the per-row plumbing they share live here.
struct TranscriptList {
    let rows: [TranscriptRow]
    let context: TranscriptContext
    let isConnected: Bool
    /// Extra space below the last row for content floating over the transcript (the composer).
    var bottomInset: CGFloat = 0
    /// Extra space above the first row, for a toolbar the transcript scrolls under.
    var topInset: CGFloat = 0
    /// Find in chat's matches to highlight, and the selected one to scroll to.
    var highlight = TranscriptHighlight()
    /// A message to scroll to and flash, e.g. from a `pincer://` link.
    var jump: TranscriptJump?
    /// Told how far the reader is from the latest message and whether the list follows the bottom;
    /// runs the scroll-to-bottom button's scroll (#439).
    var bottomState: TranscriptBottomState?
    /// Go ▸ Previous/Next Message for this list (#195).
    var navigator: TranscriptNavigator?

    /// Hands this update's inputs to the platform coordinator, in the order both lists rely on.
    @MainActor
    func push(to coordinator: Coordinator) {
        coordinator.attach(self.bottomState)
        coordinator.update(rows: self.rows, context: self.context,
                           insets: (self.topInset, self.bottomInset), isConnected: self.isConnected)
        coordinator.apply(self.highlight)
        coordinator.apply(self.jump)
        coordinator.install(self.navigator)
    }
}

extension TranscriptListController {
    /// The scroll view's content insets for the owner's chrome insets: the list's own margin plus
    /// whatever floats over it, never negative.
    nonisolated static func contentInsets(top: CGFloat, bottom: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (TranscriptLayout.verticalInset + max(0, top), TranscriptLayout.verticalInset + max(0, bottom))
    }

    /// Whether insets moved by more than half a point, so sub-pixel jitter doesn't cause a settle.
    nonisolated static func insetsChanged(from current: (top: CGFloat, bottom: CGFloat),
                                          to target: (top: CGFloat, bottom: CGFloat)) -> Bool {
        abs(current.top - target.top) > 0.5 || abs(current.bottom - target.bottom) > 0.5
    }

    /// The row's layout at `width`, with its measured height recorded so the list places it exactly.
    func layoutCorrectingHeight(_ row: TranscriptRow, width: CGFloat) -> TranscriptRowLayout {
        let layout = self.renderer.layout(for: row, width: width)
        self.correctHeight(row.id, width: width, height: layout.height)
        return layout
    }
}

extension TranscriptNavKind {
    /// The VoiceOver rotors both lists offer, in order.
    static var rotors: [(name: String, kind: TranscriptNavKind)] {
        [(L("Messages"), .message), (L("Replies"), .reply), (L("Your Messages"), .user), (L("Tool Calls"), .tool)]
    }
}

/// What a transcript cell last showed, so reapplying an unchanged layout costs only a frame check.
@MainActor
struct TranscriptCellState {
    private var serial: Int?
    private(set) weak var actions: TranscriptRowActions?

    /// Sizes `content` to the layout, top-aligned so a row briefly taller than its slot (between a
    /// change and the list catching up) grows downward, and applies the layout if it's new.
    /// Returns whether it was applied.
    mutating func apply(_ layout: TranscriptRowLayout, actions: TranscriptRowActions, to content: TranscriptRowView) -> Bool {
        let frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        if content.frame != frame { content.frame = frame }
        guard layout.serial != self.serial else { return false }
        self.serial = layout.serial
        self.actions = actions
        content.apply(layout, actions: actions)
        return true
    }
}
