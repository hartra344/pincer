import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptRenderer {
    func canBranch(from messageId: String) -> Bool { self.context.chat?.canBranch(from: messageId) ?? false }
    func canEdit(_ messageId: String) -> Bool { self.context.chat?.canEdit(messageId) ?? false }
    func canRegenerate(_ messageId: String) -> Bool { self.context.chat?.canRegenerate(messageId) ?? false }

    func branch(from messageId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.branch(from: messageId) }
    }

    func edit(_ messageId: String) {
        _ = self.context.chat?.beginEdit(messageId)
    }

    func regenerate(_ messageId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.regenerate(messageId) }
    }

    func toggleReaction(_ emoji: String, on messageId: String) {
        guard self.settings.reactionsEnabled else { return }
        self.context.chat?.toggleReaction(emoji, on: messageId)
    }

    func pickReaction(for messageId: String, from view: PView, rect: CGRect) {
        guard self.settings.reactionsEnabled else { return }
        guard let chat = self.context.chat else { return }
        let hint: String? = chat.usesGatewayReactions ? L("The agent sees your reactions on its next turn.") : nil
        ReactionPicker.present(from: view, rect: rect, hint: hint) { [weak self] emoji in
            guard self?.settings.reactionsEnabled == true else { return }
            chat.toggleReaction(emoji, on: messageId)
        }
    }

    var reactionsEnabled: Bool { self.settings.reactionsEnabled }

    var branchEntries: [TranscriptBranchEntry] {
        (self.context.chat?.branches ?? []).map { branch in
            TranscriptBranchEntry(leafEntryId: branch.leafEntryId,
                                  title: BranchMenuEntry.title(for: branch),
                                  isActive: branch.active)
        }
    }

    func stepBranch(_ offset: Int) {
        guard let chat = self.context.chat, let number = chat.activeBranchNumber,
              chat.branches.indices.contains(number - 1 + offset) else { return }
        let target = chat.branches[number - 1 + offset].leafEntryId
        Task { await chat.switchBranch(to: target) }
    }

    func switchBranch(to leafEntryId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.switchBranch(to: leafEntryId) }
    }

    func retrySend(_ id: String) {
        self.context.chat?.retry(outboxId: id)
    }

    func sendNow(_ id: String) {
        self.context.chat?.sendNow(outboxId: id)
    }

    func deleteSend(_ id: String) {
        self.context.chat?.deleteQueued(outboxId: id)
    }

    func showOriginal(_ messageId: String) { self.showOriginal(messageId, missingNotice: nil, isReplyTarget: true) }
}

extension TranscriptRenderer {
    /// Waits for the current paging pass to finish. Used by deterministic controller tests.
    func waitForOlderLoop() async {
        while let loop = self.olderLoop { await loop.value }
    }

    /// The loading-older row is on screen: pages in older history (the cache first) for as long as
    /// the row stays visible, so a page that adds no rows (duplicates, rows folding together) doesn't
    /// stall the list. Failures back off a second and give up after a few.
    func loadOlderIfShown(stillVisible: @escaping @MainActor () -> Bool) {
        guard stillVisible(), let chat = self.context.chat, chat.hasOlderItems else { return }
        guard self.olderLoop == nil else {
            // A list/context update can arrive while the previous chat's page is still unwinding.
            // A different chat gets its own pass after the old one; same-chat list updates do not
            // reset the bounded failure limit.
            if self.olderLoopChat !== chat { self.resumeOlderChat = chat }
            return
        }
        if self.resumeOlderChat === chat { self.resumeOlderChat = nil }
        self.olderLoopChat = chat
        self.olderLoop = Task { @MainActor [weak self] in
            var failures = 0
            for _ in 0..<40 {
                guard chat.hasOlderItems, !Task.isCancelled else { break }
                let loaded: Bool
                if let pageLoader = self?.olderPageLoader {
                    loaded = await pageLoader(chat)
                } else {
                    loaded = await chat.loadOlder()
                }
                if loaded {
                    failures = 0
                } else {
                    failures += 1
                    guard failures < 3 else { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                // Let the list apply the new rows before asking whether the row is still on screen.
                try? await Task.sleep(for: .milliseconds(120))
                guard stillVisible(), self?.context.chat === chat else { break }
            }
            guard let self else { return }
            self.olderLoop = nil
            self.olderLoopChat = nil
            let resumeChat = self.resumeOlderChat
            self.resumeOlderChat = nil
            if let resumeChat, resumeChat.hasOlderItems, stillVisible(), self.context.chat === resumeChat {
                self.loadOlderIfShown(stillVisible: stillVisible)
            }
        }
    }

    /// A connected edge restarts paging only when the loading row is still visible. If a bounded
    /// retry loop has not finished yet, remember one resume and launch it after that loop unwinds.
    func resumeOlderIfShown(stillVisible: @escaping @MainActor () -> Bool) {
        guard stillVisible(), let chat = self.context.chat, chat.hasOlderItems else { return }
        if self.olderLoop != nil {
            self.resumeOlderChat = chat
        } else {
            self.loadOlderIfShown(stillVisible: stillVisible)
        }
    }

    /// Scrolls to and flashes a message, paging in older history if needed. `missingNotice`
    /// replaces the chat's note when it can't be found.
    func showOriginal(_ messageId: String, missingNotice: String?, isReplyTarget: Bool = false) {
        guard let chat = self.context.chat, chat.locatingReplyId == nil else { return }
        Task { @MainActor [weak self] in
            let found = isReplyTarget ? await chat.locateReplyTarget(messageId) : await chat.locate(messageId)
            if !found, let missingNotice { chat.notice = missingNotice }
            guard found, let self, chat === self.context.chat,
                  let row = self.rowId(containing: messageId) else { return }
            self.flashToken += 1
            let token = self.flashToken
            self.setFlash(messageId)
            self.onReveal?(row)
            try? await Task.sleep(for: .seconds(1.6))
            guard self.flashToken == token else { return }
            self.setFlash(nil)
        }
    }
}
