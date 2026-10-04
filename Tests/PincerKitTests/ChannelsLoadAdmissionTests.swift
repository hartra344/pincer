import Foundation
import Testing
@testable import PincerKit

@MainActor private final class ChannelsReadGate {
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
                if entered || Task.isCancelled { continuation.resume() }
                else { entry = continuation }
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
struct ChannelsLoadAdmissionTests {
    // Official channels.status schema/handler at bca3c49262e585c0fe2f52b8af7b113d262e783c.
    // The established fixture includes full account, issue, warning and timestamp metadata.
    @Test(arguments: [false, true])
    func canceledReadCannotDisplaceCurrentStatus(probe: Bool) async throws {
        let gate = ChannelsReadGate()
        let response = ChannelFixtures.status
        let expected = try #require(ChannelsStatusSnapshot(response))
        try #require(!expected.channels.isEmpty)
        var calls = 0
        let model = ChannelsModel(request: { method, params in
            calls += 1 // Count actual attempts BEFORE cancellation can reject the request.
            #expect(method == ChannelsModel.statusMethod)
            #expect(params == ["probe": false] || params == ["probe": true, "timeoutMs": .number(Double(ChannelsModel.probeTimeoutMs))])
            try Task.checkCancellation()
            await gate.hold() // Hold an already-computed response at the local delivery boundary.
            return response
        })
        let current = Task { await model.load() }
        defer { gate.release(); current.cancel() }
        try await gate.waitForEntry()
        try #require(calls == 1 && model.loadState == .running)
        let canceled = Task { if probe { await model.probe() } else { await model.load() } }
        canceled.cancel() // Same actor: the child cannot enter before the parent first suspends.
        await canceled.value
        #expect(calls == 1)
        gate.release(); await current.value
        #expect(model.snapshot == expected)
        #expect(model.loadState == .idle && model.hasLoaded && !model.isProbing && model.supported)
    }

    @Test func ordinaryNewerProbeWins() async throws {
        let gate = ChannelsReadGate()
        let oldResponse = ChannelFixtures.status
        var object = try #require(oldResponse.object)
        object["ts"] = .number(1700000001000)
        let newerResponse = JSONValue.object(object)
        let expected = try #require(ChannelsStatusSnapshot(newerResponse))
        var calls = 0
        let model = ChannelsModel(request: { method, params in
            calls += 1
            #expect(method == ChannelsModel.statusMethod)
            if calls == 1 {
                #expect(params == ["probe": false])
                await gate.hold()
                return oldResponse
            }
            #expect(params == ["probe": true, "timeoutMs": .number(Double(ChannelsModel.probeTimeoutMs))])
            return newerResponse
        })
        let old = Task { await model.load() }
        defer { gate.release(); old.cancel() }
        try await gate.waitForEntry()
        await model.probe()
        gate.release(); await old.value
        #expect(calls == 2 && model.snapshot == expected)
        #expect(model.loadState == .idle && model.hasLoaded && !model.isProbing)
    }

    @Test func currentUnavailableRemainsVisible() async {
        let model = ChannelsModel(request: { method, params in
            #expect(method == ChannelsModel.statusMethod && params == ["probe": false])
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Current channel status unavailable", details: nil)
        })
        await model.load()
        #expect(model.loadState == .failed("Current channel status unavailable"))
        #expect(model.snapshot == nil && model.hasLoaded && model.supported && !model.isProbing)
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ChannelsAdmittedCancellationTests {
    @Test(arguments: [false, true])
    func canceledProbeRetainsSnapshotAndDoesNotPublishLateResult(fails: Bool) async throws {
        let gate = ChannelsReadGate()
        let response = ChannelFixtures.status
        let expected = try #require(ChannelsStatusSnapshot(response))
        var calls = 0
        let model = ChannelsModel(request: { _, _ in
            calls += 1
            if calls == 1 { return response }
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Canceled channel error", details: nil) }
            var object = response.object ?? [:]
            object["ts"] = .number(1700000002000)
            return .object(object)
        })
        await model.load()
        let canceled = Task { await model.probe() }
        defer { gate.release(); canceled.cancel() }
        try await gate.waitForEntry()
        try #require(model.loadState == .running && model.isProbing)
        canceled.cancel(); gate.release(); await canceled.value
        #expect(calls == 2 && model.snapshot == expected)
        #expect(model.loadState == .idle && model.hasLoaded && model.supported && !model.isProbing)
    }

    @Test func canceledOlderReadCannotIdleNewerProbe() async throws {
        let oldGate = ChannelsReadGate(), newGate = ChannelsReadGate()
        let response = ChannelFixtures.status
        let expected = try #require(ChannelsStatusSnapshot(response))
        var calls = 0
        let model = ChannelsModel(request: { _, _ in
            calls += 1
            if calls == 1 { await oldGate.hold() } else { await newGate.hold() }
            return response
        })
        let old = Task { await model.load() }
        defer { oldGate.release(); newGate.release(); old.cancel() }
        try await oldGate.waitForEntry()
        let newer = Task { await model.probe() }
        defer { newer.cancel() }
        try await newGate.waitForEntry()
        old.cancel(); oldGate.release(); await old.value
        #expect(model.loadState == .running && model.isProbing && !model.hasLoaded && model.snapshot == nil)
        newGate.release(); await newer.value
        #expect(calls == 2 && model.snapshot == expected)
        #expect(model.loadState == .idle && model.hasLoaded && !model.isProbing)
    }

    @Test func advertisedUnsupportedStatusStillCompletesWithoutRPC() async {
        var calls = 0
        let model = ChannelsModel(methods: { ["health"] }, request: { _, _ in calls += 1; return [:] })
        await model.load()
        #expect(calls == 0 && !model.supported && model.hasLoaded && model.loadState == .idle && !model.isProbing)
    }

    @Test func currentUnknownMethodRemainsUnsupported() async {
        let model = ChannelsModel(request: { _, _ in
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: channels.status", details: nil)
        })
        await model.probe()
        #expect(!model.supported && model.hasLoaded && model.snapshot == nil && model.loadState == .idle && !model.isProbing)
    }
}
