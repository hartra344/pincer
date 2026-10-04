import Foundation
import Testing
@testable import PincerKit
@MainActor private final class DeviceLoadGate {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                entry?.resume(); entry = nil
                if released || Task.isCancelled { continuation.resume() }
                else { delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered || Task.isCancelled { continuation.resume() } else { entry = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }
    func release() {
        released = true
        entry?.resume(); entry = nil
        delivery?.resume(); delivery = nil
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct DeviceLoadAdmissionTests {
    static var response: JSONValue { ["pending": .array([DeviceFixtures.pending("request-a", deviceId: "pending-device")]), "paired": .array([DeviceFixtures.paired("paired-device")])] }
    @Test func preCanceledLoadCannotDisplaceHealthyRead() async throws {
        let gate = DeviceLoadGate(); var requests = 0; let response = Self.response
        let model = DeviceManagementModel { method, params in
            #expect(method == DeviceManagementModel.listMethod && params == [:])
            requests += 1; try Task.checkCancellation(); await gate.hold(); return response
        }
        let healthy = Task { await model.load() }; defer { healthy.cancel(); gate.release() }
        try await gate.waitForEntry()
        let canceled = Task { await model.load() }; canceled.cancel(); await canceled.value
        #expect(requests == 1)
        gate.release(); await healthy.value
        #expect(model.pending == response["pending"]!.array!.compactMap(PendingDeviceRequest.init))
        #expect(model.paired == response["paired"]!.array!.compactMap(PairedDevice.init))
        #expect(model.hasLoaded && model.loadState == .idle)
    }
    @Test func ordinaryNewerLoadWins() async throws {
        let gate = DeviceLoadGate(); var requests = 0
        let model = DeviceManagementModel { _, _ in
            requests += 1; let number = requests
            if number == 1 { await gate.hold() }
            return number == 1 ? Self.response : ["pending": [], "paired": []]
        }
        let old = Task { await model.load() }; defer { old.cancel(); gate.release() }
        try await gate.waitForEntry(); await model.load(); gate.release(); await old.value
        #expect(requests == 2 && model.pending.isEmpty && model.paired.isEmpty && model.loadState == .idle)
    }
    @Test func currentFailureRemainsVisible() async {
        let model = DeviceManagementModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "device list unavailable", details: nil) }
        await model.load()
        #expect(model.loadState == .failed("device list unavailable") && model.hasLoaded)
    }
}

// These controls cover the new post-admission publication guard independently of the neutral case.
extension DeviceLoadAdmissionTests {
    @Test(arguments: [false, true])
    func canceledAdmittedReadCannotPublishLateSuccessOrFailure(fails: Bool) async throws {
        let gate = DeviceLoadGate()
        let model = DeviceManagementModel { _, _ in
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "late device error", details: nil) }
            return Self.response
        }
        let load = Task { await model.load() }; defer { load.cancel(); gate.release() }
        try await gate.waitForEntry()
        load.cancel(); gate.release(); await load.value
        #expect(model.pending.isEmpty && model.paired.isEmpty && !model.hasLoaded)
        #expect(model.loadState == .idle && model.notice == nil)
    }
}
