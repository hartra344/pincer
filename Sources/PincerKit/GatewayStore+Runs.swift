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

    /// Ends timeline lanes whose session row no longer runs, in case their end event was missed.
    func settleRunTimeline() {
        var changed = false
        for key in self.runTimelineState.runningSessionKeys {
            guard let row = self.sessions[key], let status = RunLaneStatus(settled: row.subagentStatus),
                  let asOf = row.activityDate else { continue }
            // A row with no run fields says nothing; only an explicit "not running" settles it.
            if row.subagentStatus == .idle, row.raw["hasActiveRun"]?.bool != false { continue }
            changed = self.runTimelineState.settle(sessionKey: key, status: status, asOf: asOf) || changed
        }
        if changed { self.runTimelineRevision &+= 1 }
    }

    func recordRunActivity(_ event: GatewayEvent, sessionKey: String? = nil) {
        if self.runTimelineState.apply(event: event, receivedAt: Date(), sessionKey: sessionKey) {
            self.runTimelineRevision &+= 1
        }
    }
}

extension RunLaneStatus {
    /// How a lane ends when its session row reports `status` and it never saw its own end;
    /// nil while the row still runs (or can't say).
    public init?(settled status: SubagentStatus) {
        switch status {
        case .running, .unknown: return nil
        case .done, .idle: self = .done
        case .error: self = .error
        case .aborted: self = .aborted
        }
    }
}
