import Foundation
import PincerKit

// Subagent tree and run timeline (#35).

/// The demo's "Research: launch plan" helpers (DemoGateway+Subagents.swift).
let demoSubagentParent = "agent:research:dashboard:launch-plan"
let demoSubagentKeys = (done: "agent:research:subagent:4a7c2e10-9b3d-4f5e-8a61-1c2d3e4f5a01",
                        grandchild: "agent:research:subagent:7d1e5b20-3c4a-4b6d-9e72-2d3e4f5a6b02",
                        aborted: "agent:research:subagent:2f8a6c30-5d4b-4c7e-a083-3e4f5a6b7c03",
                        running: "agent:main:subagent:8b3d7f40-6e5c-4d8f-b194-4f5a6b7c8d04",
                        failed: "agent:research:subagent:5c9e1a50-7f6d-4e9a-c2a5-5a6b7c8d9e05")
/// The mock's "Release prep" helpers (mock-gateway/subagents.mjs).
let seededSubagentParent = "agent:coder:dashboard:release"
let seededSubagentKeys = (done: "agent:coder:subagent:5b0f2c1e-8d4a-4f6e-9a51-2c7d3e1f0a01",
                          failed: "agent:coder:subagent:9e3d7a60-1b2c-4d8e-b7f4-6a5c4d3b2e02",
                          running: "agent:research:subagent:c41a8f93-7e6d-4a2b-8c1f-0d9e8b7a6f03",
                          killed: "agent:research:subagent:e2b19d74-3f5a-4c6b-9d8e-7f1a2b3c4d04")

@MainActor
func checkSubagents() {
    print("Subagent tree & run timeline")
    let now = Date(timeIntervalSince1970: 2_000_000)
    let ms = { (date: Date) in JSONValue.number(date.timeIntervalSince1970 * 1000) }
    func row(_ key: String, _ fields: [String: JSONValue]) -> SessionRow {
        var object = fields
        object["key"] = .string(key)
        return SessionRow(.object(object))!
    }
    let rows = [
        row("agent:main:main", [:]),
        row("agent:main:subagent:b", ["spawnedBy": "agent:main:main", "status": "running", "startedAt": ms(now - 30)]),
        row("agent:main:subagent:a", ["spawnedBy": "agent:main:main", "status": "failed", "lastRunError": "boom",
                                      "startedAt": ms(now - 90), "endedAt": ms(now - 60)]),
        row("agent:main:subagent:c", ["parentSessionKey": "agent:main:subagent:b", "status": "killed", "abortedLastRun": true]),
        row("agent:main:subagent:orphan", ["spawnedBy": "agent:main:gone", "status": "done"]),
        row("agent:main:subagent:x", ["spawnedBy": "agent:main:subagent:y"]),
        row("agent:main:subagent:y", ["spawnedBy": "agent:main:subagent:x"]),
    ]
    let tree = SubagentTree.build(rows: rows, rootKey: "agent:main:main", now: now)
    check(tree.children.map(\.key) == ["agent:main:subagent:a", "agent:main:subagent:b"], "children sort oldest first")
    check(tree.node("agent:main:subagent:c")?.depth == 2 && tree.node("agent:main:subagent:c")?.status == .aborted,
          "nested killed helper reads aborted")
    check(tree.node("agent:main:subagent:a")?.status == .error && tree.node("agent:main:subagent:a")?.lastError == "boom",
          "failed helper keeps its error")
    check(tree.node("agent:main:subagent:b")?.duration(now: now) == 30 && tree.runningCount == 1, "running duration uses now")
    check(tree.count == 3 && tree.node("agent:main:subagent:orphan") == nil && tree.node("agent:main:subagent:x") == nil,
          "orphans and cycles stay out")
    let offline = SubagentTree.build(rows: rows, rootKey: "agent:main:main", now: now, connected: false)
    check(offline.node("agent:main:subagent:b")?.status == .unknown, "disconnected running → unknown")

    var timeline = RunTimeline()
    var seq = 0
    func agent(_ stream: String, _ data: [String: JSONValue], _ at: TimeInterval) {
        seq += 1
        timeline.apply(agent: ["runId": "r", "seq": JSONValue(seq), "stream": .string(stream), "ts": ms(now + at),
                               "sessionKey": "agent:main:main", "data": .object(data)], receivedAt: now)
    }
    agent("lifecycle", ["phase": "start"], 0)
    agent("thinking", ["text": "hm"], 1)
    agent("tool", ["phase": "start", "name": "exec", "toolCallId": "t1"], 2)
    agent("tool", ["phase": "result", "name": "exec", "toolCallId": "t1", "isError": true, "result": "exit 1"], 4)
    agent("lifecycle", ["phase": "end", "aborted": true, "status": "cancelled", "stopReason": "user"], 5)
    timeline.apply(chat: ["runId": "r", "sessionKey": "agent:main:main", "state": "aborted"], receivedAt: now)
    let lane = timeline.latestLane(sessionKey: "agent:main:main")
    check(lane?.status == .aborted && lane?.segments.map(\.kind) == [.thinking, .tool(name: "exec"), .abort],
          "thinking, tool, abort lane (\(lane?.segments.map(\.kind) ?? []))")
    check(lane?.errorCount == 1 && lane?.duration(now: .distantFuture) == 5, "tool error counted, 5s run")
    check(RunDuration.format(65) == "1:05" && RunDuration.format(0.2) == "<1s", "duration format")
}

