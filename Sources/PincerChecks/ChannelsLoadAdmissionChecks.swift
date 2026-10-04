import Foundation
@testable import PincerKit

@MainActor private final class ChannelsStatusReadGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                if released || Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

/// A real status result is computed before the local delivery hold. No Gateway writes or overlays.
@MainActor private func checkChannelsReadAdmission(request: @escaping ChannelsModel.Request) async {
    for probe in [false, true] {
        let gate = ChannelsStatusReadGate()
        var calls = 0
        var held: JSONValue?
        let model = ChannelsModel(request: { method, params in
            calls += 1 // Attempts, including a transport that subsequently rejects cancellation.
            check(method == ChannelsModel.statusMethod
                  && (params == ["probe": false] || params == ["probe": true, "timeoutMs": .number(Double(ChannelsModel.probeTimeoutMs))]),
                  "channel status read uses the exact legal load or probe params")
            try Task.checkCancellation()
            let response = try await request(method, params)
            held = response
            await gate.hold()
            return response
        })
        let current = Task { await model.load() }
        defer { gate.release(); current.cancel() }
        let entered = await waitFor("computed channel status delivery") { gate.entered }
        check(entered, "actual channel status response reaches the local delivery hold")
        guard entered else { gate.release(); current.cancel(); await current.value; return }
        guard let held, let expected = ChannelsStatusSnapshot(held), !expected.channels.isEmpty,
              expected.channels.contains(where: { !$0.accounts.isEmpty }) else {
            check(false, "held actual channel status contains decoded channels and accounts")
            gate.release(); current.cancel(); await current.value; return
        }
        check(calls == 1 && model.loadState == .running, "one actual status read is held and running before cancellation control")
        let canceled = Task { if probe { await model.probe() } else { await model.load() } }
        canceled.cancel() // MainActor parent has not suspended since creating this task.
        await canceled.value
        check(calls == 1, "pre-canceled channel load or probe admits no additional status request")
        gate.release(); await current.value
        check(model.snapshot == expected, "current channel read retains the full actually delivered status snapshot")
        check(model.loadState == .idle && model.hasLoaded && model.supported && !model.isProbing,
              "current channel read completes healthy after canceled caller finishes")
    }
}

@MainActor func runChannelsLoadAdmissionChecks() async {
    // Official schema/handler pin bca3c49262e585c0fe2f52b8af7b113d262e783c.
    await checkChannelsReadAdmission { _, _ in
        ["ts": 1700000000000, "channelOrder": ["discord"],
         "channelLabels": ["discord": "Discord"], "channelDetailLabels": ["discord": "Discord Bot"],
         "channels": ["discord": ["configured": true, "running": true, "connected": true]],
         "channelAccounts": ["discord": [["accountId": "default", "name": "Discord", "enabled": true,
                                         "configured": true, "running": true, "connected": true,
                                         "lastInboundAt": 1699999000000]]],
         "channelDefaultAccountId": ["discord": "default"], "partial": false,
         "warnings": [], "statusIssues": []]
    }
}

@MainActor func runDemoChannelsLoadAdmissionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("Channels admission Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "genuine Demo channel status connection is ready")
    guard connected else { return }
    await checkChannelsReadAdmission { method, params in try await gateway.connection.request(method, params) }
}

@MainActor func runChannelsAdmittedCancellationChecks() async {
    let response: JSONValue = ["ts": 1700000000000, "channelOrder": ["discord"],
                               "channelLabels": ["discord": "Discord"],
                               "channels": ["discord": ["configured": true, "running": true, "connected": true]],
                               "channelAccounts": ["discord": [["accountId": "default", "configured": true, "running": true, "connected": true]]],
                               "channelDefaultAccountId": ["discord": "default"]]
    guard let expected = ChannelsStatusSnapshot(response), !expected.channels.isEmpty else {
        check(false, "admitted cancellation fixture contains a decoded status snapshot"); return
    }
    for fails in [false, true] {
        let gate = ChannelsStatusReadGate()
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
        let entered = await waitFor("admitted canceled channel probe") { gate.entered }
        check(entered, "actual channel probe reaches the response hold")
        guard entered else { gate.release(); canceled.cancel(); await canceled.value; return }
        check(model.isProbing && model.loadState == .running, "admitted probe shows its actual running state")
        canceled.cancel(); gate.release(); await canceled.value
        check(model.snapshot == expected && model.hasLoaded && model.supported,
              "canceled admitted channel probe preserves the full prior snapshot")
        check(model.loadState == .idle && !model.isProbing,
              "canceled admitted success or error clears only its own running state")
    }
    var unsupportedCalls = 0
    let unsupported = ChannelsModel(methods: { ["health"] }, request: { _, _ in unsupportedCalls += 1; return [:] })
    await unsupported.load()
    check(unsupportedCalls == 0 && !unsupported.supported && unsupported.hasLoaded && unsupported.loadState == .idle,
          "advertised unsupported channel status retains its ordinary no-RPC policy")
}
