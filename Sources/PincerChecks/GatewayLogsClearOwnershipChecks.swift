import Foundation
@testable import PincerKit

@MainActor private final class LogClearDeliveryGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { held in
                if released || Task.isCancelled { held.resume() } else { continuation = held }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; let held = continuation; continuation = nil; held?.resume() }
}

@MainActor func runGatewayLogsClearOwnershipChecks() async {
    let gate = LogClearDeliveryGate(); defer { gate.release() }
    var requests = 0
    let model = GatewayLogsModel { method, params in
        check(method == "logs.tail", "Clear ownership uses the actual logs.tail request")
        requests += 1
        if requests > 1 { check(params["cursor"]?.int == (requests - 1) * 10, "Clear keeps advancing the exact cursor") }
        let response: JSONValue = ["file": "/tmp/openclaw/clear-fixture.log", "cursor": JSONValue(requests * 10),
            "size": JSONValue(requests * 10), "lines": .array([.string("{\"level\":\"info\",\"message\":\"fixture\"}")]),
            "truncated": false, "reset": false]
        if requests == 2 { await gate.hold() }
        return response
    }
    await model.poll()
    check(model.lineCount == 1, "current first log page is visible")
    let old = Task { await model.poll() }; defer { old.cancel(); gate.release() }
    let entered = await waitFor("computed log page delivery") { gate.entered }
    check(entered, "already computed log response reaches the actual transport gate")
    guard entered else { return }
    model.clear(); gate.release(); await old.value
    check(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0 && !model.showsRecentOnly,
          "Clear stays empty after actual older poll completion")
    check(model.cursor == 20 && !model.isFetching, "discarded old display data advances cursor and releases busy state")
    await model.poll()
    check(model.lineCount == 1 && model.cursor == 30, "next current page is visible without replaying cleared lines")
}

@MainActor func runDemoGatewayLogsClearOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("logs Clear Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "logs Clear connects to genuine isolated Demo")
    guard connected else { return }
    let gate = LogClearDeliveryGate(); defer { gate.release() }
    var requests = 0
    var computedCursor: Int?
    let model = GatewayLogsModel { method, params in
        let response = try await gateway.connection.request(method, params)
        requests += 1
        if requests == 2 {
            let hasLines = response["lines"]?.array?.isEmpty == false
            check(hasLines, "genuine Demo chat activity produced the held log page")
            computedCursor = response["cursor"]?.int
            await gate.hold()
        }
        return response
    }
    await model.poll()
    check(model.lineCount > 0 && model.cursor != nil, "actual seeded Demo logs are initially visible")
    // Existing chat.send causes genuine Demo gateway/agent log activity; no log-append RPC or fabricated page.
    let chat = gateway.chat(for: "agent:main:main")
    let first = await chat.sendMessage("hello", attachments: [])
    if case .sent = first { check(true, "actual Demo chat activity is accepted") }
    else { check(false, "actual Demo chat activity is accepted"); return }
    let old = Task { await model.poll() }; defer { old.cancel(); gate.release() }
    let entered = await waitFor("real computed Demo log page") { gate.entered }
    check(entered, "real Demo log response is computed before Clear")
    guard entered else { return }
    model.clear(); gate.release(); await old.value
    check(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0
          && model.cursor == computedCursor && !model.showsRecentOnly,
          "actual old Demo poll cannot repopulate Clear, and its cursor is retained")
    let settled = await waitFor("first Demo log-producing run completes", timeout: 20) { !chat.isRunning }
    check(settled, "first real Demo chat run completes before the next activity")
    guard settled else { return }
    let second = await chat.sendMessage("hello again", attachments: [])
    if case .sent = second { check(true, "later genuine Demo activity is accepted") }
    else { check(false, "later genuine Demo activity is accepted"); return }
    await model.poll()
    check(model.lineCount > 0 && model.cursor != computedCursor && model.failure == nil,
          "new genuine Demo log activity remains visible after Clear")
}
