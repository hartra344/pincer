import Foundation

/// The demo's subagent runs (`sessions_spawn`) and their streamed activity, as
/// `mock-gateway/subagents.mjs` seeds them: "Release prep" spawned three helpers (one done, one
/// failed, one still running whose own helper was stopped). Row and event shapes follow upstream:
/// `spawnedBy`/`parentSessionKey`, `childSessions`, `spawnDepth`, `status`
/// (`running | done | failed | killed`), `startedAt`/`endedAt`/`runtimeMs`, and `agent` events
/// `{runId, seq, stream, ts, sessionKey, spawnedBy?, data}`.
extension DemoGateway {
    static let subagentParentKey = "agent:coder:dashboard:release"
    static let seededSubagents = (
        done: "agent:coder:subagent:5b0f2c1e-8d4a-4f6e-9a51-2c7d3e1f0a01",
        failed: "agent:coder:subagent:9e3d7a60-1b2c-4d8e-b7f4-6a5c4d3b2e02",
        running: "agent:research:subagent:c41a8f93-7e6d-4a2b-8c1f-0d9e8b7a6f03",
        killed: "agent:research:subagent:e2b19d74-3f5a-4c6b-9d8e-7f1a2b3c4d04"
    )
    static let seededRunningSubagentRunId = "run_seed_docs_audit"
    static let seededParentRunId = "run_seed_release"

    private static let minuteMs = 60_000.0

