import Foundation
import Testing
@testable import PincerKit

/// `SubagentTree` (#35): nesting from `sessions.list` rows, status mapping and durations.
struct SubagentTreeTests {
    static let root = "agent:main:main"
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    func row(_ key: String, _ fields: [String: JSONValue] = [:]) -> SessionRow {
        var object = fields
        object["key"] = .string(key)
        return SessionRow(.object(object))!
    }

    func child(_ id: String, of parent: String = root, startedAt: Double? = nil, _ fields: [String: JSONValue] = [:]) -> SessionRow {
        var fields = fields
        fields["spawnedBy"] = fields["spawnedBy"] ?? .string(parent)
        if let startedAt { fields["startedAt"] = .number(startedAt) }
        return self.row("agent:main:subagent:\(id)", fields)
    }

    func build(_ rows: [SessionRow], root: String = root, now: Date = t0, connected: Bool = true) -> SubagentTree {
        SubagentTree.build(rows: rows, rootKey: root, now: now, connected: connected)
    }

    func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    // MARK: Structure

    @Test func childrenSortOldestFirstWithKeyTiebreak() {
        let tree = self.build([
            self.row(Self.root),
            self.child("c", startedAt: 3000),
            self.child("b", startedAt: 1000),
            self.child("a", startedAt: 1000),
            // No startedAt: falls back to createdAt, then latest activity.
            self.child("d", ["createdAt": 2000]),
            self.child("e", ["lastActivityAt": 500]),
        ])
        #expect(tree.children.map(\.key) == ["e", "a", "b", "d", "c"].map { "agent:main:subagent:\($0)" })
        #expect(tree.children.allSatisfy { $0.depth == 1 })
    }

    @Test func parentSessionKeyAloneNestsAndSpawnedByWinsWhenBothDisagree() {
        let tree = self.build([
            self.row("agent:main:subagent:p", ["parentSessionKey": .string(Self.root)]),
            self.row("agent:main:subagent:q", ["parentSessionKey": "agent:main:subagent:p", "spawnedBy": .string(Self.root)]),
        ])
        #expect(tree.children.map(\.key) == ["agent:main:subagent:p"])
        // `parentKey` prefers parentSessionKey, so q nests under p.
        #expect(tree.children.first?.children.map(\.key) == ["agent:main:subagent:q"])
    }

    @Test func rootNeedNotBeListed() {
        let tree = self.build([self.child("a", startedAt: 1)])
        #expect(tree.children.map(\.key) == ["agent:main:subagent:a"])
    }

    @Test func orphansAndOtherTreesAreLeftOut() {
        let tree = self.build([
            self.row(Self.root),
            self.child("mine", startedAt: 1),
            self.child("orphan", of: "agent:main:subagent:gone", startedAt: 1),
            self.child("other", of: "agent:research:main", startedAt: 1),
            self.row("agent:main:dashboard:plain"),
        ])
        #expect(tree.flattened.map(\.key) == ["agent:main:subagent:mine"])
        #expect(!tree.isEmpty && tree.count == 1)
        #expect(self.build([self.row(Self.root)]).isEmpty)
    }

    @Test func cyclesTerminate() {
        let tree = self.build([
            // The root claims a child as its parent; it must not appear under itself.
            self.row(Self.root, ["spawnedBy": "agent:main:subagent:a"]),
            self.child("a", startedAt: 1),
            self.child("b", of: "agent:main:subagent:a", startedAt: 2),
            // Detached cycle and a self-parent.
            self.child("x", of: "agent:main:subagent:y"),
            self.child("y", of: "agent:main:subagent:x"),
            self.child("self", of: "agent:main:subagent:self"),
        ])
        #expect(tree.flattened.map(\.key) == ["agent:main:subagent:a", "agent:main:subagent:b"])
        #expect(tree.node(Self.root) == nil)
    }

    @Test func duplicateRowsKeepTheFirst() {
        let tree = self.build([
            self.child("a", startedAt: 1, ["label": "First", "status": "done"]),
            self.child("a", startedAt: 1, ["label": "Second", "status": "failed"]),
        ])
        #expect(tree.count == 1 && tree.children.first?.title == "First" && tree.children.first?.status == .done)
    }

    @Test func deepNestingStopsAtMaxDepth() {
        var rows = [self.row(Self.root)]
        var parent = Self.root
        for level in 1...20 {
            let key = "agent:main:subagent:l\(level)"
            rows.append(self.row(key, ["spawnedBy": .string(parent), "startedAt": .number(Double(level))]))
            parent = key
        }
        let tree = self.build(rows)
        let flat = tree.flattened
        #expect(flat.count == SubagentTree.maxDepth)
        #expect(flat.map(\.depth) == Array(1...SubagentTree.maxDepth))
        #expect(flat.last?.children.isEmpty == true)
        #expect(tree.children.first?.descendantCount == SubagentTree.maxDepth - 1)
    }

