import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DemoSkillSearchBoundaryTests {
    @Test func rawWhitespaceAndInclusiveLimitsPreserveSearch() async throws {
        let demo = DemoGateway()
        let ordinary = try await demo.handle("skills.search", [:])
        let whitespace = try await demo.handle("skills.search", ["query": " "])
        #expect(whitespace == ordinary, "upstream NonEmptyString accepts raw whitespace; current matching is unchanged")
        let one = try await demo.handle("skills.search", ["query": "nas", "limit": 1])
        #expect(one["results"]?.array?.count == 1 && one["results"]?[0]?["slug"]?.text == "nas-report")
        let hundred = try await demo.handle("skills.search", ["limit": 100])
        let rows = try #require(hundred["results"]?.array)
        #expect(!rows.isEmpty && rows.count <= 100)
    }
    @Test func stringLimitAndExistingUnexpectedPropertyHaveDistinctErrors() async throws {
        let demo = DemoGateway()
        do {
            _ = try await demo.handle("skills.search", ["limit": "1"])
            Issue.record("A string limit must not be coerced to an integer")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST" && message == "invalid skills.search params: at /limit: must be integer")
        }
        do {
            _ = try await demo.handle("skills.search", ["extra": true])
            Issue.record("Unexpected property must retain rejection")
        } catch let GatewayError.rpc(code, message, _) {
            #expect(code == "INVALID_REQUEST" && message == "invalid skills.search params: must NOT have additional properties (extra)")
        }
    }
}
