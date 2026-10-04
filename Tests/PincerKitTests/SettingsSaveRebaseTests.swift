import Foundation
import Testing
@testable import PincerKit

/// Holds the actual config.patch request emitted by GatewaySettingsModel.save. Only that
/// captured patch reaches the fixture Gateway; later local edits must survive its config.get.
@MainActor
@Suite("Settings save preserves concurrent edits")
struct SettingsSaveRebaseTests {
    private static let port = ["gateway", "port"]
    private static let bind = ["gateway", "bind"]

    @MainActor
    private final class Gateway {
        var config: JSONValue = ["gateway": ["port": 18789, "bind": "loopback"]]
        var calls: [(String, JSONValue, TimeInterval)] = []
        var submitted: JSONValue?
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func release() {
            self.released = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume()
        }

        func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
            self.calls.append((method, params, timeout))
            switch method {
            case "config.get":
                return ["resolved": self.config, "hash": .string(self.submitted == nil ? "before" : "after"), "valid": true]
            case "config.patch":
                let raw = try #require(params["raw"]?.text)
                let patch = try JSONValue.decode(Data(raw.utf8))
                self.submitted = patch
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if self.released || Task.isCancelled { continuation.resume() }
                        else { self.continuation = continuation }
                    }
                } onCancel: {
                    Task { @MainActor in self.release() }
                }
                try Task.checkCancellation()
                self.config = self.config.applyingMergePatch(patch)
                return ["ok": true]
            default:
                Issue.record("Unexpected RPC in actual settings save: \(method)")
                return [:]
            }
        }
    }

    private func waitForPatch(_ gateway: Gateway) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while gateway.submitted == nil {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "The actual save never emitted config.patch")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    enum LaterEdit: String, CaseIterable, Sendable {
        case unchanged, differentPath, samePath, delete, revert
    }

    @Test(.timeLimit(.minutes(2)), arguments: LaterEdit.allCases)
    func actualSaveAcknowledgesOnlyItsCapturedPatch(_ later: LaterEdit) async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        try #require(model.savedValue(at: Self.port) == 18789 && !model.hasChanges)
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        try #require(model.isSaving)
        #expect(gateway.submitted == ["gateway": ["port": 18790]])
        let request = try #require(gateway.calls.first { $0.0 == "config.patch" })
        #expect(request.1["baseHash"] == "before" && request.1["note"] == "Pincer: Gateway Settings" && request.2 == 60)
        switch later {
        case .unchanged: break
        case .differentPath: model.set(Self.bind, "lan")
        case .samePath: model.set(Self.port, 18791)
        case .delete: model.set(Self.port, nil)
        case .revert:
            model.revert(Self.port)
            #expect(!model.hasChanges, "Revert legitimately removes the pre-acknowledgment edit")
        }
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && !model.isSaving)
        #expect(gateway.calls.map { $0.0 } == ["config.get", "config.patch", "config.get"])
        #expect(gateway.config.value(at: Self.port) == 18790 && gateway.config.value(at: Self.bind) == "loopback",
                "Only the already captured patch was acknowledged by the Gateway")
        #expect(model.savedValue(at: Self.port) == 18790)
        switch later {
        case .unchanged:
            #expect(!model.hasChanges && model.value(at: Self.port) == 18790)
        case .differentPath:
            #expect(model.hasChanges && model.isChanged(Self.bind))
            #expect(model.value(at: Self.bind) == "lan" && model.savedValue(at: Self.bind) == "loopback")
            #expect(!model.isChanged(Self.port))
        case .samePath:
            #expect(model.hasChanges && model.isChanged(Self.port) && model.value(at: Self.port) == 18791)
        case .delete:
            #expect(model.hasChanges && model.isChanged(Self.port) && model.value(at: Self.port) == nil)
        case .revert:
            #expect(model.hasChanges && model.isChanged(Self.port) && model.value(at: Self.port) == 18789,
                    "A revert made while Save waits is still intent against the newly acknowledged base")
        }
        #expect(model.conflicts.isEmpty, "Acknowledging our own admitted write is not a competing Gateway edit")
    }

    @Test(.timeLimit(.minutes(2)))
    func lateInvalidTextRetainsActualFieldInputAndErrorAfterSave() async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        let schema = ConfigSchema(schema: ["type": "object", "properties": ["gateway": ["type": "object",
            "properties": ["port": ["type": "integer"]]]]])
        let field = try #require(schema.field(at: Self.port, value: 18789))
        try #require(field.kind == .integer)
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.setText("not-a-port", for: field)
        try #require(model.inputError(for: field) != nil)
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded)
        #expect(model.savedValue(at: Self.port) == 18790)
        #expect(model.text(for: field) == "not-a-port" && model.inputError(for: field) != nil,
                "Successful earlier Save cannot erase newer invalid input and its actionable error")
    }
}
