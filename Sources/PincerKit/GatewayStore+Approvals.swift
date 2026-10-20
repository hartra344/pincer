import Foundation
import Observation

extension GatewayStore {
    /// From the chat banner. Same guard, stale handling and cleanup as a notification action; a
    /// problem shows in `lastError`.
    @discardableResult
    public func resolveApproval(_ approval: ExecApproval, decision: String) async -> ApprovalOutcome {
        await self.resolveApproval(id: approval.id, decision: decision)
    }

    /// Sends `exec.approval.resolve` once per approval, from a notification action (which may have
    /// launched the app) or the banner. A socket that went stale while suspended is replaced first.
    /// The decision must leave within `connectWithin` seconds of the call (wall clock, so time spent
    /// suspended counts) and the RPC gets `timeout`; past that, or if the calling task is cancelled,
    /// it's dropped (`.unreachable`), never sent later. A second call for an approval that's in
    /// flight or already settled here sends nothing and returns `.alreadyHandled`.
    @discardableResult
    public func resolveApproval(
        id: String, decision: String, connectWithin: Double = 15, timeout: Double = 10) async -> ApprovalOutcome
    {
        let deadline = Date().addingTimeInterval(connectWithin)
        if self.answeredApprovals.contains(id) { return .alreadyHandled }
        if let inFlight = self.resolvingApprovals[id] {
            _ = await inFlight.value
            return .alreadyHandled
        }
        let outcome: ApprovalOutcome
        if self.approvals.first(where: { $0.id == id })?.isExpired() == true {
            outcome = .expired
        } else {
            let connection = self.connection
            let task = Task { () -> ApprovalOutcome in
                await Self.send(id: id, decision: decision, on: connection, deadline: deadline, timeout: timeout)
            }
            self.resolvingApprovals[id] = task
            outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            self.resolvingApprovals[id] = nil
        }
        if outcome.removesApproval { self.answeredApprovals.insert(id) }
        if outcome.removesApproval {
            self.approvals.removeAll { $0.id == id }
            await self.notifier?.removeApproval(gatewayId: self.id, id: id)
        } else if let message = outcome.inAppMessage(gatewayName: self.profile.name) {
            self.lastError = message
        }
        return outcome
    }

    /// Resolved elsewhere (or here): its delivered notifications go too.
    func clearApprovalNotifications(_ id: String) {
        guard let notifier = self.notifier else { return }
        let gatewayId = self.id
        Task { await notifier.removeApproval(gatewayId: gatewayId, id: id) }
    }

    private static func send(
        id: String, decision: String, on connection: GatewayConnection, deadline: Date, timeout: Double) async -> ApprovalOutcome
    {
        await connection.reconnectNow()
        while await !connection.isReady {
            guard Date() < deadline, !Task.isCancelled else { return .unreachable }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Re-checked right before sending: a suspension during the wait mustn't let a stale allow through.
        guard Date() < deadline, !Task.isCancelled else { return .unreachable }
        do {
            _ = try await connection.request(
                "exec.approval.resolve", ["id": .string(id), "decision": .string(decision)], timeout: timeout)
            return .resolved
        } catch {
            return ApprovalOutcome.classify(error)
        }
    }

    /// Pushes name an agent's main chat as `agent:<id>:main`; the Gateway's main key may differ.
    public func resolveSessionKey(_ key: String) -> String {
        guard self.sessions[key] == nil else { return key }
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "agent", parts[2] == "main",
              let main = self.sessions.values.first(where: { $0.isMain && $0.agentId == parts[1] })
        else { return key }
        return main.key
    }
}
