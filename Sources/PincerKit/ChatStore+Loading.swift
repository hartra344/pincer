import Foundation
import Observation

extension ChatStore {
    /// Installs a bulk-restored transcript snapshot. Recovery still runs on its existing next pass.
    func replaceRecoveryItems(_ items: [ChatItem]) {
        self.items = items
        self.cappedRecoveryPending = true
    }

    enum ForwardedRefreshPageDisposition: Equatable {
        case more(nextOffset: Int)
        case complete(nextOffset: Int)
        case abort
    }

    /// Validates paging progress before a sender refresh can be considered authoritative.
    nonisolated static func forwardedRefreshPageDisposition(messageCount: Int?, reportedHasMore: Bool?,
                                                             requestedOffset: Int, returnedOffset: Int?,
                                                             fallbackLimit: Int) -> ForwardedRefreshPageDisposition
    {
        guard let messageCount else { return .abort }
        if messageCount == 0 {
            return reportedHasMore == true
                ? .abort
                : .complete(nextOffset: returnedOffset ?? requestedOffset)
        }
        let nextOffset = returnedOffset ?? (requestedOffset + messageCount)
        guard nextOffset > requestedOffset else { return .abort }
        let hasMore = reportedHasMore ?? (messageCount >= fallbackLimit)
        return hasMore ? .more(nextOffset: nextOffset) : .complete(nextOffset: nextOffset)
    }

    @inline(__always)
    func recordForwardedRefresh(_ phase: ForwardedSenderRefreshDiagnostics.Phase) {
        ForwardedSenderRefreshDiagnostics.record(gatewayID: self.gatewayId, sessionKey: self.sessionKey, phase: phase)
    }

    @inline(__always)
    func recordForwardedRefreshAbort(_ reason: ForwardedSenderRefreshDiagnostics.AbortReason,
                                              offset: Int?, scanned: Int) {
        self.recordForwardedRefresh(.scanAborted(reason: reason, offset: offset, scanned: scanned))
    }

    static func diagnosticDisposition(_ disposition: ForwardedRefreshPageDisposition)
        -> ForwardedSenderRefreshDiagnostics.Disposition
    {
        switch disposition {
        case .more: .more
        case .complete: .complete
        case .abort: .abort
        }
    }

    /// True when the message subscription was sent on the current connection.
    public var isSubscribed: Bool {
        guard let gateway else { return false }
        return self.subscribedEpoch == gateway.connectionEpoch
    }

    /// The next `load()` refetches history and resubscribes even if not forced.
    public func markStale() { self.stale = true }

    public func releaseSubscription() async {
        let wasSubscribed = self.isSubscribed
        self.subscribedEpoch = nil
        self.stale = true
        if wasSubscribed, let gateway, gateway.state.isConnected {
            _ = try? await gateway.connection.request(
                "sessions.messages.unsubscribe",
                .object(self.unsubscribeParams()),
                timeout: 10)
        }
    }

    public func load(force: Bool = false) async {
        await self.load(force: force, feedbackAuthority: nil)
    }

