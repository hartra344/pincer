import Foundation
import Testing
@testable import PincerKit

/// v9 caches predate a way to record whether projected assistant rows have sender attribution.
@Suite("Forwarded sender cache refresh")
@MainActor
struct ForwardedSenderRefreshTests {
    private let legacyVersion = 9

    @Test func v9CacheIsMigratedWithoutDroppingProjectedAssistantRows() throws {
        var forwarded = ChatItem(id: "fwd-1", role: .assistant, blocks: [.text("Hi from the other agent")])
        forwarded.transcriptId = "fwd-1"
        let data = try JSONEncoder().encode(
            TranscriptCache.Snapshot(version: self.legacyVersion, items: [forwarded], complete: true))

        let (snapshot, outcome) = TranscriptCache.decode(data)

        #expect(outcome == .migrated(from: self.legacyVersion),
                "the segmented v9 cache needs the sender-attribution refresh migration")
        #expect(snapshot?.version == self.legacyVersion + 1)
        #expect(snapshot?.items == [forwarded], "migration keeps cached content available offline")
    }

    @Test func oldCompleteAndRetainedCachesMustRefreshEvenWhenActivityMatches() {
        let oldVersion = TranscriptCache.Meta(complete: true, activityMs: 10, version: self.legacyVersion, retained: false)
        let oldRetainedVersion = TranscriptCache.Meta(complete: false, activityMs: 10, version: self.legacyVersion, retained: true)

        #expect(!GatewayStore.prefetchIsFresh(oldVersion, activityMs: 10),
                "a complete v9 cache cannot prove older forwarded rows were attributed")
        #expect(!GatewayStore.prefetchIsFresh(oldRetainedVersion, activityMs: 10),
                "a retained v9 cache also needs the bounded attribution refresh")
    }
}
