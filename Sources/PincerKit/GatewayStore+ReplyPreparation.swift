import Foundation

extension GatewayStore {
    func wakeReplyAcceptanceWaiters() {
        let waiting = Array(self.replyAcceptanceWaiters.values)
        self.replyAcceptanceWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Every send waits for its session's earlier preview reservations before it can be accepted.
    /// Queue deletion and shutdown wake waiters; no task can recreate a removed reservation.
    func waitForReplyAcceptance(id: String, lifecycle: Int) async -> Bool {
        while self.outbox.hasPreparingReply(beforeOrAt: id) {
            guard !Task.isCancelled, lifecycle == self.replySendLifecycle,
                  self.outbox.entry(id: id) != nil else { return false }
            guard self.replyAcceptanceWaiters.count < 32 else { return false }
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { self.replyAcceptanceWaiters[token] = continuation }
                }
            } onCancel: {
                Task { @MainActor in self.replyAcceptanceWaiters.removeValue(forKey: token)?.resume() }
            }
        }
        return !Task.isCancelled && lifecycle == self.replySendLifecycle && self.outbox.entry(id: id) != nil
    }
}
