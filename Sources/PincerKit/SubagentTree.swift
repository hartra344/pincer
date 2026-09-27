import Foundation

/// Where a helper run stands, from its `sessions.list` row.
public enum SubagentStatus: String, Sendable, Hashable, CaseIterable {
    case running, done, error, aborted
    /// The row says nothing about a run (e.g. a branched chat nobody has run yet).
    case idle
    /// Last seen running, but the Gateway is disconnected so the outcome isn't known.
    case unknown

    public var label: String {
        switch self {
        case .running: "Running"
        case .done: "Done"
        case .error: "Failed"
        case .aborted: "Stopped"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }
}

extension SessionRow {
    /// Mirrors the Gateway's projection: `status` is `running | done | failed | killed | timeout`
    /// (`interrupted` is reported as `failed`), with `subagentRunState` and `hasActiveRun` for live runs.
    public var subagentStatus: SubagentStatus {
        let status = self.status?.lowercased()
        let runState = self.raw["subagentRunState"]?.text
        if self.hasActiveRun || runState == "active" || status == "running" { return .running }
        if status == "killed" || self.raw["abortedLastRun"]?.bool == true { return .aborted }
        if let status, ["failed", "timeout", "interrupted", "error"].contains(status) { return .error }
        if status == "done" { return .done }
        if self.lastRunError != nil { return .error }
        if self.runEndedAt != nil { return .done }
        if runState == "interrupted" { return .error }
        return .idle
    }

    public var runStartedAt: Date? { Self.date(self.raw["startedAt"]) }
    public var runEndedAt: Date? { Self.date(self.raw["endedAt"]) }
    /// Accumulated run time the Gateway reports (`runtimeMs`), across follow-up runs.
    public var runtime: TimeInterval? {
        guard let ms = self.raw["runtimeMs"]?.double, ms.isFinite, ms >= 0 else { return nil }
        return ms / 1000
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let ms = value?.double, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// One session in a subagent tree.
public struct SubagentNode: Identifiable, Hashable, Sendable {
    public let key: String
    public var id: String { self.key }
    public let title: String
    public let agentId: String
    public let status: SubagentStatus
    public let startedAt: Date?
    public let endedAt: Date?
    public let lastActivity: Date?
    public let lastError: String?
    public let runtime: TimeInterval?
    /// 1 for a direct child of the root.
    public let depth: Int
    /// Oldest first.
    public internal(set) var children: [SubagentNode]

    /// Gateway-reported runtime when known, else start to end (or `now` while running).
    public func duration(now: Date) -> TimeInterval? {
        if let runtime, self.status != .running { return runtime }
        guard let startedAt else { return self.runtime }
        let end = self.status == .running ? now : (self.endedAt ?? self.lastActivity ?? now)
        return max(self.runtime ?? 0, end.timeIntervalSince(startedAt), 0)
    }

    public var descendantCount: Int { self.children.reduce(self.children.count) { $0 + $1.descendantCount } }
}

/// The helper runs a chat spawned, nested by `spawnedBy` / `parentSessionKey`.
public struct SubagentTree: Hashable, Sendable {
    public static let maxDepth = 8
    public static let maxNodes = 500

    public let rootKey: String
    public let children: [SubagentNode]

    public init(rootKey: String, children: [SubagentNode] = []) {
        self.rootKey = rootKey
        self.children = children
    }

    public var isEmpty: Bool { self.children.isEmpty }
    public var count: Int { self.flattened.count }
    public var runningCount: Int { self.flattened.count { $0.status == .running } }

    /// Depth first, parents before their children.
    public var flattened: [SubagentNode] {
        var out: [SubagentNode] = []
        func walk(_ nodes: [SubagentNode]) {
            for node in nodes {
                out.append(node)
                walk(node.children)
            }
        }
        walk(self.children)
        return out
    }

    public func node(_ key: String) -> SubagentNode? { self.flattened.first { $0.key == key } }

    /// Builds the tree under `rootKey` in O(n). Rows link to their parent through
    /// `SessionRow.parentCandidates` (so chats merely started from main don't nest), and cycles,
    /// `maxDepth` and `maxNodes` bound the walk. `now` clamps timestamps from skewed clocks; with
    /// `connected: false`, running rows read as `.unknown`.
    public static func build(rows: some Sequence<SessionRow>, rootKey: String, now: Date,
                             connected: Bool = true) -> SubagentTree
    {
        var byParent: [String: [SessionRow]] = [:]
        var keys = Set<String>()
        var all: [SessionRow] = []
        for row in rows where keys.insert(row.key).inserted {
            all.append(row)
        }
        keys.insert(rootKey)
        for row in all {
            let candidates = row.parentCandidates
            guard let parent = candidates.first(where: { keys.contains($0) }) ?? candidates.last,
                  parent != row.key else { continue }
            byParent[parent, default: []].append(row)
        }
        var visited: Set<String> = [rootKey]
        var budget = self.maxNodes

        func clamp(_ date: Date?) -> Date? { date.map { min($0, now) } }
        func startKey(_ row: SessionRow) -> Double {
            row.raw["startedAt"]?.double ?? row.raw["createdAt"]?.double ?? row.activityMs
        }
        func nodes(under parent: String, depth: Int) -> [SubagentNode] {
            guard depth <= self.maxDepth, let rows = byParent[parent] else { return [] }
            var out: [SubagentNode] = []
            for row in rows.sorted(by: { (startKey($0), $0.key) < (startKey($1), $1.key) }) {
                guard budget > 0, visited.insert(row.key).inserted else { continue }
                budget -= 1
                var status = row.subagentStatus
                if !connected, status == .running { status = .unknown }
                out.append(SubagentNode(
                    key: row.key,
                    title: row.title,
                    agentId: row.agentId,
                    status: status,
                    startedAt: clamp(row.runStartedAt),
                    endedAt: clamp(row.runEndedAt),
                    lastActivity: clamp(row.activityDate),
                    lastError: row.lastRunError,
                    runtime: row.runtime,
                    depth: depth,
                    children: nodes(under: row.key, depth: depth + 1)))
            }
            return out
        }
        return SubagentTree(rootKey: rootKey, children: nodes(under: rootKey, depth: 1))
    }
}