@MainActor
func runDemoSubagents(_ gateway: GatewayStore) async {
    print("Subagents (demo)")
    let root = demoSubagentParent
    let kids = demoSubagentKeys
    let seeded = await waitFor("demo subagent tree") { gateway.subagentTree(rootKey: root).count == 5 }
    let tree = gateway.subagentTree(rootKey: root)
    check(seeded && gateway.sessions[root]?.title == "Research: launch plan"
          && tree.children.map(\.key) == [kids.done, kids.failed, kids.running],
          "demo launch plan has three helpers, oldest first (\(tree.flattened.map(\.key)))")
    check(tree.node(kids.done)?.status == .done && tree.node(kids.grandchild)?.status == .done
          && tree.node(kids.aborted)?.status == .aborted && tree.node(kids.failed)?.status == .error
          && tree.node(kids.running)?.status == .running,
          "demo shows all four statuses (\(tree.flattened.map(\.status.label)))")
    check(tree.node(kids.grandchild)?.depth == 2 && Set(tree.node(kids.done)?.children.map(\.key) ?? []) == [kids.grandchild, kids.aborted],
          "demo done helper has nested helpers")
    check(tree.node(kids.failed)?.lastError?.contains("503") == true, "demo failed helper shows its tool error")
    check(tree.node(kids.running).flatMap { $0.duration(now: Date()) }.map { $0 > 60 } == true, "demo running helper has a duration")
    check(gateway.hasRuns(sessionKey: root) && gateway.parentSessionKey(of: kids.grandchild) == kids.done,
          "demo runs panel and parent breadcrumb")
    let idleSeededChat = "agent:research:main"
    check(gateway.hasRuns(sessionKey: "agent:main:main"),
          "the earlier demo-core sends give Main captured run activity")
    check(gateway.sessions[idleSeededChat] != nil
          && gateway.subagentTree(rootKey: idleSeededChat).count == 0
          && gateway.runTimeline.latestLane(sessionKey: idleSeededChat) == nil,
          "the seeded Research Main chat has no helpers or captured run activity")
    check(!gateway.hasRuns(sessionKey: idleSeededChat),
          "demo omits Runs from a seeded chat without helpers or captured activity")
    check(gateway.runTitle(kids.running) == "Draft launch timeline", "demo helper title (\(gateway.runTitle(kids.running)))")

    let lanes = await waitFor("demo lanes") { gateway.runTimeline.latestLane(sessionKey: kids.running) != nil }
    let timeline = gateway.runTimeline
    let parentLane = timeline.latestLane(sessionKey: root)
    check(lanes && parentLane?.status == .done && (parentLane?.toolCount ?? 0) >= 6
          && parentLane?.segments.filter { $0.kind == .tool(name: "sessions_spawn") }.count == 3
          && parentLane?.segments.contains { $0.kind == .thinking } == true,
          "demo parent lane: thinking, tools and three spawns (\(parentLane?.segments.map(\.kind) ?? []))")
    check(timeline.latestLane(sessionKey: kids.failed)?.status == .error
          && (timeline.latestLane(sessionKey: kids.failed)?.errorCount ?? 0) >= 2, "demo failed lane has a tool error and an error marker")
    check(timeline.latestLane(sessionKey: kids.aborted)?.status == .aborted
          && timeline.latestLane(sessionKey: kids.grandchild)?.status == .done, "demo nested lanes")
    let toolsBefore = timeline.latestLane(sessionKey: kids.running)?.toolCount ?? 0
    let streaming = await waitFor("demo helper streams", timeout: 10) {
        (gateway.runTimeline.latestLane(sessionKey: kids.running)?.toolCount ?? 0) > toolsBefore
    }
    let runningLane = gateway.runTimeline.latestLane(sessionKey: kids.running)
    check(streaming && runningLane?.isRunning == true && runningLane?.currentActivity?.hasPrefix("Running `") == true,
          "demo running helper streams tool calls (\(toolsBefore) → \(runningLane?.toolCount ?? 0), \(runningLane?.currentActivity ?? "nil"))")

    // Compact iPhone's Runs badge reads this aggregate count; the visible demo keeps one helper active.
    let activeTree = gateway.subagentTree(rootKey: root)
    let activeChildren = activeTree.flattened.filter { $0.status == .running }.count
    check(activeTree.runningCount == activeChildren && activeChildren == 1,
          "demo Runs activity count matches its active helper (\(activeTree.runningCount), \(activeChildren))")

    let chat = gateway.chat(for: kids.running)
    await chat.load()
    check(!chat.items.isEmpty, "demo helper chat opens with a transcript")
    await chat.abort()
    let stopped = await waitFor("demo helper aborted") {
        gateway.subagentTree(rootKey: root).node(kids.running)?.status == .aborted
            && gateway.runTimeline.latestLane(sessionKey: kids.running)?.status == .aborted
    }
    check(stopped, "demo abort stops the running helper (\(String(describing: gateway.subagentTree(rootKey: root).node(kids.running)?.status)), lane \(String(describing: gateway.runTimeline.latestLane(sessionKey: kids.running)?.status)))")
    let abortMarkers = gateway.runTimeline.latestLane(sessionKey: kids.running)?.segments.filter { $0.kind == .abort }.count
    check(abortMarkers == 1, "demo abort leaves one abort marker (\(abortMarkers ?? 0))")
    let toolsAtStop = gateway.runTimeline.latestLane(sessionKey: kids.running)?.toolCount
    // Negative window: a stopped helper must not keep streaming.
    try? await Task.sleep(for: .seconds(3))
    check(gateway.runTimeline.latestLane(sessionKey: kids.running)?.toolCount == toolsAtStop, "demo helper stops streaming once stopped")
    let stoppedTree = gateway.subagentTree(rootKey: root)
    check(stoppedTree.runningCount == stoppedTree.flattened.filter { $0.status == .running }.count
          && stoppedTree.runningCount == 0, "demo Runs activity count clears when the helper stops")
}

