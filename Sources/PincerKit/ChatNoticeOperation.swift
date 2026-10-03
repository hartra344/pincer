import Foundation

/// Lets an asynchronous action finish its own notice without overwriting a newer action.
/// The operation weakly retains its chat and remains confined to Main.
@MainActor
public final class ChatNoticeOperation {
    private weak var chat: ChatStore?
    private var revision: UInt64?

    public init(_ chat: ChatStore) { self.chat = chat }

    public func publish(_ notice: String?) {
        guard let chat = self.chat else { return }
        chat.notice = notice
        self.revision = chat.noticeRevision
    }

    @discardableResult
    public func publishIfCurrent(_ notice: String?) -> Bool {
        guard let chat = self.chat, let revision = self.revision,
              chat.noticeRevision == revision else { return false }
        self.publish(notice)
        return true
    }
}
