import Foundation

/// The demo's subagent runs (`sessions_spawn`) and their streamed activity: "Research: launch plan"
/// spawned three helpers: one done (with two helpers of its own, one done and one stopped), one
/// still running and streaming tool calls, and one failed on a tool error. Row and event shapes
/// follow upstream (and `mock-gateway/subagents.mjs`): `spawnedBy`/`parentSessionKey`,
/// `childSessions`, `spawnDepth`, `status` (`running | done | failed | killed`),
/// `startedAt`/`endedAt`/`runtimeMs`, and `agent` events `{runId, seq, stream, ts, sessionKey, spawnedBy?, data}`.
extension DemoGateway {
    static let subagentParentKey = "agent:research:dashboard:launch-plan"
    static let seededSubagents = (
        done: "agent:research:subagent:4a7c2e10-9b3d-4f5e-8a61-1c2d3e4f5a01",
        grandchild: "agent:research:subagent:7d1e5b20-3c4a-4b6d-9e72-2d3e4f5a6b02",
        aborted: "agent:research:subagent:2f8a6c30-5d4b-4c7e-a083-3e4f5a6b7c03",
        running: "agent:main:subagent:8b3d7f40-6e5c-4d8f-b194-4f5a6b7c8d04",
        failed: "agent:research:subagent:5c9e1a50-7f6d-4e9a-c2a5-5a6b7c8d9e05"
    )
    static let seededRunningSubagentRunId = "run_seed_launch_timeline"
    static let seededParentRunId = "run_seed_launch_plan"
    /// The seeded running helper's replayed events end at this `seq`; live steps continue from it.
    static let seededRunningLastSeq = 10
    /// How often the running helper streams its next tool call.
    static let liveSubagentStepInterval: Duration = .milliseconds(2500)

    private static let minuteMs = 60_000.0