    @Test func nodeBudgetCapsHugeTrees() {
        let rows = (0..<(SubagentTree.maxNodes + 200)).map { self.child(String(format: "%05d", $0), startedAt: Double($0)) }
        let tree = self.build(rows)
        #expect(tree.count == SubagentTree.maxNodes)
        #expect(tree.children.first?.key == "agent:main:subagent:00000")
    }

    @Test func largeFlatInputBuildsQuickly() {
        // 20k unrelated rows plus a 400-node tree: linear, not quadratic.
        var rows = (0..<20_000).map { self.row("agent:main:dashboard:\($0)") }
        rows += (0..<400).map { self.child("k\($0)", of: $0 < 20 ? Self.root : "agent:main:subagent:k\($0 % 20)", startedAt: Double($0)) }
        let clock = ContinuousClock()
        var tree = SubagentTree(rootKey: Self.root)
        let elapsed = clock.measure { tree = self.build(rows) }
        #expect(tree.count == 400)
        #expect(elapsed < .seconds(2), "build took \(elapsed)")
    }

    @Test func standaloneChatsDoNotNestButAutomationSubagentsFallBack() {
        let tree = self.build([
            // A chat started from main records it as parent but is its own conversation.
            self.row("agent:main:dashboard:new", ["parentSessionKey": .string(Self.root), "createdVia": "operator"]),
            self.child("real", startedAt: 1),
        ])
        #expect(tree.flattened.map(\.key) == ["agent:main:subagent:real"])

        let cron = "agent:main:cron:job1"
        let fromRun = self.build([
            self.row(cron),
            self.row("agent:main:subagent:c1", ["spawnedBy": "agent:main:cron:job1:run:r1"]),
        ], root: cron)
        #expect(fromRun.children.map(\.key) == ["agent:main:subagent:c1"])
    }

    @Test func treeHelpers() {
        let tree = self.build([
            self.child("a", startedAt: 1, ["status": "running"]),
            self.child("b", of: "agent:main:subagent:a", startedAt: 2, ["hasActiveRun": true]),
            self.child("c", startedAt: 3, ["status": "done"]),
        ])
        #expect(tree.count == 3 && tree.runningCount == 2)
        #expect(tree.node("agent:main:subagent:b")?.depth == 2)
        #expect(tree.node("agent:main:subagent:zzz") == nil)
        #expect(tree.flattened.map(\.key) == ["a", "b", "c"].map { "agent:main:subagent:\($0)" })
        #expect(tree.children.first?.descendantCount == 1)
    }

    @Test func nodeFields() {
        let tree = self.build([
            self.row("agent:research:subagent:z", [
                "spawnedBy": .string(Self.root), "label": "Audit the docs", "status": "failed",
                "lastRunError": "boom", "startedAt": 1000, "endedAt": 4000, "lastActivityAt": 5000,
            ]),
        ])
        let node = try! #require(tree.children.first)
        #expect(node.title == "Audit the docs" && node.agentId == "research" && node.lastError == "boom")
        #expect(node.startedAt == Date(timeIntervalSince1970: 1) && node.endedAt == Date(timeIntervalSince1970: 4))
        #expect(node.lastActivity == Date(timeIntervalSince1970: 5))
    }

    // MARK: Status

    @Test(arguments: [
        (["status": "running"], SubagentStatus.running),
        (["status": "done", "hasActiveRun": true], .running),
        (["subagentRunState": "active"], .running),
        (["status": "done"], .done),
        (["status": "failed"], .error),
        (["status": "timeout"], .error),
        (["status": "FAILED"], .error),
        (["status": "killed"], .aborted),
        (["status": "done", "abortedLastRun": true], .aborted),
        (["lastRunError": "boom"], .error),
        (["endedAt": 5000], .done),
        (["subagentRunState": "interrupted"], .error),
        (["subagentRunState": "historical", "status": "done"], .done),
        ([:], .idle),
    ] as [([String: JSONValue], SubagentStatus)])
    func statusMapping(fields: [String: JSONValue], expected: SubagentStatus) {
        #expect(self.row("agent:main:subagent:s", fields).subagentStatus == expected, "\(fields)")
    }

    @Test func disconnectedRunningReadsUnknownOthersKeepTheirStatus() {
        let rows = [
            self.child("r", startedAt: 1, ["status": "running"]),
            self.child("d", startedAt: 2, ["status": "done"]),
            self.child("f", startedAt: 3, ["status": "failed"]),
            self.child("k", startedAt: 4, ["status": "killed"]),
        ]
        #expect(self.build(rows, connected: false).children.map(\.status) == [.unknown, .done, .error, .aborted])
        #expect(self.build(rows).children.map(\.status) == [.running, .done, .error, .aborted])
    }

    @Test func statusLabelsAreDistinct() {
        let labels = SubagentStatus.allCases.map(\.label)
        #expect(Set(labels).count == labels.count && !labels.contains(""))
    }

