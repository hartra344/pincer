import Foundation

// MARK: Subagent tree and run timeline

extension GatewayStore {
    /// Activity lanes for runs streamed since this app connected.
    public var runTimeline: RunTimeline {
        _ = self.runTimelineRevision
        return self.runTimelineState
    }

    /// Helper sessions under `rootKey`, rebuilt only when the session rows or connection change.
    public func subagentTree(rootKey: String) -> SubagentTree {
        let rows = self.sessions
        let connected = self.state.isConnected
        let cacheKey = "\(connected ? 1 : 0)|\(rootKey)"
        if let cached = self.subagentTrees[cacheKey] { return cached }
        let tree = SubagentTree.build(rows: rows.values, rootKey: rootKey, now: Date(), connected: connected)
        self.subagentTrees[cacheKey] = tree
        return tree
    }

    /// Whether `sessionKey` has helpers or streamed runs worth showing in the Runs panel.
    public func hasRuns(sessionKey: String) -> Bool {
        !self.subagentTree(rootKey: sessionKey).isEmpty || self.runTimeline.latestLane(sessionKey: sessionKey) != nil
    }

    /// A run's title: its label when it has one, else its agent's name.
    public func runTitle(_ sessionKey: String) -> String {
        guard let row = self.sessions[sessionKey] else { return SessionKey.shortName(sessionKey) }
        return row.title == SessionKey.shortName(sessionKey) ? self.agent(row.agentId).name : row.title
    }

    /// The closest ancestor of `sessionKey` this Gateway lists, for a "Parent" breadcrumb.
    public func parentSessionKey(of sessionKey: String) -> String? {
        guard let row = self.sessions[sessionKey] else { return nil }
        return row.parentCandidates.first { self.sessions[$0] != nil && $0 != sessionKey }
    }

    func recordRunActivity(_ event: GatewayEvent, sessionKey: String? = nil) {
        if self.runTimelineState.apply(event: event, receivedAt: Date(), sessionKey: sessionKey) {
            self.runTimelineRevision &+= 1
        }
    }
}
