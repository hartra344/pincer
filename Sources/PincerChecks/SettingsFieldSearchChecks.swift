#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkActualFieldSearch(_ model: GatewaySettingsModel, query: String) async {
    let probe = SettingsFieldSearchProbe()
    model.fieldSearchProbe = probe
    defer { model.fieldSearchProbe = nil }
    let token = UUID()
    await model.prepareFieldSearch(matching: query, token: token)
    await model.waitForFieldSearchPreparation()
    let found = model.fieldSearchResults(token: token, source: model.fieldSearchSourceRevision)
    check(!found.isEmpty && found.count <= 60, "actual field search publishes matching fields within the existing result limit")
    let counts = probe.snapshot()
    check(counts.mainTraversals == 0 && counts.mainNormalizations == 0 && counts.mainMatches == 0,
          "actual field index traversal and normalization run off Main")
    check(counts.mainTraversals + counts.offMainTraversals > 0
          && counts.mainNormalizations + counts.offMainNormalizations > 0,
          "bounded counter observes actual field search work")
}

@MainActor func runSettingsFieldSearchChecks() async {
    let model = GatewaySettingsModel(request: { method, _, _ in
        switch method {
        case "config.get": return ["config": ["example": "value"], "hash": "search-check"]
        case "config.schema": return ["schema": ["type": "object", "properties": ["example":
            ["type": "string", "title": "Example label", "description": "Distinct help"]]]]
        case "plugins.list": return ["plugins": []]
        default: throw GatewayError.protocolViolation("unexpected fixture request")
        }
    }, scopes: { [] })
    await model.load()
    await checkActualFieldSearch(model, query: "distinct example")
    let source = model.fieldSearchSourceRevision
    let token = UUID()
    await model.prepareFieldSearch(matching: "EXAMPLE label", token: token)
    check(model.fieldSearchResults(token: token, source: source).map(\.key) == ["example"],
          "actual normalized cache preserves label/path multi-term matching")
    check(model.fieldSearchBudget.cachedCount <= SettingsFieldSearchPreparation.cacheFieldLimit
          && model.fieldSearchBudget.cachedBytes <= SettingsFieldSearchPreparation.cacheByteLimit,
          "actual field index cache obeys its count and logical-byte budgets")
    check(!model.ownsFieldSearch(token: UUID(), source: source), "stale query identity cannot navigate prepared fields")
}

@MainActor func runDemoSettingsFieldSearchChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("settings search Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "connect to genuine Demo for actual schema/config field search")
    guard connected else { return }
    let model = GatewaySettingsModel(request: { method, params, timeout in
        try await gateway.connection.request(method, params, timeout: timeout)
    }, scopes: { gateway.hello?.scopes ?? [] })
    await model.load()
    check(model.hasLoaded && model.schema != nil, "actual Demo loads config and schema before searching")
    await checkActualFieldSearch(model, query: "sentry")
}
#endif
