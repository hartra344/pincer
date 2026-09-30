import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// VoiceOver announcements shared by the AppKit and UIKit transcripts and SwiftUI views.
@MainActor
enum AccessibilityAnnouncer {
    static var isVoiceOverRunning: Bool {
        #if os(macOS)
        NSWorkspace.shared.isVoiceOverEnabled
        #else
        UIAccessibility.isVoiceOverRunning
        #endif
    }

    /// Speaks `text` when VoiceOver is on; a no-op otherwise.
    static func announce(_ text: String) {
        guard self.isVoiceOverRunning, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Confirms a copy, which a button's brief "Copied" flip doesn't speak. `Clipboard.copy` calls it.
    static func announceCopied() {
        self.announce(L("Copied"))
    }
}

/// A VoiceOver custom action on a transcript row: the row's Copy, Reply and React, plus (on iOS,
/// where the row reads as one element) whatever its buttons do.
struct TranscriptRowAccessibilityAction {
    let name: String
    let perform: () -> Void

    /// Copy for each of the row's copy items, Reply, Copy Link and React on its last message, then opening the
    /// chat a forwarded message came from.
    @MainActor
    static func actions(for layout: TranscriptRowLayout, actions: TranscriptRowActions?, anchor: PView)
        -> [TranscriptRowAccessibilityAction]
    {
        var result: [TranscriptRowAccessibilityAction] = []
        for (index, item) in layout.copyItems.enumerated() where !item.text.isEmpty {
            result.append(.init(name: index == 0 ? L("Copy message") : item.title) { Clipboard.copy(item.text) })
        }
        guard let actions else { return result }
        let source = layout.sourceChat.map { chat in
            [TranscriptRowAccessibilityAction(name: chat.title) { [weak actions] in actions?.openChat(chat.sessionKey) }]
        } ?? []
        guard let messageId = layout.messages.last?.id else { return result + source }
        if let branch = layout.decoration.branch, branch.canSwitch {
            if branch.number > 1 { result.append(.init(name: L("Previous branch")) { [weak actions] in actions?.stepBranch(-1) }) }
            if branch.number < branch.count { result.append(.init(name: L("Next branch")) { [weak actions] in actions?.stepBranch(1) }) }
        }
        let count = layout.messages.count
        let names = Self.perMessageActionNames(
            messageCount: count, bookmarked: layout.messages.map { actions.isBookmarked($0.id) },
            reactions: actions.reactionsEnabled)
        let perMessage = Self.perMessageKinds(reactions: actions.reactionsEnabled)
        var nameIndex = 0
        for (index, span) in layout.messages.enumerated() {
            let id = span.id
            for kind in perMessage {
                let name = names[nameIndex]
                nameIndex += 1
                // Branch, Edit and Regenerate act on the last message only, after its Reply and Copy Link.
                if index == count - 1, kind == .bookmark { Self.appendLastOnly(&result, actions, messageId) }
                result.append(.init(name: name) { [weak actions, weak anchor] in
                    guard let actions else { return }
                    switch kind {
                    case .reply: actions.reply(to: id)
                    case .copyLink: actions.copyLink(to: id)
                    case .bookmark: actions.toggleBookmark(id)
                    case .react:
                        guard let anchor else { return }
                        let rect = Self.reactionRect(span, of: count, in: anchor.bounds.size.height)
                        actions.pickReaction(for: id, from: anchor, rect: rect)
                    }
                })
            }
        }
        return result + source
    }

    private enum PerMessageKind { case reply, copyLink, bookmark, react }

    private static func perMessageKinds(reactions: Bool) -> [PerMessageKind] {
        reactions ? [.reply, .copyLink, .bookmark, .react] : [.reply, .copyLink, .bookmark]
    }

    /// Reply, Copy Link, Bookmark and Add Reaction for each message, named `Reply, part 1 of 3` when
    /// the row holds several. Single-message rows keep the plain names.
    static func perMessageActionNames(messageCount: Int, bookmarked: [Bool], reactions: Bool) -> [String] {
        var names: [String] = []
        for index in 0..<max(messageCount, 0) {
            let isBookmarked = index < bookmarked.count && bookmarked[index]
            let base = [L("Reply"), L("Copy Link"), isBookmarked ? L("Remove Bookmark") : L("Bookmark")]
                + (reactions ? [L("Add Reaction")] : [])
            names += base.map { AccessibilityText.messagePartAction($0, part: index + 1, of: messageCount) }
        }
        return names
    }

    @MainActor
    private static func appendLastOnly(_ result: inout [TranscriptRowAccessibilityAction], _ actions: TranscriptRowActions,
                                       _ id: String)
    {
        if actions.canBranch(from: id) {
            result.append(.init(name: L("Branch from Here")) { [weak actions] in actions?.branch(from: id) })
        }
        if actions.canEdit(id) {
            result.append(.init(name: L("Edit & Resend")) { [weak actions] in actions?.edit(id) })
        }
        if actions.canRegenerate(id) {
            result.append(.init(name: L("Regenerate")) { [weak actions] in actions?.regenerate(id) })
        }
    }

    /// A 1pt anchor for the picker: near the row's end when it holds one message (as before), else near
    /// the end of that message's span.
    private static func reactionRect(_ span: TranscriptRowLayout.MessageSpan, of count: Int, in height: CGFloat) -> CGRect {
        guard count > 1, span.maxY > span.minY else { return CGRect(x: 24, y: max(height - 24, 0), width: 1, height: 1) }
        return CGRect(x: 24, y: max(span.maxY - 24, span.minY), width: 1, height: 1)
    }
}
