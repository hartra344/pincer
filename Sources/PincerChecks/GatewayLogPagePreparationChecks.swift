#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkLogPageWork(_ model: GatewayLogsModel) async {
    let probe = GatewayLogPreparationProbe(); model.pagePreparationProbe = probe
    defer { model.pagePreparationProbe = nil }
    await model.poll()
    let counts = probe.snapshot()
    check(model.hasLoaded && model.failure == nil && model.lineCount > 0 && model.cursor != nil,
          "actual logs.tail poll completes and publishes source lines/cursor")
    check(counts.mainParses == 0 && counts.mainRows == 0,
          "actual legal log page parsing and row preparation are off Main")
    check(counts.mainParses + counts.offMainParses > 0 && counts.mainRows + counts.offMainRows > 0,
          "bounded per-model counter sees real parse and row normalization work")
    check(model.bufferedBytes <= model.byteCapacity && model.entries.count <= model.capacity,
          "actual prepared log page preserves existing count/byte buffer budgets")
    let cursor = model.cursor
    model.clear()
    check(model.entries.isEmpty && model.bufferedBytes == 0 && model.cursor == cursor,
          "Clear removes visible prepared rows while preserving the transport cursor")
}

@MainActor func runGatewayLogPagePreparationChecks() async {
    let lines = await Task.detached { (0..<32).map { "{\"level\":\"info\",\"subsystem\":\"gateway\",\"message\":\"ordinary line \($0)\"}" } }.value
    let model = GatewayLogsModel(methods: { ["logs.tail"] }) { method, params in
        check(method == "logs.tail" && params["limit"]?.int == 500 && params["maxBytes"]?.int == 250000,
              "actual log poll uses the verified existing method and page bounds")
        return ["file": "/fixture/gateway.log", "cursor": 5000, "size": 5000, "lines": .array(lines.map(JSONValue.string))]
    }
    await checkLogPageWork(model)
    let bounded = GatewayLogsModel { _, _ in
        ["cursor": 30, "lines": .array((0..<20).map { .string("line \($0)") })]
    }
    bounded.capacity = 4; bounded.byteCapacity = 15
    await bounded.poll()
    check(bounded.entries.map(\.message) == ["line 18", "line 19"] && bounded.bufferedBytes == 14,
          "worker-prepared page retains exact newest lines under both buffer bounds")
    check(bounded.entries.map(\.id) == [3, 4] && bounded.lineCount == 2,
          "arrival IDs and metadata counts remain exact after prepared-row eviction")
}

@MainActor func runDemoGatewayLogPagePreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("log page Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "connect to genuine Demo before log page preparation")
    guard connected else { return }
    let model = GatewayLogsModel(methods: { Set(gateway.hello?.methods ?? []) }) { method, params in
        try await gateway.connection.request(method, params, timeout: 10)
    }
    await checkLogPageWork(model) // Unchanged real Demo log data; no overlay, writes or new fields.
}
#endif
