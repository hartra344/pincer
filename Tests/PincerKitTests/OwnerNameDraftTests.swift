import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite struct OwnerNameDraftTests {
    @Test func flushPersistsLatestEditAndCancelsPendingIdleWrites() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set("Old name", forKey: OwnerNameDraft.storageKey)
        let draft = OwnerNameDraft(defaults: scratch.defaults, wait: { _ in
            try? await Task.sleep(for: .seconds(60))
        })

        #expect(draft.text == "Old name")
        draft.update("M")
        draft.update("Maya Chen")
        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == "Old name",
                "editing changes the local draft without synchronously writing defaults")
        await draft.flush()
        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == "Maya Chen",
                "submit/disappear flushes the exact latest value")
        await Task.yield()
        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == "Maya Chen",
                "a canceled earlier idle write cannot overwrite the flushed value")
    }

    @Test func defaultsWriterRejectsOutOfOrderEdits() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let writer = OwnerNameDefaultsWriter(
            defaults: ThreadSafeDefaults(scratch.defaults), key: OwnerNameDraft.storageKey
        )

        await writer.write("latest", generation: 2)
        await writer.write("stale", generation: 1)

        #expect(scratch.defaults.string(forKey: OwnerNameDraft.storageKey) == "latest")
    }
}
