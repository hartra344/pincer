import PincerKit

/// Trims the open chat back to its window once Find has closed (#335). Find pages the whole cached
/// history in; after it closes the chat is trimmed as soon as the transcript follows the bottom, so
/// rows dropped above the window never move what the reader sees. Shared by the AppKit and UIKit lists.
@MainActor
final class TranscriptFindTrim {
    typealias Trim = @MainActor (_ chat: ChatStore, _ stillWanted: @escaping @MainActor () -> Bool) async -> Void

    private(set) var atBottom = true
    private(set) var pending = false
    private var findOpen = false
    private weak var chat: ChatStore?
    private let trim: Trim

    init(trim: @escaping Trim = { chat, stillWanted in await chat.trimOpenChatToWindow(stillWanted: stillWanted) }) {
        self.trim = trim
    }

    func findChanged(isPresented: Bool, chat: ChatStore) {
        self.chat = chat
        self.findOpen = isPresented
        self.pending = !isPresented
        self.trimIfReady()
    }

    /// Its chat stopped being shown with Find open (#571): trim it back like a closed Find would.
    func retire() {
        guard self.findOpen else { return }
        self.findOpen = false
        self.pending = true
        self.trimIfReady()
    }

    func bottomAnchorChanged(_ atBottom: Bool, chat: ChatStore) {
        self.chat = chat
        self.atBottom = atBottom
        self.trimIfReady()
    }

    /// Whether the trim may still go ahead after its save suspended.
    var stillWanted: Bool { !self.findOpen && self.atBottom }

    private func trimIfReady() {
        guard self.pending, !self.findOpen, self.atBottom, let chat else { return }
        self.pending = false
        Task { [weak self] in
            await self?.trim(chat) { [weak self] in self?.stillWanted ?? false }
        }
    }
}
