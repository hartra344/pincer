import Foundation
import Observation

extension GatewayStore {
    func recordReconciledRow(_ key: String) {
        self.listReconcile?.rows[key] = self.sessions[key]
        self.listReconcile?.deleted.removeValue(forKey: key)
    }

    func isCurrent(_ epoch: Int) -> Bool {
        !Task.isCancelled && epoch == self.connectionEpoch
    }

    func bootstrap(epoch: Int) async {
        #if DEBUG
        defer {
            if self.isCurrent(epoch) { self.observedBootstrapFinishedEpoch = epoch }
        }
        #endif
        self.bootstrapped = false
        self.setSessionListReady(false)
        self.listReconcile = ListReconcile()
        async let agents = try? self.connection.request("agents.list", [:])
        async let subscribed = try? self.connection.request(
            "sessions.subscribe",
            .object(self.listParams),
            timeout: 30)
        let agentsResult = await agents
        let subscribeResult = await subscribed
        guard self.isCurrent(epoch) else { return }
        if let agentsResult { self.applyAgents(agentsResult) }
        if let list = subscribeResult?["list"] {
            self.applySnapshot(list)
            let trailing = self.listReconcile?.needsTrailingRefresh ?? false
            self.listReconcile = trailing ? ListReconcile() : nil
            if trailing {
                self.refreshTask?.cancel()
                await self.refreshSessions()
                let invalidatedAgain = self.listReconcile?.needsTrailingRefresh ?? false
                self.listReconcile = nil
                if invalidatedAgain { self.scheduleRefresh() }
                guard self.isCurrent(epoch) else { return }
            }
        } else {
            self.listReconcile = nil
            await self.refreshSessions()
            guard self.isCurrent(epoch) else { return }
        }
        if let pending = try? await self.connection.request("exec.approval.list", [:]) {
            guard self.isCurrent(epoch) else { return }
            let items = pending["approvals"]?.array ?? pending["items"]?.array ?? pending.array ?? []
            self.approvals = items.compactMap(ExecApproval.init)
        }
        await self.refreshQuestions()
        guard self.isCurrent(epoch) else { return }
        self.bootstrapped = true
        self.setup.connected()
        Task { await PushRegistrar.shared.sync(self) }
        self.dumpSessionShapesIfRequested()
        Task { await self.loadConfiguredServerNames() }
        // Preference reads can restore remote bookmarks; reconcile deleted chats afterwards.
        // Both operations stay in the background so opening the chat never waits for them.
        #if DEBUG
        let beforeReconciliation = self.beforeBootstrapReconciliation
        let background = Task {
            defer {
                if self.observedBootstrapBackground?.epoch == epoch { self.observedBootstrapBackground = nil }
                if self.isCurrent(epoch) { self.observedBackgroundFinishedEpoch = epoch }
            }
            await self.pullBootstrapPrefs(epoch: epoch)
            await beforeReconciliation?()
            await self.reconcileOrphanedTranscripts(epoch: epoch)
        }
        self.observedBootstrapBackground = (epoch, background)
        self.lastObservedBackground = (epoch, background)
        #else
        Task {
            await self.pullBootstrapPrefs(epoch: epoch)
            await self.reconcileOrphanedTranscripts(epoch: epoch)
        }
        #endif
        Task { await self.loadGroups() }
        // Only pick a chat on the first connect: on iPhone, going back to the sidebar clears the
        // selection, and re-selecting on every reconnect would push a chat the user left.
        let selectionGone = self.selectedKey.map { self.sessions[$0] == nil } ?? false
        if selectionGone || (self.selectedKey == nil && !self.didPickInitialChat) {
            self.selectedKey = self.defaultSessionKey
        }
        self.didPickInitialChat = true
        // Every other chat lost its subscription with the old socket; it reloads when opened.
        let warm = self.warmKeys(includingLive: true)
        for chat in self.chats.values where !warm.contains(chat.sessionKey) { chat.markStale() }
        // The open chat first, so it isn't stuck behind the others.
        if let key = self.selectedKey, let open = self.chats[key] {
            await open.load(force: true)
            guard self.isCurrent(epoch) else { return }
        }
        for chat in self.chats.values where chat.sessionKey != self.selectedKey && warm.contains(chat.sessionKey) {
            await chat.load(force: true)
            guard self.isCurrent(epoch) else { return }
        }
        self.startPrefetch()
        self.reconcileMessageIndex()
        self.enforceChatBudget()
        await self.flushOutbox()
    }
}
