import Foundation
import Observation

extension GatewayStore {
    func applyAgents(_ result: JSONValue) {
        self.agents = result["agents"]?.array?.compactMap(AgentSummary.init) ?? []
        self.defaultAgentId = result["defaultId"]?.text ?? self.agents.first?.id ?? "main"
        self.agentMainKey = result["mainKey"]?.text ?? "main"
        self.agentScope = result["scope"]?.text
        var next = self.sessions
        self.addAgentHomes(to: &next)
        if next != self.sessions { self.sessions = next }
        self.recordAvatarSeeds()
        Self.agentsDidLoad?()
    }

    /// The Gateway only lists sessions it has stored, and an agent's home chat isn't stored until
    /// its first message, so a new agent would have no chats and no sidebar section. Like the
    /// Control UI, list each agent's home chat anyway; it opens empty and the first send creates
    /// it. Placeholders for agents that are gone are dropped.
    func addAgentHomes(to rows: inout [String: SessionRow]) {
        let agentIds = Set(self.agents.filter { !$0.isSystem }.map(\.id))
        for (key, row) in rows where row.isPlaceholder && !agentIds.contains(row.agentId) {
            rows.removeValue(forKey: key)
        }
        guard self.agentScope != "global" else { return }
        let mainAgents = Set(rows.values.filter { $0.isMain && !$0.isPlaceholder }.map(\.agentId))
        for agent in self.agents where !agent.isSystem && !mainAgents.contains(agent.id) {
            let key = "agent:\(agent.id):\(self.agentMainKey)"
            guard rows[key] == nil,
                  let row = SessionRow(.object([
                      "key": .string(key), "agentId": .string(agent.id), "isMain": true, "kind": "direct",
                      SessionRow.placeholderField: true,
                  ]))
            else { continue }
            rows[key] = row
        }
    }

    /// Re-fetches `agents.list` so the sidebar and pickers show created, renamed and deleted agents.
    public func reloadAgents() async {
        guard self.state.isConnected, let result = try? await self.connection.request("agents.list", [:]) else { return }
        self.applyAgents(result)
    }

    /// After an agent mutation: the roster, and the config (its agent entries and bindings changed).
    func agentsDidChange() async {
        await self.reloadAgents()
        if self.settings.hasLoaded { await self.settings.reloadConfig() }
    }
}
