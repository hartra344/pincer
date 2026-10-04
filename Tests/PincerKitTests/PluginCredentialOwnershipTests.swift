import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Plugin credential request ownership")
struct PluginCredentialOwnershipTests {
    private func plugin(_ id: String) throws -> PluginInfo {
        try #require(PluginInfo(["id": .string(id), "name": .string(id), "enabled": true]))
    }
    // Pinned upstream plugins.inspect: descriptor metadata only, never secret values.
    private static func response(_ id: String, _ label: String) -> JSONValue {
        ["credentials": [["path": .array(["plugins", "entries", id, "config", "apiKey"].map(JSONValue.string)),
                          "label": .string(label), "envVars": ["EXAMPLE_API_KEY"],
                          "requiresCredential": true, "status": "missing"]]]
    }
    @MainActor private final class Requests {
        var entered = 0
        var failures: Set<Int> = []
        var released: Set<Int> = []
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        func release(_ index: Int) { released.insert(index); waiters.removeValue(forKey: index)?.resume() }
        func releaseAll() { for index in 1...max(entered, 2) { release(index) } }
        func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
            #expect(method == "plugins.inspect" && timeout == 20)
            let id = try #require(params["pluginId"]?.text)
            #expect(params == ["pluginId": .string(id)])
            entered += 1
            let index = entered
            // Deliberately deliver a completed response even after cancellation:
            // model publication must not depend on transport cooperation.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released.contains(index) || Task.isCancelled { continuation.resume() }
                    else { waiters[index] = continuation }
                }
            } onCancel: { Task { @MainActor in self.release(index) } }
            if failures.contains(index) { throw GatewayError.closed("inspection failed") }
            return PluginCredentialOwnershipTests.response(id, "Catalog \(index)")
        }
    }
    private func model(_ requests: Requests) -> GatewaySettingsModel {
        GatewaySettingsModel(request: { try await requests.request($0, $1, $2) }, scopes: { [] })
    }
    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func olderInspectionCannotReplaceLatestDescriptorList(_ cancelOld: Bool) async throws {
        let requests = Requests(), model = model(requests)
        let selected = try plugin("example")
        let old = Task { await model.loadCredentials(for: selected) }
        defer { requests.releaseAll(); old.cancel() }
        try #require(await eventually { requests.entered == 1 })
        let latest = Task { await model.loadCredentials(for: selected) }
        defer { latest.cancel() }
        try #require(await eventually { requests.entered == 2 })
        requests.release(2); await latest.value
        let expected = Self.response("example", "Catalog 2")["credentials"]!.array!.compactMap(PluginCredential.init)
        try #require(model.credentials["example"] == expected)
        if cancelOld { old.cancel() }
        requests.release(1); await old.value
        #expect(model.credentials["example"] == expected, "Old response must not replace the newer actual metadata")
        #expect(requests.entered == 2)
    }
    @Test(.timeLimit(.minutes(2))) func ordinaryAndFailedCurrentInspectionPreserveExistingPolicy() async throws {
        let requests = Requests(), model = model(requests)
        let selected = try plugin("example")
        requests.release(1)
        await model.loadCredentials(for: selected)
        let prior = try #require(model.credentials["example"])
        #expect(prior.first?.label == "Catalog 1")
        requests.failures.insert(2); requests.release(2)
        await model.loadCredentials(for: selected)
        #expect(model.credentials["example"] == prior, "Inspection failure keeps previously loaded descriptors")
    }
    @Test(.timeLimit(.minutes(2))) func differentPluginRequestsRemainIndependent() async throws {
        let requests = Requests(), model = model(requests)
        let firstPlugin = try plugin("example"), secondPlugin = try plugin("example.docs")
        let first = Task { await model.loadCredentials(for: firstPlugin) }
        defer { requests.releaseAll(); first.cancel() }
        try #require(await eventually { requests.entered == 1 })
        requests.release(2)
        await model.loadCredentials(for: secondPlugin)
        requests.release(1); await first.value
        #expect(model.credentials["example"]?.first?.label == "Catalog 1")
        #expect(model.credentials["example.docs"]?.first?.label == "Catalog 2")
    }
    @Test(.timeLimit(.minutes(2))) func preCanceledCallerDoesNotDisplaceHealthyInspection() async throws {
        let requests = Requests(), model = model(requests)
        let selected = try plugin("example")
        let healthy = Task { await model.loadCredentials(for: selected) }
        defer { requests.releaseAll(); healthy.cancel() }
        try #require(await eventually { requests.entered == 1 })
        let canceled = Task { await model.loadCredentials(for: selected) }
        canceled.cancel(); await canceled.value
        #expect(requests.entered == 1)
        requests.release(1); await healthy.value
        #expect(model.credentials["example"]?.first?.label == "Catalog 1")
    }
    @Test(.timeLimit(.minutes(2))) func canceledCurrentInspectionDoesNotPublishCompletedTransportResponse() async throws {
        let requests = Requests(), model = model(requests)
        let selected = try plugin("example")
        let current = Task { await model.loadCredentials(for: selected) }
        defer { requests.releaseAll(); current.cancel() }
        try #require(await eventually { requests.entered == 1 })
        current.cancel(); requests.release(1); await current.value
        #expect(model.credentials["example"] == nil)
    }
}
