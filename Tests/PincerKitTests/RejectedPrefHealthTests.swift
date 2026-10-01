import Testing
@testable import PincerKit

@MainActor
@Suite("Gateway rejected preferences in Health")
struct RejectedPrefHealthTests {
    @Test func rowsAreStableFeatureLabeledAndPreserveGatewayMessages() {
        let rows = RejectedPrefHealthRow.rows(from: [
            GatewayStore.chatColorsPref: "color map is too large",
            Bookmark.prefKey(shard: 2): "bookmark shard exceeds limit",
            Reactions.prefKey: "value-too-large",
            "pincer.futurePreference": "unknown preference",
        ])

        #expect(rows.map(\.id) == [Bookmark.prefKey(shard: 2), GatewayStore.chatColorsPref,
                                    "pincer.futurePreference", Reactions.prefKey])
        #expect(rows.map(\.feature) == [.bookmarks, .chatColors, .other, .reactions])
        #expect(rows.map(\.message) == ["bookmark shard exceeds limit", "color map is too large",
                                         "unknown preference", "value-too-large"])
    }

    @Test func removedRejectionsProduceNoHealthRows() {
        #expect(RejectedPrefHealthRow.rows(from: [:]).isEmpty)
    }
}
