#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Tools search ownership", .timeLimit(.minutes(2)))
struct ToolsInspectorSearchOwnershipTests {
    actor Gate {
        var entered = false, open = false
        var admission: CheckedContinuation<Void, Never>?
        var held: CheckedContinuation<Void, Never>?
        func holdFirst() async {
            guard !entered else { return }
            entered = true; admission?.resume(); admission = nil
            if !open { await withCheckedContinuation { held = $0 } }
        }
        func wait() async { if !entered && !open { await withCheckedContinuation { admission = $0 } } }
        func release() { open = true; admission?.resume(); admission = nil; held?.resume(); held = nil }
    }
    @Test(arguments: [false, true])
    func completedOldWorkerCannotPublishAcrossLatestOrCancellation(cancel: Bool) async {
        let inspection = await Task.detached {
            ToolsInspection.build(catalog: ToolCatalog(["groups": [["id": "g", "label": "Group", "tools": [
                ["id": "one", "label": "One", "description": "first needle"],
                ["id": "two", "label": "Two", "description": "second needle"]]]]]), effective: nil)
        }.value
        let preparation = ToolsInspectorSearchPreparation(), gate = Gate()
        preparation.didPrepare = { await gate.holdFirst() }
        let owner = UUID()
        let first = Task { await preparation.prepare(inspection, filter: .all, query: "first", owner: owner, sourceRevision: 1) }
        defer { first.cancel(); preparation.invalidate(); Task { await gate.release() } }
        await withTaskCancellationHandler {
            await gate.wait()
            #expect(preparation.activeCount == 1 && preparation.result == nil)
            let second = Task { await preparation.prepare(inspection, filter: .all, query: "second", owner: owner, sourceRevision: 2) }
            // Yield until actual second admission, not an assumed delay or worker completion.
            while preparation.pendingCount == 0 && !Task.isCancelled { await Task.yield() }
            #expect(preparation.activeCount == 1 && preparation.pendingCount == 1)
            if cancel { preparation.invalidate() }
            await gate.release()
            let old = await first.value
            let latest = await second.value
            #expect(old == nil)
            if cancel { #expect(latest == nil && preparation.result == nil) }
            else {
                #expect(latest?.groups.flatMap(\.tools).map(\.id) == ["two"])
                #expect(preparation.owns(owner, sourceRevision: 2) && !preparation.owns(owner, sourceRevision: 1))
            }
            #expect(preparation.activeCount == 0 && preparation.pendingCount == 0)
        } onCancel: { Task { await gate.release() } }
    }
    @Test func actualModelReloadInvalidatesCompletedOldSource() async {
        var label = "Old label"
        let model = ToolsInspectorModel(scope: .agent("main", sessionKey: nil), methods: { ["tools.catalog"] }) { _, _ in
            ["groups": [["id": "g", "label": "Group", "tools": [["id": "one", "label": .string(label), "description": "needle"]]]]]
        }
        await model.load()
        let gate = Gate(), owner = UUID()
        model.searchPreparation.didPrepare = { await gate.holdFirst() }
        let old = Task { await model.prepareDisplaySearch(.all, matching: "needle", owner: owner) }
        defer { old.cancel(); model.searchPreparation.invalidate(); Task { await gate.release() } }
        await withTaskCancellationHandler {
            await gate.wait()
            label = "New label"
            await model.load()
            await gate.release()
            #expect(await old.value == nil)
            let new = await model.prepareDisplaySearch(.all, matching: "needle", owner: owner)
            #expect(new?.groups.flatMap(\.tools).first?.label == "New label")
            #expect(model.searchPreparation.owns(owner, sourceRevision: model.searchSourceRevision))
        } onCancel: { Task { await gate.release() } }
    }

}
#endif