    func load(force: Bool, feedbackAuthority: MessageEditFeedbackAuthority?) async {
        self.isDehydrated = false
        await self.restoreDraft()
        await self.restoreFromCache()
        guard let gateway, gateway.state.isConnected else { return }
        if self.forwardedSenderRefreshPending, !self.headless {
            gateway.startHeadlessFill(sessionKey: self.sessionKey, agentId: self.agentId)
        }
        if self.hasLoaded, !force, !self.stale { return }
        if !force, let running = self.loadTask {
            await Self.value(of: running)
            // The caller that started it went away mid-fetch; this one still wants the history.
            if running.isCancelled, !Task.isCancelled { await self.load(force: false, feedbackAuthority: feedbackAuthority) }
            return
        }
        self.loadGeneration += 1
        let generation = self.loadGeneration
        // Waiters await this task; only the caller that started it passes its cancellation on.
        let task = Task {
            await self.fetchHistory(gateway, generation: generation, feedbackAuthority: feedbackAuthority)
            if self.loadGeneration == generation { self.loadTask = nil }
        }
        self.loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Waits for `task`, but returns as soon as the caller is cancelled; `task` itself keeps running.
    private static func value(of task: Task<Void, Never>) async {
        let gate = WaiterGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Task {
                    await task.value
                    gate.resume()
                }
            }
        } onCancel: {
            gate.resume()
        }
    }

    private func fetchHistory(_ gateway: GatewayStore, generation: Int, feedbackAuthority: MessageEditFeedbackAuthority?) async {
        // Ordinary refreshes keep their existing feedback behavior unless a newer assignment
        // arrives while awaiting history. Only an explicit edit refresh also checks selection.
        let feedbackRevision = self.errorMessageRevision
        self.isLoading = !self.hasLoaded
        defer { if self.loadGeneration == generation { self.isLoading = false } }
        do {
            let epoch = gateway.connectionEpoch
            if self.subscribedEpoch != epoch {
                self.subscribedEpoch = epoch
                do {
                    try await self.subscribeToMessages(on: gateway)
                } catch is CancellationError {
                    if self.subscribedEpoch == epoch { self.subscribedEpoch = nil }
                    return
                } catch {
                    if self.subscribedEpoch == epoch { self.subscribedEpoch = nil }
                }
            }
            var params = self.params(keyName: "sessionKey")
            params["limit"] = .number(Double(self.historyLimit))
            let result = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
            #if DEBUG
            try await self.historyResponseProbe?()
            #endif
            // A newer load (a branch switch or rewind reload) owns the transcript now: this reply predates it.
            guard self.loadGeneration == generation else { return }
            let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
            guard self.loadGeneration == generation else { return }
            self.apply(history: result, parsed: parsed)
            self.hasLoaded = true
            self.stale = false
            self.loadCount += 1
            if self.errorMessageRevision == feedbackRevision && (feedbackAuthority?.isCurrent(in: self) ?? true) {
                self.errorMessage = nil
            }
            self.scheduleSave()
            self.startBackfill()
            self.refreshProgressCard()
            if !self.headless {
                Task { await self.refreshBranches() }
                Task { await self.syncReactions() }
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.loadGeneration == generation else { return } // A newer load owns the outcome now.
            if self.errorMessageRevision == feedbackRevision && (feedbackAuthority?.isCurrent(in: self) ?? true) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Brings back the draft saved on disk, unless one was started here in the meantime.
    func restoreDraft() async {
        guard !self.draftChecked, !self.headless else { return }
        self.draftChecked = true
        guard let saved = await DraftStore.load(gatewayId: self.gatewayId, sessionKey: self.sessionKey),
              !self.draftEdited
        else { return }
        self.restoringDraft = true
        self.draft = saved
        self.restoringDraft = false
    }

    func scheduleDraftSave(after delay: Duration = .milliseconds(400)) {
        let previous = self.draftSaveTask
        previous?.cancel()
        let draft = self.draft
        self.draftSaveTask = Task { [gatewayId, sessionKey] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            // Saves land in order, so an older draft never overwrites a newer one.
            await previous?.value
            await DraftStore.save(draft, gatewayId: gatewayId, sessionKey: sessionKey)
        }
    }

    /// Writes a pending draft now, e.g. before the app is suspended.
    public func flushDraft() async {
        guard self.draftSaveTask != nil else { return }
        self.scheduleDraftSave(after: .zero)
        await self.draftSaveTask?.value
    }

}

/// Resumes its continuation exactly once, from whichever of completion or cancellation comes first.
private final class WaiterGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = self.lock.withLock {
            if self.done { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let pending = self.lock.withLock {
            self.done = true
            defer { self.continuation = nil }
            return self.continuation
        }
        pending?.resume()
    }
}
