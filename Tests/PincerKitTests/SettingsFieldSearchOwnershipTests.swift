#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private final class FieldSearchWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    func holdFirst() {
        guard !Thread.isMainThread else { return }
        condition.lock()
        guard !entered else { condition.unlock(); return }
        entered = true
        let waiter = arrival; arrival = nil; waiter?.resume()
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitEntered() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                condition.lock()
                if entered || released || Task.isCancelled { condition.unlock(); waiter.resume() }
                else { arrival = waiter; condition.unlock() }
            }
        } onCancel: { self.release() }
    }
    func release() {
        condition.lock(); released = true
        let waiter = arrival; arrival = nil
        condition.broadcast(); condition.unlock(); waiter?.resume()
    }
}

@MainActor @Suite("Settings field search ownership", .timeLimit(.minutes(2)))
struct SettingsFieldSearchOwnershipTests {
    private func model(count: Int = 2, helpBytes: Int = 0) async -> GatewaySettingsModel {
        let response = await Task.detached {
            var fields: [String: JSONValue] = [:]
            for index in 0..<count {
                fields[String(format: "field%05d", index)] = ["type": "string", "title": .string("Label " + String(index)),
                    "description": .string(String(repeating: "x", count: helpBytes) + " needle")]
            }
            return JSONValue.object(["schema": ["type": "object", "properties": .object(fields)]])
        }.value
        var configCount = 0
        let model = GatewaySettingsModel(request: { method, _, _ in
            switch method {
            case "config.schema": return response
            case "config.get": configCount += 1; return ["config": [:], "hash": .string("config-\(configCount)")]
            case "plugins.list": return ["plugins": []]
            default: throw GatewayError.protocolViolation("unexpected search fixture request")
            }
        }, scopes: { [] })
        await model.load(); return model
    }
    @Test func latestQueryReplacesPendingWithoutPublishingAnOlderQuery() async throws {
        let model = await model(); let gate = FieldSearchWorkGate(); defer { gate.release() }
        model.fieldSearchBeforeWork = { gate.holdFirst() }
        let firstID = UUID(), middleID = UUID(), latestID = UUID()
        let first = Task { await model.prepareFieldSearch(matching: "label 0", token: firstID) }
        defer { first.cancel(); gate.release() }
        await gate.waitEntered()
        let middle = Task { await model.prepareFieldSearch(matching: "label 0", token: middleID) }
        try await self.wait { model.fieldSearchBudget.pendingToken == middleID }
        let latest = Task { await model.prepareFieldSearch(matching: "label 1", token: latestID) }
        try await self.wait { model.fieldSearchBudget.pendingToken == latestID }
        #expect(model.fieldSearchBudget.activeCount == 1 && model.fieldSearchBudget.pendingCount == 1)
        gate.release(); await first.value; await middle.value; await latest.value
        let source = model.fieldSearchSourceRevision
        #expect(model.fieldSearchResults(token: firstID, source: source).isEmpty)
        #expect(model.fieldSearchResults(token: middleID, source: source).isEmpty)
        #expect(model.fieldSearchResults(token: latestID, source: source).map(\.key) == ["field00001"])
        #expect(model.ownsFieldSearch(token: latestID, source: source))
    }
    @Test func sourceReplacementRejectsHeldCompletionAndRoutesOnlyFreshFields() async throws {
        let model = await model(); let gate = FieldSearchWorkGate(); defer { gate.release() }
        model.fieldSearchBeforeWork = { gate.holdFirst() }
        let oldID = UUID(), freshID = UUID(); let oldSource = model.fieldSearchSourceRevision
        let old = Task { await model.prepareFieldSearch(matching: "label", token: oldID) }
        defer { old.cancel(); gate.release() }
        await gate.waitEntered(); await model.reloadConfig()
        let fresh = Task { await model.prepareFieldSearch(matching: "label 1", token: freshID) }
        try await self.wait { model.fieldSearchBudget.pendingToken == freshID }; gate.release(); await old.value; await fresh.value
        #expect(!model.ownsFieldSearch(token: oldID, source: oldSource))
        #expect(model.fieldSearchResults(token: oldID, source: model.fieldSearchSourceRevision).isEmpty)
        #expect(model.fieldSearchResults(token: freshID, source: model.fieldSearchSourceRevision).map(\.key) == ["field00001"])
    }
    @Test func cancellationDoesNotReleaseAnActiveWorkerLease() async throws {
        let model = await model(); let gate = FieldSearchWorkGate(); defer { gate.release() }
        model.fieldSearchBeforeWork = { gate.holdFirst() }
        let canceledID = UUID(), freshID = UUID()
        let canceled = Task { await model.prepareFieldSearch(matching: "label 0", token: canceledID) }
        await gate.waitEntered(); canceled.cancel(); await canceled.value
        #expect(model.fieldSearchBudget.activeCount == 1)
        let fresh = Task { await model.prepareFieldSearch(matching: "label 1", token: freshID) }
        try await self.wait { model.fieldSearchBudget.pendingToken == freshID }
        let drain = Task { await model.waitForFieldSearchPreparation() }; drain.cancel(); await drain.value
        #expect(model.fieldSearchBudget.activeCount == 1)
        gate.release(); await fresh.value
        #expect(model.fieldSearchResults(token: canceledID, source: model.fieldSearchSourceRevision).isEmpty)
        #expect(model.fieldSearchResults(token: freshID, source: model.fieldSearchSourceRevision).count == 1)
    }
    @Test(arguments: [false, true]) func oversizedIndexesRemainExactlySearchableWithoutCacheRetention(_ byteLimited: Bool) async {
        let model = await model(count: byteLimited ? 1 : 4097, helpBytes: byteLimited ? 2_200_000 : 0)
        let token = UUID()
        await model.prepareFieldSearch(matching: byteLimited ? "needle" : "field04096", token: token)
        #expect(model.fieldSearchResults(token: token, source: model.fieldSearchSourceRevision).map(\.key) == [byteLimited ? "field00000" : "field04096"])
        #expect(model.fieldSearchBudget.cachedCount == 0 && model.fieldSearchBudget.cachedBytes == 0)
    }
    @Test func warmBoundedIndexAvoidsRetraversalWhileKeepingFullMatching() async {
        let model = await model(); let probe = SettingsFieldSearchProbe(); model.fieldSearchProbe = probe
        await model.prepareFieldSearch(matching: "label 0", token: UUID())
        let before = probe.snapshot(); let token = UUID()
        await model.prepareFieldSearch(matching: "needle field00001", token: token)
        #expect(model.fieldSearchResults(token: token, source: model.fieldSearchSourceRevision).map(\.key) == ["field00001"])
        #expect(probe.snapshot().offMainTraversals == before.offMainTraversals)
        #expect(model.fieldSearchBudget.cachedCount == 2 && model.fieldSearchBudget.cachedBytes <= SettingsFieldSearchPreparation.cacheByteLimit)
        #expect(probe.snapshot().mainTraversals == 0 && probe.snapshot().mainNormalizations == 0
                && probe.snapshot().mainMatches == 0 && probe.snapshot().offMainMatches > 0)
    }
    @Test func currentSnapshotDynamicKeysReplaceThePriorIndex() async {
        var gets = 0
        let model = GatewaySettingsModel(request: { method, _, _ in
            switch method {
            case "config.get":
                gets += 1
                return ["config": .object([gets == 1 ? "first" : "second": "value"]), "hash": .string("dynamic-\(gets)")]
            case "config.schema": return ["schema": ["type": "object", "additionalProperties": ["type": "string"]]]
            case "plugins.list": return ["plugins": []]
            default: throw GatewayError.protocolViolation("unexpected dynamic search request")
            }
        }, scopes: { [] })
        await model.load()
        let old = UUID()
        await model.prepareFieldSearch(matching: "first", token: old)
        #expect(model.fieldSearchResults(token: old, source: model.fieldSearchSourceRevision).map(\.key) == ["first"])
        await model.reloadConfig()
        let latest = UUID()
        await model.prepareFieldSearch(matching: "second", token: latest)
        #expect(model.fieldSearchResults(token: latest, source: model.fieldSearchSourceRevision).map(\.key) == ["second"])
        #expect(model.searchIndex.map(\.key) == ["second"])
    }
    @Test func pendingQueryIsNotACompletedEmptySearch() async {
        let model = await model(); let gate = FieldSearchWorkGate(); defer { gate.release() }
        model.fieldSearchBeforeWork = { gate.holdFirst() }
        let token = UUID(), source = model.fieldSearchSourceRevision
        let search = Task { await model.prepareFieldSearch(matching: "nothing matches", token: token) }
        defer { search.cancel(); gate.release() }
        await gate.waitEntered()
        #expect(model.fieldSearchResults(token: token, source: source).isEmpty)
        #expect(!model.ownsFieldSearch(token: token, source: source), "Pending is not terminal no-match UI")
        gate.release(); await search.value
        #expect(model.fieldSearchResults(token: token, source: source).isEmpty)
        #expect(model.ownsFieldSearch(token: token, source: source), "Only the completed current empty search admits no-match UI")
    }
    private func wait(_ condition: () -> Bool) async throws {
        while !condition() { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
    }

}
#endif
