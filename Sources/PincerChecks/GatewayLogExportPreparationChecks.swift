#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkPreparedLogExport(_ entries: [GatewayLogEntry], gatewayName: String) async {
    let expected = await Task.detached {
        Data(entries.filter { !$0.isMarker }.map(\.raw).joined(separator: "\n").utf8)
    }.value
    let preparation = GatewayLogExportPreparation()
    let probe = GatewayLogExportProbe(); preparation.probe = probe
    let output = await preparation.prepare(entries, gatewayName: gatewayName,
        date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
    check(output.data == expected, "actual confirmed Export preparation preserves exact raw bytes/newlines and excludes markers")
    check(output.name == "openclaw-fixture-gateway-19700101-000000.log", "actual prepared export filename is deterministic")
    let counts = probe.snapshot()
    check(counts.mainJoins == 0 && counts.mainEncodes == 0, "actual log Export join and UTF8 encoding run off Main")
    check(counts.workerJoins == 1 && counts.workerEncodes == 1,
          "per-instance bounded probe observes both actual Export preparation boundaries")
    var published: GatewayLogExport?
    preparation.request(entries, gatewayName: gatewayName) { published = $0 }
    await preparation.waitForIdle()
    check(published?.data == expected, "actual bounded UI admission publishes the finished current export")
    published = nil
    preparation.request(entries, gatewayName: gatewayName) { published = $0 }
    preparation.cancel() // Synchronous invalidation precedes the queued worker's publication.
    await preparation.waitForIdle()
    check(published == nil, "canceled UI export cannot publish its prepared document")
}

@MainActor func runGatewayLogExportPreparationChecks() async {
    let lines = await Task.detached { (0..<32).map { "raw line \($0): " + String(repeating: "é", count: 2000) } }.value
    let model = GatewayLogsModel(methods: { ["logs.tail"] }) { method, params in
        check(method == "logs.tail" && params["limit"]?.int == 500 && params["maxBytes"]?.int == 250000,
              "actual source poll retains verified logs.tail page bounds")
        return ["file": "/fixture/gateway.log", "cursor": 140000, "size": 140000, "lines": .array(lines.map(JSONValue.string))]
    }
    await model.poll()
    check(model.hasLoaded && model.lineCount == 32 && model.bufferedBytes < model.byteCapacity,
          "lawful actual model page supplies retained Export source")
    await checkPreparedLogExport(model.entries + [GatewayLogEntry(id: 1000, marker: "not exported")], gatewayName: "Fixture Gateway")
}

@MainActor func runDemoGatewayLogExportPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("log Export Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "genuine Demo connection is ready for actual logs.tail Export source")
    guard connected else { return }
    let model = GatewayLogsModel(methods: { Set(gateway.hello?.methods ?? []) }) { method, params in
        try await gateway.connection.request(method, params, timeout: 10)
    }
    await model.poll()
    check(model.hasLoaded && model.failure == nil && model.lineCount > 0, "unchanged genuine Demo log page supplies Export entries")
    await checkPreparedLogExport(model.entries, gatewayName: "Fixture Gateway")
}
#endif
