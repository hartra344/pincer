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
        var writeError: GatewayError?
        var persistBeforeFailure = false
        var secondReadGate: SnapshotGate?
        var snapshotHashOverride: String?
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
                let response: JSONValue = ["resolved": self.config, "hash": .string(self.snapshotHashOverride ?? (self.submitted == nil ? "before" : "after")), "valid": true]
                if self.calls.count(where: { $0.0 == "config.get" }) == 2, let gate = self.secondReadGate { await gate.wait() }
                return response
            case "config.patch", "config.apply":
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
                if self.writeError == nil || self.persistBeforeFailure {
                    self.config = method == "config.apply" ? patch : self.config.applyingMergePatch(patch)
                }
                if let error = self.writeError { throw error }
                return ["ok": true]
            case "plugins.list":
                return ["plugins": []]
            default:
                Issue.record("Unexpected RPC in actual settings save: \(method)")
                return [:]
            }
        }
    }

    @MainActor
    private final class SnapshotGate {
        var entered = false
        var reads = 0
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            self.entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    if self.released || Task.isCancelled { waiter.resume() }
                    else { self.waiter = waiter }
                }
            } onCancel: { Task { @MainActor in self.release() } }
        }
        func release() {
            self.released = true
            let waiter = self.waiter
            self.waiter = nil
            waiter?.resume()
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
    @Test(.timeLimit(.minutes(2)))
    func rawApplyReplacesEarlierFormEditButRetainsLaterIntent() async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let raw: JSONValue = ["gateway": ["port": 19000, "bind": "loopback"]]
        let save = Task { await model.saveRaw(raw.compactString()) }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.set(Self.bind, "lan")
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && gateway.config == raw)
        #expect(model.value(at: Self.port) == 19000 && !model.isChanged(Self.port),
                "Raw Apply deliberately replaces edits that existed before it was admitted")
        #expect(model.value(at: Self.bind) == "lan" && model.savedValue(at: Self.bind) == "loopback" && model.isChanged(Self.bind))
    }

    @Test(.timeLimit(.minutes(2)))
    func persistedButNotAppliedStillAcknowledgesOnlyAdmittedIntent() async throws {
        let gateway = Gateway()
        let persisted: JSONValue = ["gateway": ["port": 18790, "bind": "loopback"]]
        gateway.persistBeforeFailure = true
        gateway.writeError = .rpc(code: "UNAVAILABLE", message: "Saved, restart failed", details: [
            "persistedConfig": ["config": persisted, "hash": "after"]])
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.set(Self.port, 18791)
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && gateway.config == persisted)
        #expect(model.savedValue(at: Self.port) == 18790 && model.value(at: Self.port) == 18791 && model.hasChanges)
        #expect(model.lastSave?.outcome == .savedNotApplied("Saved, restart failed"))
    }

    @Test(.timeLimit(.minutes(2)))
    func lateFieldEditDoesNotReceiveRejectedEarlierValidationIssues() async throws {
        let gateway = Gateway()
        gateway.writeError = .rpc(code: "INVALID_REQUEST", message: "invalid config", details: [
            "issues": [["path": "gateway.port", "message": "Port rejected"]]])
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.set(Self.port, 18791)
        gateway.release()
        let succeeded = await save.value
        #expect(!succeeded && model.value(at: Self.port) == 18791 && model.savedValue(at: Self.port) == 18789)
        #expect(model.hasChanges && model.writeIssues.isEmpty,
                "A rejected earlier value cannot attach stale field issues to the newer value")
    }

    @Test(.timeLimit(.minutes(2)))
    func discardDuringSaveCannotAdmitASecondWriteAndRemainsUnsavedAfterAcknowledgment() async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.discardChanges()
        let second = await model.save()
        #expect(!second && model.isSaving)
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && model.value(at: Self.port) == 18789 && model.savedValue(at: Self.port) == 18790 && model.hasChanges)
        #expect(gateway.calls.filter { $0.0 == "config.patch" }.count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func olderConfigGetCannotReplaceAnAlreadyPublishedNewerSnapshot() async throws {
        let gate = SnapshotGate()
        let model = GatewaySettingsModel(request: { method, _, _ in
            try #require(method == "config.get")
            gate.reads += 1
            let read = gate.reads
            if read == 2 { await gate.wait() }
            return ["resolved": ["gateway": ["port": .number(read == 3 ? 19001 : 18789)]], "hash": .string("read-\(read)")]
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        let old = Task { await model.reloadConfig() }
        defer { old.cancel(); gate.release() }
        let deadline = ContinuousClock.now + .seconds(15)
        while !gate.entered {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.reloadConfig()
        #expect(model.savedValue(at: Self.port) == 19001)
        gate.release()
        await old.value
        #expect(model.savedValue(at: Self.port) == 19001 && model.snapshot?.hash == "read-3")
    }

    @Test(.timeLimit(.minutes(2)))
    func olderSaveRefreshCannotReplaceNewerReloadOrDropLateIntent() async throws {
        let gateway = Gateway()
        let gate = SnapshotGate()
        gateway.secondReadGate = gate
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release(); gate.release() }
        try await self.waitForPatch(gateway)
        model.set(Self.port, 18791)
        gateway.release()
        let deadline = ContinuousClock.now + .seconds(15)
        while !gate.entered {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        gateway.config = gateway.config.setting("lan", at: Self.bind)
        await model.reloadConfig()
        #expect(model.savedValue(at: Self.bind) == "lan")
        gate.release()
        let succeeded = await save.value
        #expect(succeeded && model.savedValue(at: Self.bind) == "lan" && model.value(at: Self.bind) == "lan")
        #expect(model.value(at: Self.port) == 18791 && model.savedValue(at: Self.port) == 18790 && model.isChanged(Self.port))
    }

    @Test(.timeLimit(.minutes(2)))
    func serverOnlyMidSaveReloadMustNotBecomeALocalEditAgainstNewerAcknowledgment() async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        gateway.config = gateway.config.setting("lan", at: Self.bind)
        await model.reloadConfig()
        try #require(model.value(at: Self.bind) == "lan" && !model.isChanged(Self.bind))
        gateway.config = gateway.config.setting("auto", at: Self.bind)
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && gateway.config.value(at: Self.bind) == "auto")
        #expect(model.savedValue(at: Self.bind) == "auto" && model.value(at: Self.bind) == "auto",
                "An unrelated server-only reload must not overwrite a newer acknowledged server value")
        #expect(!model.isChanged(Self.bind) && !model.hasChanges)
    }

    @Test(.timeLimit(.minutes(2)))
    func olderPersistedErrorCannotReplaceNewerReloadSnapshot() async throws {
        let gateway = Gateway()
        let persisted: JSONValue = ["gateway": ["port": 18790, "bind": "loopback"]]
        gateway.persistBeforeFailure = true
        gateway.writeError = .rpc(code: "UNAVAILABLE", message: "Saved, restart failed", details: [
            "persistedConfig": ["config": persisted, "hash": "older-write"]])
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        model.set(Self.port, 18791)
        gateway.config = ["gateway": ["port": 18790, "bind": "lan"]]
        gateway.snapshotHashOverride = "newer-reload"
        await model.reloadConfig()
        try #require(model.snapshot?.hash == "newer-reload" && model.savedValue(at: Self.bind) == "lan")
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded)
        #expect(model.snapshot?.hash == "newer-reload" && model.savedValue(at: Self.bind) == "lan",
                "Response arrival cannot manufacture freshness for an older persistedConfig snapshot")
        #expect(model.value(at: Self.bind) == "lan" && !model.isChanged(Self.bind))
        #expect(model.value(at: Self.port) == 18791 && model.savedValue(at: Self.port) == 18790 && model.isChanged(Self.port))
    }

    @Test(.timeLimit(.minutes(2)), arguments: [false, true])
    func laterParentAndChildEditsKeepTheirActualOrder(_ parentFirst: Bool) async throws {
        let gateway = Gateway()
        let model = GatewaySettingsModel(request: { method, params, timeout in
            try await gateway.request(method, params, timeout)
        }, scopes: { [GatewayConnection.adminScope] })
        await model.reloadConfig()
        model.set(Self.port, 18790)
        let save = Task { await model.save() }
        defer { save.cancel(); gateway.release() }
        try await self.waitForPatch(gateway)
        let parent: JSONValue = ["port": 19000, "bind": "lan"]
        if parentFirst {
            model.set(["gateway"], parent)
            model.set(Self.port, 19001)
        } else {
            model.set(Self.port, 19001)
            model.set(["gateway"], parent)
        }
        gateway.release()
        let succeeded = await save.value
        #expect(succeeded && model.savedValue(at: Self.port) == 18790)
        #expect(model.value(at: Self.port) == .number(parentFirst ? 19001 : 19000))
        #expect(model.value(at: Self.bind) == "lan" && model.hasChanges)
    }

}
