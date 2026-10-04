#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Tools Inspector search preparation", .timeLimit(.minutes(2)))
struct ToolsInspectorSearchPreparationTests {
    @Test func legalSummariesMatchCompleteTailWithoutMainSearch() async {
        let payloads = await Task.detached {
            let tools: [JSONValue] = (0..<32).map { index in
                ["id": .string("fixture_\(index)"), "label": .string("Tool \(index)"),
                 "description": .string(String(repeating: "a", count: 90) + " tailneedle"),
                 "source": "plugin", "pluginId": "fixture", "optional": false,
                 "defaultProfiles": [], "tags": []]
            }
            let catalog: JSONValue = ["agentId": "main", "profiles": [["id": "full", "label": "Full"]],
                "groups": [["id": "plugin:fixture", "label": "Fixture", "source": "plugin", "pluginId": "fixture", "tools": .array(tools)]]]
            let effectiveTools: [JSONValue] = tools.prefix(16).map { tool in
                return ["id": tool["id"] ?? .null, "label": tool["label"] ?? .null,
                    "description": tool["description"] ?? .null, "rawDescription": tool["description"] ?? .null,
                    "source": "plugin", "pluginId": "fixture"]
            }
            let effective: JSONValue = ["agentId": "main", "profile": "full", "groups": [["id": "plugin", "label": "Connected tools", "source": "plugin", "tools": .array(effectiveTools)]], "notices": []]
            return (catalog, effective)
        }.value
        let model = ToolsInspectorModel(scope: .session(key: "agent:main:main", agentId: "main")) { method, _ in
            method == "tools.catalog" ? payloads.0 : payloads.1
        }
        await model.load()
        #expect(model.inspection?.totalCount == 32)
        let probe = ToolsInspectorSearchProbe(); model.searchProbe = probe
        let all = await model.prepareSearchFields(.all, matching: "TAILNEEDLE")
        #expect(all.map(\.id) == ["plugin:fixture"])
        #expect(all.flatMap(\.tools).map(\.id) == (0..<32).map { "fixture_\($0)" })
        let allowed = await model.prepareSearchFields(.allowed, matching: "tailneedle")
        let denied = await model.prepareSearchFields(.denied, matching: "tailneedle")
        let blank = await model.prepareSearchFields(.all, matching: " ")
        let unmatched = await model.prepareSearchFields(.all, matching: "no such tool")
        #expect(allowed.flatMap(\.tools).map(\.id) == (0..<16).map { "fixture_\($0)" })
        #expect(denied.flatMap(\.tools).map(\.id) == (16..<32).map { "fixture_\($0)" })
        #expect(blank.flatMap(\.tools).count == 32)
        #expect(unmatched.isEmpty)
        let counts = probe.snapshot()
        #expect(counts.mainFilters == 0 && counts.mainMatches == 0)
        #expect(counts.mainFilters + counts.workerFilters > 0 && counts.mainMatches + counts.workerMatches > 0)
    }
}
#endif
