import Testing
@testable import PincerKit

@MainActor
@Suite("Voice settings draft")
struct VoiceSettingsDraftTests {
    private func settings(speed: Double, stability: Double = 0.5) -> TTSVoiceSettings {
        var value = TTSVoiceSettings.elevenLabsDefault
        value.speed = speed
        value.stability = stability
        return value
    }

    @Test func firstAcknowledgmentPreservesUnreleasedDrag() throws {
        let draft = VoiceSettingsDraft()
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        draft.edit(settings(speed: 1.5, stability: 0.8))
        #expect(draft.complete(first, acknowledged: first.value) == nil)
        draft.updateSnapshot(first.value)
        #expect(draft.value == settings(speed: 1.5, stability: 0.8))
        #expect(draft.baseline == first.value && draft.activeCount == 0 && draft.pendingCount == 0)
    }

    @Test func onlyLatestReleasedSnapshotQueuesBehindActiveSave() throws {
        let draft = VoiceSettingsDraft()
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        draft.edit(settings(speed: 1.2))
        #expect(draft.commit() == nil)
        draft.edit(settings(speed: 1.7))
        #expect(draft.commit() == nil)
        draft.edit(settings(speed: 1.7, stability: 0.8))
        #expect(draft.activeCount == 1 && draft.pendingCount == 1)
        let next = try #require(draft.complete(first, acknowledged: first.value))
        #expect(next.value == settings(speed: 1.7))
        #expect(draft.complete(first, acknowledged: first.value) == nil)
        #expect(draft.activeCount == 1)
        #expect(draft.complete(next, acknowledged: next.value) == nil)
        #expect(draft.baseline == settings(speed: 1.7))
        #expect(draft.value == settings(speed: 1.7, stability: 0.8))
        #expect(draft.activeCount == 0 && draft.pendingCount == 0)
    }

    @Test func failureKeepsDraftAndAllowsSameValueRetry() throws {
        let draft = VoiceSettingsDraft()
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        #expect(draft.complete(first, acknowledged: nil) == nil)
        #expect(draft.baseline == .elevenLabsDefault && draft.value == first.value)
        let retry = try #require(draft.commit())
        #expect(retry.value == first.value)
        #expect(draft.complete(retry, acknowledged: retry.value) == nil)
        #expect(draft.baseline == first.value && draft.activeCount == 0)
    }

    @Test func failedActiveSaveStillAdvancesLatestCommittedSettings() throws {
        let draft = VoiceSettingsDraft()
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        draft.edit(settings(speed: 1.7))
        #expect(draft.commit() == nil)
        let next = try #require(draft.complete(first, acknowledged: nil))
        #expect(draft.baseline == .elevenLabsDefault && next.value == settings(speed: 1.7))
        #expect(draft.complete(next, acknowledged: next.value) == nil)
        #expect(draft.baseline == next.value && draft.value == next.value)
    }

    @Test func failedPossiblyPersistedSaveStillSendsExplicitQueuedRestore() throws {
        let draft = VoiceSettingsDraft()
        var changed = TTSVoiceSettings.elevenLabsDefault
        changed.speed = 1.5
        draft.edit(changed)
        let first = try #require(draft.commit())
        draft.edit(.elevenLabsDefault)
        #expect(draft.commit() == nil)
        let restore = try #require(draft.complete(first, acknowledged: nil))
        #expect(restore.value == .elevenLabsDefault && draft.activeCount == 1)
        #expect(draft.complete(restore, acknowledged: restore.value) == nil)
        #expect(draft.value == .elevenLabsDefault && draft.baseline == .elevenLabsDefault && draft.activeCount == 0)
    }

    @Test func ABAIntentIsNotMistakenForUnchangedUserRevision() throws {
        let draft = VoiceSettingsDraft()
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        draft.edit(settings(speed: 1.7))
        draft.edit(first.value)
        #expect(draft.revision > first.revision)
        #expect(draft.complete(first, acknowledged: first.value) == nil)
        draft.updateSnapshot(settings(speed: 1.2))
        #expect(draft.value == first.value && draft.baseline == settings(speed: 1.2))
    }

    @Test func noopAndExplicitReturnToSavedValuePermitFreshSnapshot() throws {
        let draft = VoiceSettingsDraft()
        #expect(draft.commit() == nil && draft.activeCount == 0)
        draft.edit(settings(speed: 1.7))
        draft.edit(.elevenLabsDefault)
        #expect(draft.commit() == nil)
        draft.updateSnapshot(settings(speed: 1.2))
        #expect(draft.value == settings(speed: 1.2))
        draft.edit(settings(speed: 1.5))
        let first = try #require(draft.commit())
        #expect(draft.commit() == nil)
        #expect(draft.complete(first, acknowledged: first.value) == nil)
        #expect(draft.activeCount == 0 && draft.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func operationTrackerKeepsAllActiveWorkAndOnlyLatestPublication(_ newerFinishesFirst: Bool) {
        let operations = VoiceSetupOperationTracker()
        let older = operations.begin()
        let newer = operations.begin()
        #expect(operations.busy && operations.activeCount == 2)
        #expect(operations.finish(newerFinishesFirst ? newer : older) == newerFinishesFirst)
        #expect(operations.busy && operations.activeCount == 1)
        #expect(operations.finish(newerFinishesFirst ? older : newer) == !newerFinishesFirst)
        #expect(!operations.busy && operations.activeCount == 0)
    }
}
