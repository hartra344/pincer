#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkLogCopy(_ model: GatewayLogsModel) async {
    await model.poll()
    check(model.hasLoaded && model.failure == nil && model.lineCount > 0, "actual legal log page supplies Copy source")
    let entries = model.entries
    let expected = await Task.detached { (GatewayLogs.copyText(entries), GatewayLogs.rawText(entries)) }.value
    let helper = GatewayLogCopyPreparation(), probe = GatewayLogCopyProbe()
    helper.probe = probe
    let formatted = await helper.prepare(entries, style: .formatted)
    let raw = await helper.prepare(entries, style: .raw)
    let published: String = await withCheckedContinuation { continuation in
        helper.request(entries, style: .formatted) { continuation.resume(returning: $0) }
    }
    check(published == expected.0, "current Copy request publishes exact text without touching the clipboard")
    check(formatted == expected.0 && raw == expected.1, "actual Copy button preparation retains exact formatted/raw text and newlines")
    check(probe.snapshot().main == 0 && probe.snapshot().worker == 3, "actual Copy preparation stays off Main")
}

@MainActor func runGatewayLogCopyPreparationChecks() async {
    let lines = await Task.detached { (0..<32).map { "raw \($0):" + String(repeating: "é", count: 2000) } }.value
    let model = GatewayLogsModel(methods: { ["logs.tail"] }) { method, params in
        check(method == "logs.tail" && params["limit"]?.int == 500 && params["maxBytes"]?.int == 250000,
              "Copy source uses existing legal logs.tail bounds")
        return ["file": "/fixture/gateway.log", "cursor": 140000, "size": 140000, "lines": .array(lines.map(JSONValue.string))]
    }
    await checkLogCopy(model)
}

@MainActor func runDemoGatewayLogCopyPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("Copy source Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "actual Demo is ready for unchanged log Copy source")
    guard connected else { return }
    let model = GatewayLogsModel(methods: { Set(gateway.hello?.methods ?? []) }) { method, params in
        try await gateway.connection.request(method, params, timeout: 10)
    }
    await checkLogCopy(model)
}
#endif