@MainActor
func runLiveSubagents(gateway: GatewayStore) async {
    print("Subagents (live)")
    let root = seededSubagentParent
    let kids = seededSubagentKeys
    let seededKeys: Set = [kids.done, kids.failed, kids.running]
    let ready = await waitFor("live subagent tree") { gateway.subagentTree(rootKey: root).count >= 4 }
    let tree = gateway.subagentTree(rootKey: root)
    check(ready && seededKeys.isSubset(of: Set(tree.children.map(\.key))),
          "live release chat lists the seeded helpers (\(tree.children.map(\.key)))")
    let statuses = Dictionary(uniqueKeysWithValues: tree.flattened.map { ($0.key, $0.status) })
    check(statuses.values.contains(.done) && statuses.values.contains(.error) && statuses.values.contains(.running)
          && statuses.values.contains(.aborted), "live seeded statuses (\(statuses.values.map(\.label).sorted()))")
    check(tree.flattened.contains { $0.depth == 2 }, "live nested helper")

    let chat = gateway.chat(for: root)
    await chat.load()
    let before = Set(gateway.subagentTree(rootKey: root).flattened.map(\.key))
    _ = await chat.send("spawn a helper for the changelog")
    let spawned = await waitFor("live spawn done", timeout: 20) {
        gateway.subagentTree(rootKey: root).children.contains { !before.contains($0.key) && $0.status == .done }
    }
    let child = gateway.subagentTree(rootKey: root).children.first { !before.contains($0.key) }
    check(spawned, "live spawn adds a finished helper (\(String(describing: child?.status)))")
    if let child {
        let lane = await waitFor("live child lane") { gateway.runTimeline.latestLane(sessionKey: child.key)?.status == .done }
        let childLane = gateway.runTimeline.latestLane(sessionKey: child.key)
        check(lane && (childLane?.toolCount ?? 0) >= 1 && childLane?.segments.contains { $0.kind == .thinking } == true,
              "live child lane has thinking and a tool (\(childLane?.segments.map(\.kind) ?? []))")
        check(child.duration(now: Date()).map { $0 >= 0 } == true, "live child duration")
    }
    check(gateway.runTimeline.latestLane(sessionKey: root)?.segments.contains { $0.kind == .tool(name: "sessions_spawn") } == true,
          "live parent lane shows sessions_spawn")

    let beforeFail = Set(gateway.subagentTree(rootKey: root).flattened.map(\.key))
    _ = await chat.send("spawn fail please")
    let failed = await waitFor("live spawn fail", timeout: 20) {
        gateway.subagentTree(rootKey: root).children.contains { !beforeFail.contains($0.key) && $0.status == .error }
    }
    check(failed, "live failing spawn reads error")
    if let key = gateway.subagentTree(rootKey: root).children.first(where: { !beforeFail.contains($0.key) })?.key {
        check(gateway.runTimeline.latestLane(sessionKey: key)?.status == .error, "live failed child lane errors")
    }

    guard let running = gateway.subagentTree(rootKey: root).flattened.first(where: { $0.status == .running }) else {
        check(false, "live running helper to abort")
        return
    }
    let helper = gateway.chat(for: running.key)
    await helper.load()
    await helper.abort()
    let aborted = await waitFor("live helper abort") { gateway.subagentTree(rootKey: root).node(running.key)?.status == .aborted }
    check(aborted, "live abort stops the running helper (\(String(describing: gateway.subagentTree(rootKey: root).node(running.key)?.status)))")
    check(gateway.sessions[root]?.raw["hasActiveSubagentRun"]?.bool != true, "live parent no longer has an active helper")
}
