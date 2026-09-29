import Foundation
import Testing
@testable import PincerKit

/// Issue #228: PincerKit's sentences go through `PincerStrings`; with no bundle registered (as in
/// tests) they read as English, and Gateway failures are classified in one place.
@Suite("PincerKit localization")
struct PincerKitLocalizationTests {
    private func rpc(_ code: String, _ message: String, details: JSONValue? = nil) -> GatewayError {
        .rpc(code: code, message: message, details: details)
    }

    @Test("MISSING_SCOPE details name the scope")
    func missingScopeDetails() {
        let error = self.rpc("FORBIDDEN", "forbidden", details: .object([
            "code": .string("MISSING_SCOPE"), "missingScope": .string("operator.read"),
        ]))
        #expect(GatewayError.classify(error) == .missingScope(scope: "operator.read"))
        #expect(GatewayError.message(for: error) == "Your device doesn't have the `operator.read` scope. Approve it again from the Gateway with that scope.")
    }

    @Test("MISSING_SCOPE without a scope name")
    func missingScopeNoName() {
        let error = self.rpc("MISSING_SCOPE", "nope")
        #expect(GatewayError.classify(error) == .missingScope(scope: nil))
        #expect(GatewayError.message(for: error) == "Your device is missing a scope this needs. Approve it again from the Gateway with that scope.")
    }

    @Test("Legacy message names the scope")
    func legacyMissingScope() {
        let error = self.rpc("INVALID_REQUEST", "missing scope: operator.read")
        #expect(GatewayError.classify(error) == .missingScope(scope: "operator.read"))
    }

    @Test("A page's own scope sentence wins")
    func pageScopeSentence() {
        let error = self.rpc("MISSING_SCOPE", "x")
        #expect(GatewayError.message(for: error, scope: "Custom") == "Custom")
    }

    @Test("Unknown method")
    func unknownMethod() {
        #expect(GatewayError.classify(self.rpc("UNKNOWN_METHOD", "x")) == .unsupported)
        #expect(GatewayError.classify(self.rpc("INVALID_REQUEST", "Unknown method: devices.list")) == .unsupported)
        #expect(GatewayError.message(for: self.rpc("UNKNOWN_METHOD", "x"), unavailable: "device management")
            == "This Gateway doesn't support device management yet.")
    }

    @Test("Plain RPC and non-RPC errors")
    func plainErrors() {
        #expect(GatewayError.classify(self.rpc("INTERNAL", "boom")) == .message("boom"))
        #expect(GatewayError.message(for: self.rpc("INTERNAL", "boom"), unavailable: "pairing requests") == "boom")
        struct Oops: LocalizedError { var errorDescription: String? { "oops" } }
        #expect(GatewayError.classify(Oops()) == .message("oops"))
        #expect(GatewayError.message(for: Oops()) == "oops")
    }

    @Test("Without a registered bundle, phrases are English")
    func englishFallback() {
        #expect(PincerStrings.bundle == nil)
        #expect(AccessibilityText.findStatus(current: 2, total: 5) == "Result 2 of 5")
        #expect(AccessibilityText.findStatus(current: nil, total: 1) == "1 result")
        #expect(AccessibilityText.findStatus(current: nil, total: 0) == "No results")
    }

    @Test("Sender names and markers")
    func senderStrings() {
        #expect(MessageSender.unknownAgentName == "Another agent")
        #expect(MessageSender.automationName == "Automation")
        #expect(MessageSender.helperName == "Helper")
        #expect(MessageSender(kind: .automation).displayName(agents: []) == "Automation")
        #expect(MessageSender(kind: .helper, label: "Nightly").displayName(agents: []) == "Nightly")
        #expect(MessageSender(kind: .automation).marker(agents: [], receivingAgentId: nil) == "from an automation")
        #expect(MessageSender(kind: .helper).marker(agents: [], receivingAgentId: nil) == "from a helper")
        #expect(MessageSender(kind: .agent).marker(agents: [], receivingAgentId: nil) == "from another agent")
        #expect(MessageSender(kind: .agent, agentId: "kiko").marker(agents: [], receivingAgentId: "main") == "from Kiko’s chat")
        #expect(MessageSender(kind: .agent, agentId: "main").marker(agents: [], receivingAgentId: "main") == "from another chat")
    }
}
