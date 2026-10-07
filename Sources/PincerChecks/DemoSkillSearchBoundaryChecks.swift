@testable import PincerKit

@MainActor func runDemoSkillSearchBoundaryChecks() async {
    let demo = DemoGateway()
    do {
        let ordinary = try await demo.handle("skills.search", [:])
        let whitespace = try await demo.handle("skills.search", ["query": " "])
        check(whitespace == ordinary && ordinary["results"]?.array?.isEmpty == false,
              "raw nonempty whitespace retains the actual default inventory")
        let one = try await demo.handle("skills.search", ["query": "nas", "limit": 1])
        check(one["results"]?.array?.count == 1 && one["results"]?[0]?["slug"]?.text == "nas-report",
              "inclusive minimum limit returns the actual matching skill")
        let hundred = try await demo.handle("skills.search", ["limit": 100])
        let count = hundred["results"]?.array?.count ?? 0
        check((1...100).contains(count), "inclusive maximum limit retains nonempty bounded results")
        for (params, expected) in [(JSONValue.object(["limit": "1"]), "at /limit: must be integer"),
                                   (JSONValue.object(["extra": true]), "must NOT have additional properties (extra)")] {
            do {
                _ = try await demo.handle("skills.search", params)
                check(false, "invalid boundary control must reject search")
            } catch let GatewayError.rpc(code, message, _) {
                check(code == "INVALID_REQUEST" && message == "invalid skills.search params: \(expected)",
                      "typed limit and unchanged extra-key controls keep distinct errors")
            }
        }
    } catch { check(false, "actual Demo boundary search controls complete") }
}
