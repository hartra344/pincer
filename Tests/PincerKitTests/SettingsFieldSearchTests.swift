#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Settings field search work", .timeLimit(.minutes(2)))
struct SettingsFieldSearchTests {
    private func model(large: Bool = false) async -> GatewaySettingsModel {
        let response = await Task.detached {
            var properties: [String: JSONValue] = [:]
            for index in 0..<70 {
                let key = String(format: "field%02d", index)
                properties[key] = ["type": "string", "title": .string("Shared label " + key),
                    "description": .string(index == 0 && large ? String(repeating: "long help ", count: 210_000) + "needle" : "Shared help")]
            }
            return JSONValue.object(["schema": ["type": "object", "properties": .object(properties)]])
        }.value
        let model = GatewaySettingsModel(request: { method, _, _ in
            switch method {
            case "config.get": return ["config": [:], "hash": "search-fixture"]
            case "config.schema": return response
            case "plugins.list": return ["plugins": []]
            default: throw GatewayError.protocolViolation("unexpected fixture request")
            }
        }, scopes: { [] })
        await model.load()
        return model
    }
    @Test func coldSearchTraversesAndNormalizesOffMain() async {
        let model = await model(large: true)
        let probe = SettingsFieldSearchProbe()
        model.fieldSearchProbe = probe
        let token = UUID()
        await model.prepareFieldSearch(matching: "needle", token: token)
        await model.waitForFieldSearchPreparation()
        let found = model.fieldSearchResults(token: token, source: model.fieldSearchSourceRevision)
        #expect(found.map(\.key) == ["field00"], "Full remote help must remain searchable without truncation")
        let counts = probe.snapshot()
        #expect(counts.mainTraversals == 0 && counts.mainNormalizations == 0,
                "Actual cold field traversal and joined-haystack normalization stay off Main")
        #expect(counts.mainTraversals + counts.offMainTraversals > 0
                && counts.mainNormalizations + counts.offMainNormalizations > 0,
                "Probe observes real traversal and normalization, not a fabricated zero")
    }
    @Test func matchingOrderAndLimitPreserveExistingSemantics() async {
        let model = await model()
        func search(_ query: String) async -> [ConfigField] {
            let token = UUID()
            await model.prepareFieldSearch(matching: query, token: token)
            await model.waitForFieldSearchPreparation()
            return model.fieldSearchResults(token: token, source: model.fieldSearchSourceRevision)
        }
        #expect(await search("SHARED label").map(\.key) == (0..<60).map { String(format: "field%02d", $0) })
        #expect(await search("help field69").map(\.key) == ["field69"])
        #expect(await search("no matching text").isEmpty)
        #expect(await search("   ").count == 60)
    }
}
#endif