    /// Adds the release chat and its helpers to the demo's sessions and transcripts.
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
            Self.subagentParentKey, agent: "coder", title: "Release prep",
            preview: "Spawned three helpers for the 2.4 release.", minutesAgo: 29,
            ["category": "Work", "childSessions": JSONValue([kids.done, kids.failed, kids.running]),
             "hasActiveSubagentRun": true, "lastRunId": .string(Self.seededParentRunId),
             "startedAt": at(30), "endedAt": at(29), "runtimeMs": .number(minute), "status": "done"])
        sessions[kids.done] = child(
            kids.done, agent: "coder", title: "Write the changelog", preview: "CHANGELOG.md updated with 14 entries.",
            minutesAgo: 26, parent: Self.subagentParentKey, depth: 1,
            ["status": "done", "startedAt": at(29), "endedAt": at(26), "runtimeMs": .number(3 * minute),
             "lastRunId": "run_seed_changelog"])
        sessions[kids.failed] = child(
            kids.failed, agent: "coder", title: "Run the test suite", preview: "2 tests failed in LoginTests.",
            minutesAgo: 22, parent: Self.subagentParentKey, depth: 1,
            ["status": "failed", "startedAt": at(29), "endedAt": at(22), "runtimeMs": .number(7 * minute),
             "lastRunId": "run_seed_tests", "lastRunError": "swift test exited with code 1: 2 failures in LoginTests"])
        sessions[kids.running] = child(
            kids.running, agent: "research", title: "Audit the docs", preview: "Checking links in docs/setup.md…",
            minutesAgo: 1, parent: Self.subagentParentKey, depth: 1,
            ["status": "running", "startedAt": at(4), "hasActiveRun": true,
             "activeRunIds": [.string(Self.seededRunningSubagentRunId)], "lastRunId": .string(Self.seededRunningSubagentRunId),
             "subagentRunState": "active", "subagentRole": "orchestrator", "subagentControlScope": "children",
             "childSessions": [.string(kids.killed)]])
        sessions[kids.killed] = child(
            kids.killed, agent: "research", title: "Check external links", preview: "Stopped.",
            minutesAgo: 2, parent: kids.running, depth: 2,
            ["status": "killed", "abortedLastRun": true, "startedAt": at(3), "endedAt": at(2),
             "runtimeMs": .number(minute), "lastRunId": "run_seed_links"])

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
        func receipt(_ id: String, _ key: String, _ runId: String) -> JSONValue {
            result(id, "sessions_spawn", #"{"status":"accepted","childSessionKey":"\#(key)","runId":"\#(runId)"}"#,
                   minutesAgo: 29.4)
        }

        transcripts[Self.subagentParentKey] = [
            message("user", [text("Get the 2.4 release ready: changelog, tests and a docs pass.")], minutesAgo: 30),
            message("assistant", [
                thinking("Three independent jobs, so I'll run them in parallel as subagents."),
                call("call_spawn_changelog", "sessions_spawn",
                     ["task": "Summarize merged PRs since 2.3 into CHANGELOG.md.", "label": "Write the changelog"]),
                call("call_spawn_tests", "sessions_spawn", ["task": "Run swift test and report failures.", "label": "Run the test suite"]),
                call("call_spawn_docs", "sessions_spawn",
                     ["task": "Check docs/ for stale steps and broken links.", "label": "Audit the docs", "agentId": "research"]),
            ], minutesAgo: 29.5),
            receipt("call_spawn_changelog", kids.done, "run_seed_changelog"),
            receipt("call_spawn_tests", kids.failed, "run_seed_tests"),
            receipt("call_spawn_docs", kids.running, Self.seededRunningSubagentRunId),
            message("assistant", [text("Spawned three helpers for the 2.4 release. I'll report back when they finish.")],
                    minutesAgo: 29),
        ]
        transcripts[kids.done] = [
            message("user", [text("Summarize merged PRs since 2.3 into CHANGELOG.md.")], minutesAgo: 29),
            message("assistant", [thinking("List the merged PRs first."),
                                  call("call_cl_log", "exec", ["command": "git log --merges v2.3..HEAD --oneline"])], minutesAgo: 28.8),
            result("call_cl_log", "exec", "14 merge commits", minutesAgo: 28.5),
            message("assistant", [call("call_cl_edit", "edit", ["path": "CHANGELOG.md"])], minutesAgo: 27),
            result("call_cl_edit", "edit", "ok", minutesAgo: 26.5),
            message("assistant", [text("CHANGELOG.md updated with 14 entries.")], minutesAgo: 26),
        ]
        transcripts[kids.failed] = [
            message("user", [text("Run swift test and report failures.")], minutesAgo: 29),
            message("assistant", [thinking("Build first, then run the tests."),
                                  call("call_t_build", "exec", ["command": "swift build"])], minutesAgo: 28.8),
            result("call_t_build", "exec", "Build complete! (41.2s)", minutesAgo: 28),
            message("assistant", [call("call_t_test", "exec", ["command": "swift test"])], minutesAgo: 27.9),
            result("call_t_test", "exec", "LoginTests.testTimeout failed\nLoginTests.testRefresh failed\nexit code 1",
                   minutesAgo: 22.5, isError: true),
            message("assistant", [text("2 tests failed in LoginTests.")], minutesAgo: 22,
                    extra: ["stopReason": "error", "errorMessage": "swift test exited with code 1: 2 failures in LoginTests"]),
        ]
        transcripts[kids.running] = [
            message("user", [text("Check docs/ for stale steps and broken links.")], minutesAgo: 4),
            message("assistant", [thinking("Split the external link check out to a helper."),
                                  call("call_d_spawn", "sessions_spawn",
                                       ["task": "Check external links in docs/.", "label": "Check external links"])], minutesAgo: 3.5),
            result("call_d_spawn", "sessions_spawn",
                   #"{"status":"accepted","childSessionKey":"\#(kids.killed)","runId":"run_seed_links"}"#, minutesAgo: 3.4),
            message("assistant", [call("call_d_install", "read", ["path": "docs/install.md"])], minutesAgo: 3),
            result("call_d_install", "read", "# Install\n…", minutesAgo: 2.8),
            message("assistant", [call("call_d_old", "read", ["path": "docs/legacy/upgrade.md"])], minutesAgo: 2.5),
            result("call_d_old", "read", "ENOENT: no such file or directory, open 'docs/legacy/upgrade.md'",
                   minutesAgo: 2.3, isError: true),
            message("assistant", [thinking("The legacy guide moved; check the setup page next."),
                                  call("call_d_read", "read", ["path": "docs/setup.md"])], minutesAgo: 1),
        ]
        transcripts[kids.killed] = [
            message("user", [text("Check external links in docs/.")], minutesAgo: 3),
            message("assistant", [call("call_l_fetch", "web_fetch", ["url": "https://example.com/guide"])], minutesAgo: 2.5),
        ]
    }

    /// The seeded runs' `agent` events, oldest first, with their original timestamps, so the Runs
    /// panel has lanes to show: thinking, tool calls (two errors), a failed run, a stopped one and
    /// one still running inside an open `read`.
    static func seededRunEvents(now: Double = DemoGateway.now().double ?? 0) -> [JSONValue] {
        let kids = Self.seededSubagents
        var events: [(ts: Double, payload: JSONValue)] = []
        func run(_ runId: String, _ key: String, spawnedBy: String?, _ steps: [(minutesAgo: Double, stream: String, data: JSONValue)]) {
            for (index, step) in steps.enumerated() {
                let ts = (now - step.minutesAgo * Self.minuteMs).rounded()
                var payload: [String: JSONValue] = [
                    "runId": .string(runId), "sessionKey": .string(key), "seq": JSONValue(index + 1),
                    "stream": .string(step.stream), "ts": .number(ts), "data": step.data,
                ]
                if let spawnedBy { payload["spawnedBy"] = .string(spawnedBy) }
                events.append((ts, .object(payload)))
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
            start(30), thinking(29.9, "Three independent jobs, so I'll run them in parallel as subagents."),
            tool(29.6, "call_spawn_changelog", "sessions_spawn", ["label": "Write the changelog"]),
            toolResult(29.5, "call_spawn_changelog", "sessions_spawn", "accepted"),
            tool(29.5, "call_spawn_tests", "sessions_spawn", ["label": "Run the test suite"]),
            toolResult(29.45, "call_spawn_tests", "sessions_spawn", "accepted"),
            tool(29.45, "call_spawn_docs", "sessions_spawn", ["label": "Audit the docs"]),
            toolResult(29.4, "call_spawn_docs", "sessions_spawn", "accepted"),
            writing(29.2, "Spawned three helpers for the 2.4 release."), end(29),
        ])
        run("run_seed_changelog", kids.done, spawnedBy: Self.subagentParentKey, [
            start(29), thinking(28.9, "List the merged PRs first."),
            tool(28.8, "call_cl_log", "exec", ["command": "git log --merges v2.3..HEAD --oneline"]),
            toolResult(28.5, "call_cl_log", "exec", "14 merge commits"),
            thinking(28.4, "Group them by area."),
            tool(27, "call_cl_edit", "edit", ["path": "CHANGELOG.md"]), toolResult(26.5, "call_cl_edit", "edit", "ok"),
            writing(26.2, "CHANGELOG.md updated with 14 entries."), end(26),
        ])
        run("run_seed_tests", kids.failed, spawnedBy: Self.subagentParentKey, [
            start(29), thinking(28.9, "Build first, then run the tests."),
            tool(28.8, "call_t_build", "exec", ["command": "swift build"]),
            toolResult(28, "call_t_build", "exec", "Build complete! (41.2s)"),
            tool(27.9, "call_t_test", "exec", ["command": "swift test"]),
            toolResult(22.5, "call_t_test", "exec", "LoginTests.testTimeout failed\nLoginTests.testRefresh failed", isError: true),
            (22, "lifecycle", ["phase": "error", "error": "swift test exited with code 1: 2 failures in LoginTests",
                               "endedAt": ms(22)]),
        ])
        run(Self.seededRunningSubagentRunId, kids.running, spawnedBy: Self.subagentParentKey, [
            start(4), thinking(3.9, "Split the external link check out to a helper."),
            tool(3.5, "call_d_spawn", "sessions_spawn", ["label": "Check external links"]),
            toolResult(3.4, "call_d_spawn", "sessions_spawn", "accepted"),
            tool(3, "call_d_install", "read", ["path": "docs/install.md"]),
            toolResult(2.8, "call_d_install", "read", "# Install"),
            tool(2.5, "call_d_old", "read", ["path": "docs/legacy/upgrade.md"]),
            toolResult(2.3, "call_d_old", "read", "ENOENT: no such file or directory, open 'docs/legacy/upgrade.md'",
                       isError: true),
            thinking(1.2, "The legacy guide moved; check the setup page next."),
            tool(1, "call_d_read", "read", ["path": "docs/setup.md"]),
        ])
        run("run_seed_links", kids.killed, spawnedBy: kids.running, [
            start(3), tool(2.5, "call_l_fetch", "web_fetch", ["url": "https://example.com/guide"]), end(2, aborted: true),
        ])
        return events.sorted { $0.ts < $1.ts }.map(\.payload)
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
