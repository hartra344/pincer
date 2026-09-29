import Foundation
import Testing
@testable import PincerKit

struct GatewayErrorTests {
    private func rpc(_ code: String, _ message: String = "x", _ details: JSONValue? = nil) -> GatewayError {
        .rpc(code: code, message: message, details: details)
    }

    @Test func missingScope() {
        let cases: [GatewayError] = [
            self.rpc("MISSING_SCOPE"),
            self.rpc("FORBIDDEN", "x", ["code": "MISSING_SCOPE"]),
            self.rpc("INVALID_REQUEST", "x", ["code": "MISSING_SCOPE"]),
            self.rpc("FORBIDDEN", "missing scope: operator.admin"),
            self.rpc("FORBIDDEN", "missing operator.approvals"),
            self.rpc("INVALID_REQUEST", "missing scope: operator.read"),
        ]
        for error in cases {
            #expect(GatewayError.isMissingScope(error), "\(error)")
            #expect(!GatewayError.isForbidden(error) && !GatewayError.isUnknownMethod(error))
        }
        #expect(GatewayError.missingScope(self.rpc("FORBIDDEN", "x", ["missingScope": "operator.admin"])) == "operator.admin")
        #expect(GatewayError.missingScope(self.rpc("FORBIDDEN", "x", ["scope": "operator.read"])) == "operator.read")
    }

    @Test func bareForbiddenIsARoleRefusal() {
        let error = self.rpc("FORBIDDEN", "not allowed")
        #expect(!GatewayError.isMissingScope(error))
        #expect(GatewayError.isForbidden(error) && GatewayError.isUnavailable(error))
    }

    @Test func unknownMethod() {
        for error in [self.rpc("UNKNOWN_METHOD"), self.rpc("METHOD_NOT_FOUND"), self.rpc("INVALID_REQUEST", "Unknown method: cron.list")] {
            #expect(GatewayError.isUnknownMethod(error) && GatewayError.isUnavailable(error))
            #expect(!GatewayError.isMissingScope(error))
        }
    }

    @Test func genericAndNonRPCErrors() {
        let generic = self.rpc("UNAVAILABLE", "try later")
        #expect(!GatewayError.isMissingScope(generic) && !GatewayError.isUnknownMethod(generic) && !GatewayError.isUnavailable(generic))
        #expect(!GatewayError.isMissingScope(GatewayError.notConnected) && !GatewayError.isUnknownMethod(URLError(.timedOut)))
    }

    @Test func messagePicksTheCallersWording() {
        #expect(GatewayError.message(for: self.rpc("FORBIDDEN", "missing scope: operator.admin"), scope: "S", unavailable: "U") == "S")
        #expect(GatewayError.message(for: self.rpc("UNKNOWN_METHOD", "nope"), scope: "S", unavailable: "renaming devices") == "This Gateway doesn't support renaming devices yet.")
        #expect(GatewayError.message(for: self.rpc("UNKNOWN_METHOD", "nope"), scope: "S") == "nope")
        #expect(GatewayError.message(for: self.rpc("UNAVAILABLE", "try later"), scope: "S", unavailable: "U") == "try later")
        #expect(GatewayError.message(for: GatewayError.notConnected, scope: "S") == GatewayError.notConnected.localizedDescription)
    }

    @Test func defaultWording() {
        let named = self.rpc("FORBIDDEN", "x", ["code": "MISSING_SCOPE", "missingScope": "operator.read"])
        #expect(GatewayError.message(for: named) == "Your device doesn't have the `operator.read` scope. Approve it again from the Gateway with that scope.")
        let inMessage = self.rpc("FORBIDDEN", "missing scope: operator.admin")
        #expect(GatewayError.message(for: inMessage).contains("`operator.admin`"))
        #expect(GatewayError.message(for: self.rpc("MISSING_SCOPE")).hasPrefix("Your device is missing a scope"))
    }
}