    // MARK: Durations

    @Test func runningDurationGrowsWithNow() {
        let started = Self.t0.addingTimeInterval(-90)
        let tree = self.build([self.child("r", startedAt: self.ms(started), ["status": "running"])])
        let node = try! #require(tree.children.first)
        #expect(node.duration(now: Self.t0) == 90)
        #expect(node.duration(now: Self.t0.addingTimeInterval(30)) == 120)
    }

    @Test func finishedDurationPrefersRuntimeThenStartToEnd() {
        let start = self.ms(Self.t0) - 600_000
        let tree = self.build([
            self.child("rt", startedAt: start, ["status": "done", "runtimeMs": 42_000, "endedAt": .number(start + 600_000)]),
            self.child("se", startedAt: start + 1, ["status": "failed", "endedAt": .number(start + 1 + 7_000)]),
            self.child("none", ["status": "done"]),
            self.child("rtonly", ["status": "done", "runtimeMs": 1500]),
        ])
        let byKey = Dictionary(uniqueKeysWithValues: tree.flattened.map { ($0.key, $0) })
        let later = Self.t0.addingTimeInterval(3600)
        #expect(byKey["agent:main:subagent:rt"]?.duration(now: later) == 42)
        #expect(byKey["agent:main:subagent:se"]?.duration(now: later) == 7)
        #expect(byKey["agent:main:subagent:none"]?.duration(now: later) == nil)
        #expect(byKey["agent:main:subagent:rtonly"]?.duration(now: later) == 1.5)
    }

    @Test func runningWithAccumulatedRuntimeNeverShrinks() {
        // runtimeMs covers earlier follow-up runs, so it can exceed this run's elapsed time.
        let tree = self.build([self.child("r", startedAt: self.ms(Self.t0) - 10_000, ["status": "running", "runtimeMs": 300_000])])
        #expect(tree.children.first?.duration(now: Self.t0) == 300)
    }

    @Test func clockSkewNeverYieldsNegativeDurations() {
        // Gateway clock ahead of ours: startedAt is in our future.
        let future = self.ms(Self.t0) + 60_000
        let tree = self.build([
            self.child("r", startedAt: future, ["status": "running"]),
            self.child("d", startedAt: future, ["status": "done", "endedAt": .number(future + 5000)]),
        ])
        for node in tree.flattened {
            #expect(node.startedAt.map { $0 <= Self.t0 } ?? true, "clamped to now")
            #expect((node.duration(now: Self.t0) ?? 0) >= 0)
        }
    }

    @Test func invalidTimestampsAreIgnored() {
        let row = self.row("agent:main:subagent:x", ["startedAt": -5, "endedAt": 0, "runtimeMs": -1])
        #expect(row.runStartedAt == nil && row.runEndedAt == nil && row.runtime == nil)
    }

    // MARK: Seeds

    @Test func demoSeedsBuildTheLaunchPlanTree() {
        var sessions: [String: [String: JSONValue]] = [:]
        var transcripts: [String: [JSONValue]] = [:]
        let now = self.ms(Self.t0)
        DemoGateway.seedSubagents(sessions: &sessions, transcripts: &transcripts, now: now)
        let kids = DemoGateway.seededSubagents
        let rows = sessions.values.compactMap { SessionRow(.object($0)) }
        let tree = self.build(rows, root: DemoGateway.subagentParentKey)
        #expect(sessions[DemoGateway.subagentParentKey]?["label"]?.string == "Research: launch plan")
        #expect(tree.children.map(\.key) == [kids.done, kids.failed, kids.running], "oldest start first")
        #expect(tree.node(kids.done)?.children.map(\.key) == [kids.grandchild, kids.aborted])
        #expect(Dictionary(uniqueKeysWithValues: tree.flattened.map { ($0.key, $0.status) })
            == [kids.done: .done, kids.grandchild: .done, kids.aborted: .aborted, kids.running: .running, kids.failed: .error])
        #expect(tree.node(kids.grandchild)?.depth == 2 && tree.count == 5 && tree.runningCount == 1)
        #expect(tree.node(kids.done)?.duration(now: Self.t0) == 510)
        #expect(tree.node(kids.failed)?.duration(now: Self.t0) == 204)
        #expect(tree.node(kids.running)?.duration(now: Self.t0) == 360)
        #expect(tree.node(kids.failed)?.lastError?.contains("503") == true)
        #expect(tree.node(kids.running)?.agentId == "main")
        for key in [DemoGateway.subagentParentKey, kids.done, kids.grandchild, kids.aborted, kids.running, kids.failed] {
            let stamps = (transcripts[key] ?? []).compactMap { $0["timestamp"]?.double }
            #expect(!stamps.isEmpty && stamps == stamps.sorted(), "\(key) transcript in time order")
        }
    }
}
