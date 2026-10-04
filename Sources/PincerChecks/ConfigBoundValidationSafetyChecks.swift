import Foundation
@testable import PincerKit

@MainActor func runConfigBoundValidationSafetyChecks() async {
    let schema = await Task.detached {
        ConfigSchema(schema: ["type": "object", "properties": ["limit": ["type": "number", "minimum": .number(1e30)]]])
    }.value
    guard let field = schema.field(at: ["limit"]) else { check(false, "actual numeric schema field parses"); return }
    check(field.validate( .number(0)) == "Must be at least 1e+30.",
          "actual field validation formats finite out-of-Int64 bounds without trapping")
}

@MainActor func runDemoConfigBoundValidationSafetyChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("numeric bound Demo schema", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "genuine Demo config connection is ready")
    guard ready else { return }
    do {
        let response = try await gateway.connection.request("config.schema", [:])
        let schema = await Task.detached { ConfigSchema(response: response) }.value
        guard schema.root.object != nil, let ordinary = schema.field(at: ["agents", "defaults", "model", "primary"]) else {
            check(false, "actual Demo schema supplies its existing primary-model field"); return
        }
        check(ordinary.kind == .text && ordinary.validate(.string("anthropic/claude-opus-4-8")) == nil,
              "actual Demo primary-model schema retains its real text-field validation behavior")
        // Explicitly LOCAL valid JSON Schema constraint, interpreted by the same parsed
        // schema field API; no Gateway response overlay or configuration write.
        guard let local = schema.field(at: ["localBound"], node: ["type": "number", "maximum": .number(-1e30)]) else {
            check(false, "local numeric constraint field parses through actual schema"); return
        }
        check(local.validate( .number(0)) == "Must be at most -1e+30.",
              "genuine Demo schema field API safely validates the explicit LOCAL finite bound")
    } catch { check(false, "actual Demo config.schema read failed: \(error)") }
}

@MainActor func runConfigBoundFormattingBoundaryChecks() {
    let bound = Double(Int64.max).nextDown
    let schema = ConfigSchema(schema: ["type": "object", "properties": ["limit": ["type": "number", "minimum": .number(bound)]]])
    guard let field = schema.field(at: ["limit"]) else { check(false, "integer-boundary schema field parses"); return }
    check(field.validate(.number(0)) == "Must be at least \(Int64(bound))." && field.validate(.number(bound)) == nil,
          "largest representable in-range integer bound stays exact and inclusive")
}
