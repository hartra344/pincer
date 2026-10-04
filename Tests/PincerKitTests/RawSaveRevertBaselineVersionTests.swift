import Foundation
import Testing
@testable import PincerKit

/// The snapshot-hash onChange and the Save task can acknowledge in either order.
/// A completed comparison against the pre-save baseline must not erase later intent.
@MainActor
@Suite("Raw Save reverted baseline ownership", .timeLimit(.minutes(2)))
struct RawSaveRevertBaselineVersionTests {
    enum Later: String, CaseIterable, Sendable { case revert, typing, aba }

    @Test(arguments: Later.allCases, [false, true])
    func completedOldBaselineComparisonDoesNotAuthorizeAcknowledgementReplacement(
        _ later: Later, _ snapshotBeforeFinish: Bool
    ) async throws {
        let draft = RawConfigEditorDraft()
        let baseline = "{gateway:{port:18789}}"
        let submitted = "{gateway:{port:18790}}"
        let typed = "{gateway:{port:18791}}"
        draft.updateSnapshot(baseline)
        draft.edit(submitted)
        await draft.waitForValidation()
        let admission = try #require(draft.beginSave())
        switch later {
        case .revert: draft.revert()
        case .typing: draft.edit(typed)
        case .aba: draft.edit(typed); draft.edit(baseline)
        }
        // Await the actual equality/JSON5 worker, not a guessed UI-settlement delay.
        await draft.waitForValidation()
        #expect(!draft.validationPending && draft.validationError == nil)
        #expect(draft.text == (later == .typing ? typed : baseline))
        #expect(draft.isEdited == (later == .typing), "Revert/ABA are clean only against the old baseline")
        if snapshotBeforeFinish { draft.updateSnapshot(submitted) }
        draft.finishSave(admission: admission, acknowledgedRaw: submitted)
        if !snapshotBeforeFinish {
            // Same production API used by RawConfigPage's deferred snapshot-hash onChange.
            draft.updateSnapshot(submitted)
        }
        await draft.waitForValidation()
        #expect(draft.baseline == submitted && !draft.savePending)
        #expect(draft.text == (later == .typing ? typed : baseline),
                "Acknowledgement order must preserve the actual post-admission Revert/typing/ABA intent")
        #expect(draft.isEdited && !draft.validationPending && draft.validationError == nil,
                "The preserved text differs from the newly acknowledged baseline")
    }

    @Test func ordinaryCleanRevertStillAcceptsFreshSnapshot() async {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{value:1}")
        draft.edit("{value:2}")
        await draft.waitForValidation()
        draft.revert()
        await draft.waitForValidation()
        #expect(!draft.isEdited && draft.beginSave() == nil)
        draft.updateSnapshot("{value:3}")
        await draft.waitForValidation()
        #expect(draft.text == "{value:3}" && draft.baseline == "{value:3}" && !draft.isEdited)
    }

    @Test(arguments: [false, true])
    func unchangedAdmissionStillInstallsAcknowledgedSnapshot(_ snapshotBeforeFinish: Bool) async throws {
        let draft = RawConfigEditorDraft()
        draft.updateSnapshot("{value:1}")
        draft.edit("{value:2}")
        await draft.waitForValidation()
        let admission = try #require(draft.beginSave())
        if snapshotBeforeFinish { draft.updateSnapshot("{value:2}") }
        draft.finishSave(admission: admission, acknowledgedRaw: "{value:2}")
        if !snapshotBeforeFinish { draft.updateSnapshot("{value:2}") }
        await draft.waitForValidation()
        #expect(draft.text == "{value:2}" && !draft.isEdited && !draft.savePending)
    }
}
