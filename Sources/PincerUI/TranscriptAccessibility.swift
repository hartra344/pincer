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

    /// Copy for each of the row's copy items, then Reply and React on its last message.
    @MainActor
    static func actions(for layout: TranscriptRowLayout, actions: TranscriptRowActions?, anchor: PView)
        -> [TranscriptRowAccessibilityAction]
    {
        var result: [TranscriptRowAccessibilityAction] = []
        for (index, item) in layout.copyItems.enumerated() where !item.text.isEmpty {
            result.append(.init(name: index == 0 ? L("Copy message") : item.title) { Clipboard.copy(item.text) })
        }
        guard let actions, let messageId = layout.messages.last?.id else { return result }
        result.append(.init(name: L("Reply")) { [weak actions] in actions?.reply(to: messageId) })
        if actions.reactionsEnabled {
            result.append(.init(name: L("Add Reaction")) { [weak actions, weak anchor] in
                guard let actions, let anchor else { return }
                let size = anchor.bounds.size
                actions.pickReaction(for: messageId, from: anchor,
                                     rect: CGRect(x: 24, y: max(size.height - 24, 0), width: 1, height: 1))
            })
        }
        return result
    }
}