    /// Adds the launch-plan chat and its helpers to the demo's sessions and transcripts.
    static func seedSubagents(sessions: inout [String: [String: JSONValue]], transcripts: inout [String: [JSONValue]],
                              now: Double = DemoGateway.now().double ?? 0)
    {
        let kids = Self.seededSubagents
        let minute = Self.minuteMs
        func at(_ minutesAgo: Double) -> JSONValue { .number((now - minutesAgo * minute).rounded()) }
        func row(_ key: String, agent: String, title: String, preview: String, minutesAgo: Double,
                 _ extra: [String: JSONValue] = [:]) -> [String: JSONValue]
        {
            var row: [String: JSONValue] = [
                "key": .string(key), "sessionId": .string(UUID().uuidString.lowercased()), "kind": "direct",
                "label": .string(title), "derivedTitle": .string(title), "lastMessagePreview": .string(preview),
                "channel": "webchat", "agentId": .string(agent), "isMain": false, "pinned": false, "unread": false,
                "archived": false, "updatedAt": at(minutesAgo), "lastActivityAt": at(minutesAgo), "status": "idle",
                "hasActiveRun": false, "activeRunIds": [], "model": "claude-sonnet-5", "modelProvider": "anthropic",
                "modelOverrideSource": nil,
            ]
            row.merge(extra) { _, new in new }
            return row
        }
        func child(_ key: String, agent: String, title: String, preview: String, minutesAgo: Double, parent: String,
                   depth: Int, _ extra: [String: JSONValue]) -> [String: JSONValue]
        {
            var fields: [String: JSONValue] = [
                "parentSessionKey": .string(parent), "spawnedBy": .string(parent), "createdVia": "spawn",
                "subagentRole": "leaf", "spawnDepth": JSONValue(depth), "subagentRunState": "historical",
            ]
            fields.merge(extra) { _, new in new }
            return row(key, agent: agent, title: title, preview: preview, minutesAgo: minutesAgo, fields)
        }

        sessions[Self.subagentParentKey] = row(
            Self.subagentParentKey, agent: "research", title: "Research: launch plan",
            preview: "Spawned three helpers for the launch plan.", minutesAgo: 29,
            ["category": "Work", "childSessions": JSONValue([kids.done, kids.running, kids.failed]),
             "hasActiveSubagentRun": true, "lastRunId": .string(Self.seededParentRunId),
             "startedAt": at(32), "endedAt": at(29), "runtimeMs": .number(3 * minute), "status": "done"])
        sessions[kids.done] = child(
            kids.done, agent: "research", title: "Competitor pricing scan", preview: "Five competitors compared.",
            minutesAgo: 21, parent: Self.subagentParentKey, depth: 1,
            ["status": "done", "startedAt": at(29.5), "endedAt": at(21), "runtimeMs": .number(8.5 * minute),
             "lastRunId": "run_seed_pricing", "subagentRole": "orchestrator", "subagentControlScope": "children",
             "childSessions": JSONValue([kids.grandchild, kids.aborted])])
        sessions[kids.grandchild] = child(
            kids.grandchild, agent: "research", title: "Summarize pricing pages", preview: "Tiers and prices in a table.",
            minutesAgo: 24, parent: kids.done, depth: 2,
            ["status": "done", "startedAt": at(28), "endedAt": at(24), "runtimeMs": .number(4 * minute),
             "lastRunId": "run_seed_pricing_pages"])
        sessions[kids.aborted] = child(
            kids.aborted, agent: "research", title: "Fetch archived pricing", preview: "Stopped.",
            minutesAgo: 25.5, parent: kids.done, depth: 2,
            ["status": "killed", "abortedLastRun": true, "startedAt": at(27.5), "endedAt": at(25.5),
             "runtimeMs": .number(2 * minute), "lastRunId": "run_seed_archive"])
        sessions[kids.running] = child(
            kids.running, agent: "main", title: "Draft launch timeline", preview: "Checking the release calendar…",
            minutesAgo: 1, parent: Self.subagentParentKey, depth: 1,
            ["status": "running", "startedAt": at(6), "hasActiveRun": true,
             "activeRunIds": [.string(Self.seededRunningSubagentRunId)], "lastRunId": .string(Self.seededRunningSubagentRunId),
             "subagentRunState": "active"])
        sessions[kids.failed] = child(
            kids.failed, agent: "research", title: "Check trademark availability", preview: "The trademark search failed.",
            minutesAgo: 26, parent: Self.subagentParentKey, depth: 1,
            ["status": "failed", "startedAt": at(29.4), "endedAt": at(26), "runtimeMs": .number(3.4 * minute),
             "lastRunId": "run_seed_trademark",
             "lastRunError": "web_fetch failed: 503 Service Unavailable from tmsearch.uspto.gov"])

        func message(_ role: String, _ content: [JSONValue], minutesAgo: Double, extra: [String: JSONValue] = [:]) -> JSONValue {
            var message: [String: JSONValue] = [
                "role": .string(role), "content": .array(content), "timestamp": at(minutesAgo),
                "__openclaw": ["id": .string(UUID().uuidString.lowercased())],
            ]
            if role == "assistant" {
                message["provider"] = "anthropic"
                message["model"] = "claude-sonnet-5"
            }
            message.merge(extra) { _, new in new }
            return .object(message)
        }
        func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
        func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text)] }
        func call(_ id: String, _ name: String, _ args: JSONValue) -> JSONValue {
            ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": args]
        }
        func result(_ id: String, _ name: String, _ output: String, minutesAgo: Double, isError: Bool = false) -> JSONValue {
            message("toolResult", [text(output)], minutesAgo: minutesAgo,
                    extra: ["toolCallId": .string(id), "toolName": .string(name), "isError": .bool(isError)])
        }
        func receipt(_ id: String, _ key: String, _ runId: String, minutesAgo: Double) -> JSONValue {
            result(id, "sessions_spawn", #"{"status":"accepted","childSessionKey":"\#(key)","runId":"\#(runId)"}"#,
                   minutesAgo: minutesAgo)
        }

        transcripts[Self.subagentParentKey] = [
            message("user", [text("Put together a launch plan for Pincer 2.0: pricing, timeline and naming.")], minutesAgo: 32),
            message("assistant", [
                thinking("Gather context first, then split the work into three helpers."),
                call("call_lp_search", "web_search", ["query": "operator app launch checklist"]),
            ], minutesAgo: 31.8),
            result("call_lp_search", "web_search", "8 results", minutesAgo: 31.2),
            message("assistant", [call("call_lp_fetch", "web_fetch", ["url": "https://example.com/launch-guide"])], minutesAgo: 31.1),
            result("call_lp_fetch", "web_fetch", "Launch guide (4,210 words)", minutesAgo: 30.6),
            message("assistant", [call("call_lp_read", "read", ["path": "notes/roadmap.md"])], minutesAgo: 30.5),
            result("call_lp_read", "read", "# Roadmap\n…", minutesAgo: 30.3),
            message("assistant", [
                thinking("Pricing, timeline and trademark are independent; run them in parallel."),
                call("call_spawn_pricing", "sessions_spawn",
                     ["task": "Compare competitor pricing.", "label": "Competitor pricing scan"]),
                call("call_spawn_timeline", "sessions_spawn",
                     ["task": "Draft a launch timeline.", "label": "Draft launch timeline", "agentId": "main"]),
                call("call_spawn_trademark", "sessions_spawn",
                     ["task": "Check that the name is free to trademark.", "label": "Check trademark availability"]),
            ], minutesAgo: 29.8),
            receipt("call_spawn_pricing", kids.done, "run_seed_pricing", minutesAgo: 29.5),
            receipt("call_spawn_timeline", kids.running, Self.seededRunningSubagentRunId, minutesAgo: 29.45),
            receipt("call_spawn_trademark", kids.failed, "run_seed_trademark", minutesAgo: 29.4),
            message("assistant", [text("Spawned three helpers for the launch plan. I'll pull their results together when they finish.")],
                    minutesAgo: 29),
        ]
        transcripts[kids.done] = [
            message("user", [text("Compare competitor pricing.")], minutesAgo: 29.5),
            message("assistant", [thinking("Two helpers: current pricing pages, and archived ones for history."),
                                  call("call_pr_spawn_pages", "sessions_spawn",
                                       ["task": "Summarize competitors' pricing pages.", "label": "Summarize pricing pages"]),
                                  call("call_pr_spawn_archive", "sessions_spawn",
                                       ["task": "Fetch archived pricing pages.", "label": "Fetch archived pricing"])],
                    minutesAgo: 28.2),
            receipt("call_pr_spawn_pages", kids.grandchild, "run_seed_pricing_pages", minutesAgo: 28.1),
            receipt("call_pr_spawn_archive", kids.aborted, "run_seed_archive", minutesAgo: 28.05),
            message("assistant", [call("call_pr_write", "write", ["path": "research/pricing.md"])], minutesAgo: 22),
            result("call_pr_write", "write", "ok", minutesAgo: 21.5),
            message("assistant", [text("Five competitors compared in research/pricing.md.")], minutesAgo: 21),
        ]
        transcripts[kids.grandchild] = [
            message("user", [text("Summarize competitors' pricing pages.")], minutesAgo: 28),
            message("assistant", [call("call_pp_fetch", "web_fetch", ["url": "https://example.com/pricing"])], minutesAgo: 27.5),
            result("call_pp_fetch", "web_fetch", "Pricing page (3 tiers)", minutesAgo: 26.5),
            message("assistant", [text("Tiers and prices in a table.")], minutesAgo: 24),
        ]
        transcripts[kids.aborted] = [
            message("user", [text("Fetch archived pricing pages.")], minutesAgo: 27.5),
            message("assistant", [call("call_ar_fetch", "web_fetch", ["url": "https://web.archive.org/web/2024/example.com/pricing"])],
                    minutesAgo: 27),
        ]
        transcripts[kids.running] = [
            message("user", [text("Draft a launch timeline.")], minutesAgo: 6),
            message("assistant", [thinking("Start from the release calendar."),
                                  call("call_tl_cal", "read", ["path": "notes/release-calendar.md"])], minutesAgo: 5.5),
            result("call_tl_cal", "read", "# Release calendar\n…", minutesAgo: 5.2),
            message("assistant", [call("call_tl_search", "web_search", ["query": "app store review times"])], minutesAgo: 4),
            result("call_tl_search", "web_search", "6 results", minutesAgo: 3.4),
            message("assistant", [call("call_tl_draft", "write", ["path": "plans/launch-timeline.md"])], minutesAgo: 1),
        ]
        transcripts[kids.failed] = [
            message("user", [text("Check that the name is free to trademark.")], minutesAgo: 29.4),
            message("assistant", [thinking("Search the trademark database for the name."),
                                  call("call_tm_search", "web_search", ["query": "Pincer trademark"])], minutesAgo: 29.2),
            result("call_tm_search", "web_search", "4 results", minutesAgo: 28.8),
            message("assistant", [call("call_tm_fetch", "web_fetch", ["url": "https://tmsearch.uspto.gov/search?q=pincer"])],
                    minutesAgo: 28.7),
            result("call_tm_fetch", "web_fetch", "503 Service Unavailable", minutesAgo: 26.5, isError: true),
            message("assistant", [text("The trademark search failed.")], minutesAgo: 26,
                    extra: ["stopReason": "error", "errorMessage": "web_fetch failed: 503 Service Unavailable from tmsearch.uspto.gov"]),
        ]
    }

    private static func agentEvent(_ runId: String, _ key: String, spawnedBy: String?, seq: Int, stream: String, ts: Double,
                                   _ data: JSONValue) -> JSONValue
    {
        var payload: [String: JSONValue] = [
            "runId": .string(runId), "sessionKey": .string(key), "seq": JSONValue(seq),
            "stream": .string(stream), "ts": .number(ts.rounded()), "data": data,
        ]
        if let spawnedBy { payload["spawnedBy"] = .string(spawnedBy) }
        return .object(payload)
    }

    /// The seeded runs' `agent` events, oldest first, with their original timestamps, so the Runs
    /// panel has lanes to show: thinking, tool calls (one errored), a failed run, a stopped one and
    /// one still running inside an open `write`.
    static func seededRunEvents(now: Double = DemoGateway.now().double ?? 0) -> [JSONValue] {
        let kids = Self.seededSubagents
        var events: [(ts: Double, payload: JSONValue)] = []
        func run(_ runId: String, _ key: String, spawnedBy: String?, _ steps: [(minutesAgo: Double, stream: String, data: JSONValue)]) {
            for (index, step) in steps.enumerated() {
                let ts = now - step.minutesAgo * Self.minuteMs
                events.append((ts, Self.agentEvent(runId, key, spawnedBy: spawnedBy, seq: index + 1, stream: step.stream,
                                                   ts: ts, step.data)))
            }
        }
        func ms(_ minutesAgo: Double) -> JSONValue { .number((now - minutesAgo * Self.minuteMs).rounded()) }
        func start(_ minutesAgo: Double) -> (Double, String, JSONValue) {
            (minutesAgo, "lifecycle", ["phase": "start", "startedAt": ms(minutesAgo)])
        }
        func end(_ minutesAgo: Double, aborted: Bool = false) -> (Double, String, JSONValue) {
            (minutesAgo, "lifecycle", aborted
                ? ["phase": "end", "status": "cancelled", "aborted": true, "stopReason": "user", "endedAt": ms(minutesAgo)]
                : ["phase": "end", "stopReason": "stop", "aborted": false, "endedAt": ms(minutesAgo)])
        }
        func thinking(_ minutesAgo: Double, _ text: String) -> (Double, String, JSONValue) {
            (minutesAgo, "thinking", ["text": .string(text), "delta": .string(text)])
        }
        func writing(_ minutesAgo: Double, _ text: String) -> (Double, String, JSONValue) {
            (minutesAgo, "assistant", ["text": .string(text), "delta": .string(text)])
        }
        func tool(_ minutesAgo: Double, _ id: String, _ name: String, _ args: JSONValue) -> (Double, String, JSONValue) {
            (minutesAgo, "tool", ["phase": "start", "name": .string(name), "toolCallId": .string(id), "args": args])
        }
        func toolResult(_ minutesAgo: Double, _ id: String, _ name: String, _ result: String, isError: Bool = false)
            -> (Double, String, JSONValue)
        {
            (minutesAgo, "tool", ["phase": "result", "name": .string(name), "toolCallId": .string(id),
                                  "isError": .bool(isError), "result": .string(result)])
        }

        run(Self.seededParentRunId, Self.subagentParentKey, spawnedBy: nil, [
            start(32), thinking(31.9, "Gather context first, then split the work into three helpers."),
            tool(31.8, "call_lp_search", "web_search", ["query": "operator app launch checklist"]),
            toolResult(31.2, "call_lp_search", "web_search", "8 results"),
            tool(31.1, "call_lp_fetch", "web_fetch", ["url": "https://example.com/launch-guide"]),
            toolResult(30.6, "call_lp_fetch", "web_fetch", "Launch guide (4,210 words)"),
            tool(30.5, "call_lp_read", "read", ["path": "notes/roadmap.md"]),
            toolResult(30.3, "call_lp_read", "read", "# Roadmap"),
            thinking(30.2, "Pricing, timeline and trademark are independent; run them in parallel."),
            tool(29.8, "call_spawn_pricing", "sessions_spawn", ["label": "Competitor pricing scan"]),
            toolResult(29.5, "call_spawn_pricing", "sessions_spawn", "accepted"),
            tool(29.5, "call_spawn_timeline", "sessions_spawn", ["label": "Draft launch timeline"]),
            toolResult(29.45, "call_spawn_timeline", "sessions_spawn", "accepted"),
            tool(29.45, "call_spawn_trademark", "sessions_spawn", ["label": "Check trademark availability"]),
            toolResult(29.4, "call_spawn_trademark", "sessions_spawn", "accepted"),
            writing(29.2, "Spawned three helpers for the launch plan."), end(29),
        ])
        run("run_seed_pricing", kids.done, spawnedBy: Self.subagentParentKey, [
            start(29.5), thinking(29.3, "Two helpers: current pricing pages, and archived ones for history."),
            tool(28.2, "call_pr_spawn_pages", "sessions_spawn", ["label": "Summarize pricing pages"]),
            toolResult(28.1, "call_pr_spawn_pages", "sessions_spawn", "accepted"),
            tool(28.1, "call_pr_spawn_archive", "sessions_spawn", ["label": "Fetch archived pricing"]),
            toolResult(28.05, "call_pr_spawn_archive", "sessions_spawn", "accepted"),
            thinking(23.5, "Both helpers are back; write it up."),
            tool(22, "call_pr_write", "write", ["path": "research/pricing.md"]),
            toolResult(21.5, "call_pr_write", "write", "ok"),
            writing(21.2, "Five competitors compared."), end(21),
        ])
        run("run_seed_pricing_pages", kids.grandchild, spawnedBy: kids.done, [
            start(28), thinking(27.8, "Fetch each pricing page."),
            tool(27.5, "call_pp_fetch", "web_fetch", ["url": "https://example.com/pricing"]),
            toolResult(26.5, "call_pp_fetch", "web_fetch", "Pricing page (3 tiers)"),
            writing(24.5, "Tiers and prices in a table."), end(24),
        ])
        run("run_seed_archive", kids.aborted, spawnedBy: kids.done, [
            start(27.5),
            tool(27, "call_ar_fetch", "web_fetch", ["url": "https://web.archive.org/web/2024/example.com/pricing"]),
            end(25.5, aborted: true),
        ])
        run(Self.seededRunningSubagentRunId, kids.running, spawnedBy: Self.subagentParentKey, [
            start(6), thinking(5.8, "Start from the release calendar."),
            tool(5.5, "call_tl_cal", "read", ["path": "notes/release-calendar.md"]),
            toolResult(5.2, "call_tl_cal", "read", "# Release calendar"),
            thinking(4.5, "Check how long app review takes."),
            tool(4, "call_tl_search", "web_search", ["query": "app store review times"]),
            toolResult(3.4, "call_tl_search", "web_search", "6 results"),
            thinking(2, "Draft the plan week by week."),
            writing(1.5, "Week 1: beta."),
            tool(1, "call_tl_draft", "write", ["path": "plans/launch-timeline.md"]),
        ])
        run("run_seed_trademark", kids.failed, spawnedBy: Self.subagentParentKey, [
            start(29.4), thinking(29.3, "Search the trademark database for the name."),
            tool(29.2, "call_tm_search", "web_search", ["query": "Pincer trademark"]),
            toolResult(28.8, "call_tm_search", "web_search", "4 results"),
            tool(28.7, "call_tm_fetch", "web_fetch", ["url": "https://tmsearch.uspto.gov/search?q=pincer"]),
            toolResult(26.5, "call_tm_fetch", "web_fetch", "503 Service Unavailable\nRetry-After: 120", isError: true),
            (26, "lifecycle", ["phase": "error", "error": "web_fetch failed: 503 Service Unavailable from tmsearch.uspto.gov",
                               "endedAt": ms(26)]),
        ])
        return events.sorted { $0.ts < $1.ts }.map(\.payload)
    }

    /// The running helper's next live step: the open tool finishes and the next one starts, so the
    /// lane always shows a tool running. `seq` is the last one sent; returns the events and the new `seq`.
    static func liveSubagentStep(_ step: Int, seq: Int, now: Double = DemoGateway.now().double ?? 0) -> (events: [JSONValue], seq: Int) {
        let tools: [(name: String, args: JSONValue)] = [
            ("web_search", ["query": "launch week checklist"]), ("read", ["path": "notes/marketing.md"]),
            ("web_fetch", ["url": "https://example.com/press-kit"]), ("edit", ["path": "plans/launch-timeline.md"]),
        ]
        let previous = step == 0 ? (id: "call_tl_draft", name: "write") : (id: "call_tl_live_\(step - 1)", name: tools[(step - 1) % tools.count].name)
        let next = tools[step % tools.count]
        var seq = seq
        var events: [JSONValue] = []
        func add(_ stream: String, _ data: JSONValue) {
            seq += 1
            events.append(Self.agentEvent(Self.seededRunningSubagentRunId, Self.seededSubagents.running,
                                          spawnedBy: Self.subagentParentKey, seq: seq, stream: stream, ts: now, data))
        }
        add("tool", ["phase": "result", "name": .string(previous.name), "toolCallId": .string(previous.id),
                     "isError": false, "result": "ok"])
        if step % 3 == 2 { add("thinking", ["text": "Next section.", "delta": "Next section."]) }
        add("tool", ["phase": "start", "name": .string(next.name), "toolCallId": .string("call_tl_live_\(step)"), "args": next.args])
        return (events, seq)
    }

    /// A stopped subagent's row, like the Gateway's registry records it: `killed`, not idle.
    static func markSubagentAborted(_ row: inout [String: JSONValue], at now: Double = DemoGateway.now().double ?? 0) {
        guard row["key"]?.string?.contains(":subagent:") == true else { return }
        row["status"] = "killed"
        row["abortedLastRun"] = true
        row["endedAt"] = .number(now)
        row["subagentRunState"] = "historical"
        if let started = row["startedAt"]?.double { row["runtimeMs"] = .number(max(0, now - started)) }
    }

    /// `hasActiveSubagentRun` for `parentKey`, from its children's rows.
    static func hasRunningChild(_ parentKey: String, in sessions: [String: [String: JSONValue]]) -> Bool {
        sessions.values.contains { row in
            (row["spawnedBy"]?.string ?? row["parentSessionKey"]?.string) == parentKey && row["status"]?.string == "running"
        }
    }
}
