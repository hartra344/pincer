import Foundation

/// The outbox: messages composed offline (or that failed) wait here, per Gateway, and go out in
/// order once the Gateway is back. Every resend reuses the entry's idempotency key, so the
/// Gateway's `chat.send` dedupe answers a repeat of a send that already landed from its cache
/// instead of running it again.
extension GatewayStore {
    /// Unsent messages across this Gateway's chats (queued, sending or failed).
    public var unsentCount: Int { self.outbox.count }

    /// Adds an entry as if it had been composed here: demo seeds and checks use it to show a
    /// queued or failed message. Nothing is sent until a flush picks it up (failed ones wait
    /// for Retry).
    public func injectOutboxEntry(_ entry: OutboxEntry) {
        self.outbox.enqueue(entry)
    }

    /// Discards every unsent message of this Gateway (Settings → Storage).
    public func discardOutbox() {
        self.outboxAttachments = [:]
        self.outbox = Outbox(entries: self.outbox.entries.filter { $0.state == .sending })
    }

    func updateOutbox(_ change: (inout Outbox) -> Void) {
        var outbox = self.outbox
        change(&outbox)
        self.outbox = outbox
    }

    /// Reads the saved outbox once; anything left `.sending` by a killed app goes back to the queue.
    func loadOutbox() async {
        guard !self.outboxLoaded else { return }
        self.outboxLoaded = true
        guard !self.profile.isDemo else {
            // The demo keeps its outbox in memory, seeded with a failed message to retry.
            for entry in DemoGateway.seedOutbox() where self.outbox.entry(id: entry.id) == nil {
                self.injectOutboxEntry(entry)
            }
            return
        }
        let (saved, _) = await OutboxStore.load(gatewayId: self.id)
        guard var saved, !saved.isEmpty else { return }
        saved.recoverAfterLaunch()
        // Anything composed while the file was being read goes after what was saved.
        for entry in self.outbox.entries where saved.entry(id: entry.id) == nil { saved.enqueue(entry) }
        self.outbox = saved
        if self.state.isConnected, self.hello != nil { await self.flushOutbox() }
    }

    func outboxChanged(from old: Outbox) {
        let changed = Set(old.entries.map(\.sessionKey) + self.outbox.entries.map(\.sessionKey)).filter {
            old.entries(for: $0) != self.outbox.entries(for: $0)
        }
        for key in changed {
            self.chats[key]?.syncOutbox(self.outbox.entries(for: key))
        }
        for id in self.outboxAttachments.keys where self.outbox.entry(id: id) == nil {
            self.outboxAttachments.removeValue(forKey: id)
        }
        guard self.outboxLoaded, !self.profile.isDemo, old.persistable != self.outbox.persistable else { return }
        let previous = self.outboxSaveTask
        let outbox = self.outbox
        let id = self.id
        self.outboxSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            await OutboxStore.save(outbox, gatewayId: id)
        }
    }

    /// Drops entries whose send already shows in the transcript.
    func reconcileOutbox(committedKeys: Set<String>) {
        guard !committedKeys.isEmpty, self.outbox.entries.contains(where: { committedKeys.contains($0.id) }) else { return }
        self.outbox.reconcile(committedKeys: committedKeys)
    }

    /// Sends every queued message, oldest first and in order per chat. One flush at a time; a
    /// flush stops when the connection drops (what's left stays queued for the next one).
    public func flushOutbox() async {
        guard !self.outboxFlushing else { return }
        self.outboxFlushing = true
        defer { self.outboxFlushing = false }
        var checked: Set<String> = []
        while self.state.isConnected, self.hello != nil, let entry = self.outbox.nextToSend() {
            let chat = self.chat(for: entry.sessionKey)
            // A send that may have landed before (the app quit or the socket dropped mid-send)
            // is checked against the transcript first, past the Gateway's dedupe window too.
            if entry.attempts > 0, checked.insert(entry.sessionKey).inserted {
                await chat.load(force: chat.hasLoaded)
                guard self.outbox.entry(id: entry.id)?.state == .queued else { continue }
            }
            _ = await chat.deliver(entry)
        }
    }
}
