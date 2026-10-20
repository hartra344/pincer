import Foundation
import Observation

extension GatewayStore {
    var listParams: [String: JSONValue] {
        ["limit": 300, "ownerFirst": true, "includeLastMessage": true, "archived": self.showArchived ? "all" : false]
    }

    public func refreshSessions() async {
        // A row event can reach the main actor before this response even though the Gateway read the
        // list first (#1022), so row changes seen meanwhile are kept over the snapshot.
        if self.listReconcile == nil { self.listReconcile = ListReconcile(ownedByRefresh: true) }
        self.refreshesInFlight += 1
        defer {
            self.refreshesInFlight -= 1
            if self.refreshesInFlight == 0, let reconcile = self.listReconcile, reconcile.ownedByRefresh {
                self.listReconcile = nil
                if reconcile.needsTrailingRefresh { self.scheduleRefresh() }
            }
        }
        guard let list = try? await self.connection.request("sessions.list", .object(self.listParams), timeout: 30) else {
            return
        }
        self.applySnapshot(list)
    }

    func setSessionListReady(_ ready: Bool) {
        guard self.sessionListReady != ready else { return }
        self.sessionListReady = ready
        self.routeCandidatesDidChange?()
    }

    func applySnapshot(_ list: JSONValue) {
        let previous = Set(self.sessions.values.filter { !$0.isPlaceholder }.map(\.key))
        var next: [String: SessionRow] = [:]
        for row in list["sessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            next[row.key] = row
        }
        if let reconcile = self.listReconcile {
            for (key, sessionId) in reconcile.deleted where sessionId == nil || next[key]?.sessionId == sessionId {
                next.removeValue(forKey: key)
            }
            for (key, row) in reconcile.rows where reconcile.deleted[key] == nil { next[key] = row }
        }
        self.addAgentHomes(to: &next)
        self.sessions = next
        self.hasSessionListSnapshot = true
        self.setSessionListReady(true)
        self.scheduleSpotlightReindex()
        if let defaults = list["defaults"], let model = defaults["model"]?.text {
            self.defaultModelRef = ModelRef.qualified(model, provider: defaults["modelProvider"]?.text)
        }
        if let defaults = list["defaults"] {
            self.defaultContextTokens = defaults["contextTokens"]?.int.flatMap { $0 > 0 ? $0 : nil }
        }
        // Sessions deleted while we weren't listening (e.g. across a reconnect) lose their cache too.
        let dropped = previous.subtracting(next.keys)
        if !dropped.isEmpty { Task { await self.forgetVanishedSessions(dropped) } }
    }

    func scheduleRefresh() {
        if self.listReconcile != nil {
            self.listReconcile?.needsTrailingRefresh = true
            return
        }
        self.refreshTask?.cancel()
        self.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshSessions()
        }
    }

    var defaultSessionKey: String? {
        let main = self.sessions.values.first { $0.isMain && $0.agentId == self.defaultAgentId }
        return main?.key ?? self.sortedRows.first?.key
    }
}
