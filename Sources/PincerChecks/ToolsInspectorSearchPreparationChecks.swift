#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkActualToolsSearch(_ model: ToolsInspectorModel, query: String, expectedID: String) async {
    let probe = ToolsInspectorSearchProbe(); model.searchProbe = probe
    defer { model.searchProbe = nil }
    let result = await model.prepareSearchFields(.all, matching: query)
    check(result.flatMap(\.tools).contains { $0.id == expectedID }, "actual complete tool text matches the requested query")
    let all = await model.prepareSearchFields(.all, matching: "")
    let allowed = await model.prepareSearchFields(.allowed, matching: "")
    let denied = await model.prepareSearchFields(.denied, matching: "")
    check(all.flatMap(\.tools).count == allowed.flatMap(\.tools).count + denied.flatMap(\.tools).count,
          "actual allowed/denied filters partition the loaded inventory without dropping tools")
    let counts = probe.snapshot()
    check(counts.mainFilters == 0 && counts.mainMatches == 0, "actual editable Tools Inspector search does no Main filtering/text matching")
    check(counts.workerFilters > 0 && counts.workerMatches > 0,
          "bounded per-model observation records actual filter and match work")
    let owner = UUID()
    let displayed = await model.prepareDisplaySearch(.all, matching: query, owner: owner)
    check(displayed?.groups.flatMap(\.tools).contains { $0.id == expectedID } == true
          && model.searchPreparation.owns(owner, sourceRevision: model.searchSourceRevision),
          "actual displayed query owner matches its completed source revision")
    model.searchPreparation.invalidate()
    check(!model.searchPreparation.owns(owner, sourceRevision: model.searchSourceRevision),
          "section disappearance invalidates finished search publication")
}

@MainActor func runToolsInspectorSearchPreparationChecks() async {
    let payload: JSONValue = await Task.detached { () -> JSONValue in
        ["agentId": "main", "profiles": [["id": "full", "label": "Full"]],
         "groups": [["id": "plugin:fixture", "label": "Fixture", "source": "plugin", "pluginId": "fixture",
                     "tools": [["id": "fixture_tool", "label": "Fixture tool", "description": .string(String(repeating: "a", count: 90) + " tailneedle"),
                                "source": "plugin", "pluginId": "fixture", "optional": false, "tags": [], "defaultProfiles": []]]]]]
    }.value
    let model = ToolsInspectorModel(scope: .agent("main", sessionKey: nil), methods: { ["tools.catalog"] }) { method, params in
        check(method == "tools.catalog" && params == ["agentId": "main"], "actual catalog request preserves existing verified params")
        return payload
    }
    await model.load()
    await checkActualToolsSearch(model, query: "TAILNEEDLE", expectedID: "fixture_tool")
    let unmatched = await model.prepareSearchFields(.all, matching: "no such tool")
    check(unmatched.isEmpty, "actual unmatched query produces no tools")
}

@MainActor func runDemoToolsInspectorSearchPreparationChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("Tools search Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "genuine Demo connects before actual tool inventory search")
    guard connected else { return }
    let model = gateway.toolsInspector(sessionKey: "agent:main:main")
    await model.load()
    guard let tool = model.inspection?.allTools.first else { check(false, "actual Demo inventory includes tools"); return }
    await checkActualToolsSearch(model, query: tool.label, expectedID: tool.id)
}
#endif
