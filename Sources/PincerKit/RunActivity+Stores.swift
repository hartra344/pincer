import Foundation

// Feeds `RunActivityCoordinator` from the stores. All of it is a no-op until the iOS app installs a host.

extension ChatStore {
    /// Brings this chat's Live Activity in step with its run. Called when the run starts, ends, changes
    /// tool, waits for approval or finishes; never for streamed text.
    func refreshRunActivity() {
        let coordinator = RunActivityCoordinator.shared
        guard coordinator.isActive, !self.headless, let gateway = self.gateway else { return }
        coordinator.refresh(
            gatewayId: self.gatewayId, sessionKey: self.sessionKey, signals: self.avatarSignals,
            startedAt: self.live?.startedAt ?? Date(),
            eligible: self.isEligibleForRunActivity(),
            identity: self.runActivityIdentity(gateway))
    }

    /// A turn gets one only once its stream has begun here (never from a session row alone, which can
    /// still say "running" just after the turn ended). Helper runs, automations and slash commands you've
    /// hidden from the sidebar, and archived chats, don't get one.
    private func isEligibleForRunActivity() -> Bool {
        guard self.live != nil else { return false }
        guard let row = self.sessionRow ?? self.gateway?.sessions[self.sessionKey] else { return true }
        return BackgroundRefreshFilter.load(gatewayId: self.gatewayId).notifies(row)
    }

    private func runActivityIdentity(_ gateway: GatewayStore) -> RunActivityIdentity {
        let row = self.sessionRow ?? gateway.sessions[self.sessionKey]
        let agentId = row?.agentId ?? self.agentId ?? SessionKey.agentId(from: self.sessionKey) ?? "main"
        let agent = gateway.agent(agentId)
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = PincerRoute(
            target: Notifier.Target(gatewayId: self.gatewayId, sessionKey: self.sessionKey),
            isDemo: gateway.profile.isDemo).url
        return RunActivityIdentity(
            gatewayId: self.gatewayId, sessionKey: self.sessionKey, agentName: name.isEmpty ? agent.id : name,
            chatTitle: row?.title ?? SessionKey.shortName(self.sessionKey), emoji: agent.emoji, url: url)
    }
}

extension GatewayStore {
    /// An approval appeared or went away: the chat it belongs to may start or stop waiting.
    func approvalsChanged(from old: [ExecApproval]) {
        guard RunActivityCoordinator.shared.isActive else { return }
        let keys = Set(old.compactMap(\.sessionKey)).symmetricDifference(self.approvals.compactMap(\.sessionKey))
        for key in keys { self.chats[key]?.refreshRunActivity() }
    }
}
