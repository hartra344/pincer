import Foundation
import Testing
@testable import PincerKit

private final class RawValidationGate: @unchecked Sendable {
    let lock = NSLock()
    private var entered = false
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    #if DEBUG
    private let gate = ExplicitWorkerTestGate()
    private func recordEntry() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = !entered; entered = true
        return first
    }
    func observe() async {
        if recordEntry() { await gate.hold() }
    }
    func waitUntilEntered() async -> Bool { await gate.waitUntilEntered(timeout: 10) }
    func open() { gate.open() }
    #else
    let release = DispatchSemaphore(value: 0)
    func observe() {
        lock.lock(); let first = !entered; entered = true; lock.unlock()
        if first { _ = release.wait(timeout: .now() + 15) }
    }
    func open() { release.signal() }
    #endif
}

@MainActor @Suite("Raw config editor intent")
struct RawConfigEditorDraftTests {
    @Test func delayedInitialSnapshotPreservesExistingUserIntent() async {
        let draft = RawConfigEditorDraft()
        draft.edit("{local:1}")
        draft.updateSnapshot("{remote:2}")
        await draft.waitForValidation()
        #expect(draft.text == "{local:1}" && draft.baseline == "{remote:2}" && draft.isEdited)
    }
    @Test(.timeLimit(.minutes(2))) func acknowledgementPreservesTypingRevertAndABA() async throws {
        for later in ["unchanged", "typing", "revert", "aba"] {
            let draft = RawConfigEditorDraft()
            let before = "{port:1}", submitted = "{port:2}", newest = "{port:3}"
            draft.updateSnapshot(before)
            draft.edit(submitted)
            await draft.waitForValidation()
            #expect(!draft.validationPending && draft.validationError == nil)
            let revision = try #require(draft.beginSave())
            #expect(draft.beginSave() == nil, "an actual admitted save cannot overlap")
            switch later {
            case "typing": draft.edit(newest)
            case "revert": draft.revert()
            case "aba": draft.edit(newest); draft.edit(before)
            default: break
            }
            draft.updateSnapshot(submitted)
            draft.finishSave(admission: revision, acknowledgedRaw: submitted)
            await draft.waitForValidation()
            #expect(draft.baseline == submitted)
            #expect(draft.text == (later == "unchanged" ? submitted : later == "typing" ? newest : before))
            #expect(draft.isEdited == (later != "unchanged"))
        }
    }
    @Test(.timeLimit(.minutes(2))) func oneActiveValidationPublishesOnlyTheLatestReplacement() async throws {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{}")
        let gate = RawValidationGate()
        #if DEBUG
        draft.validationObserver = { await gate.observe() }
        #else
        draft.validationObserver = { gate.observe() }
        #endif
        defer { gate.open() }
        draft.edit("{valid:1}")
        #if DEBUG
        let oldValidation = draft.actualValidationTaskForTesting
        do {
            let entered = await gate.waitUntilEntered()
            try Task.checkCancellation()
            try #require(entered)
        } catch {
            gate.open()
            await oldValidation?.value
            await draft.waitForValidation()
            throw error
        }
        #else
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.hasEntered {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #endif
        for value in 0..<100 { draft.edit("{value:\(value)}") }
        draft.edit("{broken")
        #expect(draft.validationPending && draft.validationError == nil)
        gate.open()
        #if DEBUG
        await oldValidation?.value
        #endif
        await draft.waitForValidation()
        #expect(!draft.validationPending && draft.validationError != nil && draft.text == "{broken")
        draft.revert()
        #expect(!draft.isEdited && !draft.validationPending)
        await draft.waitForValidation()
        #expect(draft.validationError == nil && !draft.validationPending)
    }
    @Test func failedSaveRetainsLatestIntentAndInvalidText() async throws {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{}")
        draft.edit("{submitted:1}")
        await draft.waitForValidation()
        let revision = try #require(draft.beginSave())
        draft.edit("invalid")
        draft.finishSave(admission: revision, acknowledgedRaw: nil)
        await draft.waitForValidation()
        #expect(draft.text == "invalid" && draft.baseline == "{}" && draft.validationError != nil && draft.isEdited)
    }
    @Test func equalityAndCleanRevertAllowFreshSnapshotsWithoutApplyingUnchangedText() async {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{value:1}")
        draft.edit("{value:2}")
        draft.edit("{value:1}")
        #expect(draft.beginSave() == nil)
        await draft.waitForValidation()
        #expect(!draft.isEdited && draft.beginSave() == nil)
        draft.updateSnapshot("{value:3}")
        #expect(draft.text == "{value:3}")
        draft.edit("{value:4}")
        draft.revert()
        draft.updateSnapshot("{value:5}")
        #expect(draft.text == "{value:5}" && !draft.isEdited && draft.beginSave() == nil)
    }
    @Test(.timeLimit(.minutes(2))) func heldComparisonCannotPublishAgainstAnOlderBaseline() async throws {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{value:1}")
        let gate = RawValidationGate()
        #if DEBUG
        draft.validationObserver = { await gate.observe() }
        #else
        draft.validationObserver = { gate.observe() }
        #endif
        defer { gate.open() }
        draft.edit("{value:1}")
        #if DEBUG
        let oldValidation = draft.actualValidationTaskForTesting
        do {
            let entered = await gate.waitUntilEntered()
            try Task.checkCancellation()
            try #require(entered)
        } catch {
            gate.open()
            await oldValidation?.value
            await draft.waitForValidation()
            throw error
        }
        #else
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.hasEntered {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #endif
        draft.updateSnapshot("{value:2}")
        #expect(draft.validationPending && draft.beginSave() == nil)
        gate.open()
        #if DEBUG
        await oldValidation?.value
        #endif
        await draft.waitForValidation()
        #expect(draft.isEdited && draft.text == "{value:1}" && draft.baseline == "{value:2}")
        #expect(!draft.validationPending && draft.validationError == nil)
    }
}
