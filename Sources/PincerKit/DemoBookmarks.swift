import Foundation

/// The demo gateway's starter bookmarks (#42): three messages with fixed ids the demo's seeded
/// transcripts use, so they resolve on every launch.
public enum DemoBookmarks {
    static let tripQuestion = "Any onsen etiquette we should know?"
    static let tripMessageId = "demo-trip-onsen-etiquette"
    static let toolsExecMessageId = "demo-tools-mcp-status"
    static let toolsSummaryMessageId = "demo-tools-mcp-summary"

    public static let tripSessionKey = "agent:main:dashboard:trip"

    /// Bookmarks to seed, newest first once added.
    public static func seeds(now: Date = Date()) -> [Bookmark] {
        [
            Bookmark(sessionKey: self.tripSessionKey, messageId: self.tripMessageId,
                     preview: "Wash thoroughly at the shower stools first, keep the small towel out of the water, and tie up long hair.",
                     role: "assistant", messageDate: nil, createdAt: now.addingTimeInterval(-3)),
            Bookmark(sessionKey: DemoGateway.toolCardsKey, messageId: self.toolsExecMessageId,
                     preview: "Checking the status of each server.", role: "assistant", createdAt: now.addingTimeInterval(-2)),
            Bookmark(sessionKey: DemoGateway.toolCardsKey, messageId: self.toolsSummaryMessageId,
                     preview: Bookmark.preview(DemoGateway.toolCardsPreview), role: "assistant", createdAt: now.addingTimeInterval(-1)),
        ]
    }

    /// Adds the starter bookmarks when the store has none.
    @MainActor
    public static func seed(into store: BookmarkStore) {
        guard store.bookmarks.isEmpty else { return }
        for bookmark in self.seeds() { store.add(bookmark) }
    }
}
