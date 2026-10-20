import Foundation
import Observation

extension ChatStore {
    // MARK: Capped messages

    /// History caps each text field (8,000 chars by default) and flags the message; like the
    /// Control UI, fetch the full copy with `chat.message.get` and swap it in.
    func recoverCappedMessages(fromAcceptedMessage: Bool = false) {
        self.cappedRecoveryPending = false
        var items = self.items
        var substituted = false
        var refreshedRows: [(item: ChatItem, fallbackIndex: Int)] = []
        var missing: [String] = []
        for index in items.indices {
#if DEBUG
            // Keep the diagnostic bounded even if a long-lived store performs many scans.
            if self.cappedRecoveryRowsVisitedForTesting < 100_000 {
                self.cappedRecoveryRowsVisitedForTesting += 1
            }
            if fromAcceptedMessage, self.acceptedEventRecoveryRowsVisitedForTesting < 100_000 {
                self.acceptedEventRecoveryRowsVisitedForTesting += 1
            }
#endif
            guard items[index].isCapped else { continue }
            guard let messageId = items[index].transcriptId else { continue }
            if let full = self.fullMessages[messageId] {
                let restored = Self.restoring(full, over: items[index])
                items[index] = restored
                if self.liveReplyItemTokens[restored.id] != nil || self.liveReplyCandidate?.id == restored.id {
                    refreshedRows.append((item: restored, fallbackIndex: index))
                }
                substituted = true
            } else if self.recoveryAttempted.insert(messageId).inserted {
                missing.append(messageId)
            }
        }
        if substituted {
            self.items = items
            self.refreshLiveReplyPreparations(matching: refreshedRows)
        }
        for messageId in missing {
            Task { [weak self] in await self?.fetchFullMessage(messageId) }
        }
    }

    func fetchFullMessage(_ messageId: String) async {
        guard let gateway else {
            self.recoveryAttempted.remove(messageId)
            if !self.isDehydrated { self.cappedRecoveryPending = true }
            return
        }
#if DEBUG
        let testRequest = self.cappedMessageRecoveryRequestForTesting
        guard gateway.state.isConnected || testRequest != nil else {
            self.recoveryAttempted.remove(messageId)
            if !self.isDehydrated { self.cappedRecoveryPending = true }
            return
        }
#else
        guard gateway.state.isConnected else {
            self.recoveryAttempted.remove(messageId)
            if !self.isDehydrated { self.cappedRecoveryPending = true }
            return
        }
#endif
        var params = self.params(keyName: "sessionKey")
        params["messageId"] = .string(messageId)
        params["maxChars"] = .number(Double(self.fullMessageMaxChars))
        let result: JSONValue
        do {
#if DEBUG
            if let testRequest {
                result = try await testRequest(messageId)
            } else {
                result = try await gateway.connection.request("chat.message.get", .object(params), timeout: 30)
            }
#else
            result = try await gateway.connection.request("chat.message.get", .object(params), timeout: 30)
#endif
        } catch {
            // Transport failures retry on the next recovery pass; Gateway refusals below don't.
            self.recoveryAttempted.remove(messageId)
            if !self.isDehydrated { self.cappedRecoveryPending = true }
            return
        }
        guard result["ok"]?.bool == true, let message = result["message"] else { return }
        let parsed = await Task.detached(priority: .utility) {
            ChatItem(message, fallbackIndex: 0, projectLegacyLocation: true)
        }.value
        guard let full = parsed, !full.isCapped else { return }
        self.fullMessages[messageId] = full
        guard let index = self.items.firstIndex(where: { $0.transcriptId == messageId && $0.isCapped }) else { return }
        let restored = Self.restoring(full, over: self.items[index])
        self.items[index] = restored
        self.refreshLiveReplyPreparations(matching: [(item: restored, fallbackIndex: index)])
    }

    /// The full copy with the capped row's identity, so the row keeps its place and scroll anchor.
    static func restoring(_ full: ChatItem, over capped: ChatItem) -> ChatItem {
        var item = full
        item.id = capped.id
        item.isPending = capped.isPending
        item.idempotencyKey = full.idempotencyKey ?? capped.idempotencyKey
        return item
    }

    func scheduleReload(after delay: Duration = .milliseconds(250)) {
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load(force: true)
        }
    }
}
