import Foundation
@testable import PincerKit

@MainActor
private final class MCPRefreshGate {
    var entered = 0
    var active = 0
    var maximumActive = 0
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    func hold() async throws -> Int {
        entered += 1
        let index = entered
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released.contains(index) || Task.isCancelled { continuation.resume() }
                else { waiters[index] = continuation }
            }
        } onCancel: { Task { @MainActor in self.release(index) } }
        try Task.checkCancellation()
        return index
    }
    func release(_ index: Int) { released.insert(index); waiters.removeValue(forKey: index)?.resume() }
    func releaseAll() { for index in 1...max(2, entered) { release(index) } }
}

@MainActor
private func checkMCPRefreshRounds(settings: GatewaySettingsModel, scopes: @escaping @MainActor () -> [String],
                                   response: @escaping MCPServersModel.Request, label: String) async {
    let gate = MCPRefreshGate()
    var fresh: JSONValue?
    let model = MCPServersModel(settings: settings, methods: { [ToolsPolicy.effectiveMethod] }, scopes: scopes,
                               sessionKey: { "agent:main:main" }, request: { method, params in
        check(method == ToolsPolicy.effectiveMethod && params == ["sessionKey": "agent:main:main", "agentId": "main"],
              "\(label): actual session MCP refresh uses existing tools.effective params")
        let payload = try await response(method, params)
        let round = try await gate.hold()
        if round == 1 { throw GatewayError.closed("earlier MCP refresh fixture failure") }
        fresh = payload
        return payload
    })
    var completed: Set<Int> = []
    let first = Task { await model.load(); completed.insert(1) }
    defer { gate.releaseAll(); first.cancel() }
    let firstEntered = await waitFor("\(label) first MCP request", { gate.entered == 1 })
    check(firstEntered, "\(label): first actual MCP request reaches its held response")
    guard firstEntered else { return }
    var queued = false
    let second = Task { queued = true; await model.load(); completed.insert(2) }
    defer { second.cancel() }
    let callerQueued = await waitFor("\(label) queued MCP caller", { queued })
    check(callerQueued, "\(label): later caller enters the actual queued load path")
    guard callerQueued else { return }
    gate.release(1)
    let latestEntered = await waitFor("\(label) latest MCP request", { gate.entered == 2 })
    check(latestEntered, "\(label): queued refresh reaches its held response")
    guard latestEntered else { return }
    check(model.loadState.isRunning && completed.isEmpty, "\(label): latest held round stays running and both callers wait")
    gate.release(2)
    await first.value; await second.value
    check(gate.entered == 2 && gate.maximumActive == 1 && completed == [1, 2],
          "\(label): callers await two coalesced held responses")
    check(model.loadState == .idle, "\(label): successful latest round clears the older failure")
    let expected = fresh.map { MCPServersModel.statuses(from: EffectiveTools($0)) }
    check(model.statuses["filesystem"]?.state == .connected && model.statuses["filesystem"]?.tools.isEmpty == false,
          "\(label): the actual filesystem MCP tool source remains connected")
    check(expected?.isEmpty == false && model.statuses == expected,
          "\(label): latest exact effective-tool statuses publish")
}

@MainActor
func runMCPRefreshOutcomeChecks() async {
    let settings = GatewaySettingsModel(request: { _, _, _ in [:] }, scopes: { [] })
    await checkMCPRefreshRounds(settings: settings, scopes: { [] }, response: { _, _ in
        ["groups": [["id": "mcp", "source": "mcp", "tools": [
            ["id": "filesystem__lookup", "source": "mcp", "mcpServer": "filesystem", "mcpToolName": "lookup"]]]]]
    }, label: "offline")
}

@MainActor
func runDemoMCPRefreshOutcomeChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("MCP refresh Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped
    })
    check(connected, "MCP refresh checks connect to the genuine Demo Gateway")
    guard connected else { return }
    check(gateway.hello?.methods.contains(ToolsPolicy.effectiveMethod) == true,
          "Demo hello advertises the actual session effective-tools method")
    // Select the existing session-derived client path; no hello or server data is altered.
    // The first real response is held, then a simulated transport failure is delivered;
    // the queued response is another genuine Demo tools.effective result.
    await checkMCPRefreshRounds(settings: gateway.settings, scopes: { gateway.hello?.scopes ?? [] },
        response: { try await gateway.connection.request($0, $1) }, label: "Demo")
}
