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

    static func uploadPolicyKey(_ id: UUID) -> String { "pincer.uploadPolicy.\(id.uuidString)" }

    static func savedUploadPolicy(in defaults: UserDefaults, id: UUID) -> UploadPolicy? {
        defaults.data(forKey: Self.uploadPolicyKey(id)).flatMap { try? JSONDecoder().decode(UploadPolicy.self, from: $0) }
    }

    func saveUploadPolicy(_ policy: UploadPolicy) {
        guard policy != self.lastUploadPolicy else { return }
        self.lastUploadPolicy = policy
        if let data = try? JSONEncoder().encode(policy) { self.defaults.set(data, forKey: Self.uploadPolicyKey(self.id)) }
    }

    /// What this Gateway accepts: the live hello's policy when connected, else the last one seen,
    /// else the defaults.
    public var uploadLimits: UploadLimits {
        if let hello = self.hello, self.state.isConnected { return UploadLimits(hello: hello) }
        return UploadLimits(policy: self.lastUploadPolicy ?? self.hello.map(UploadPolicy.init(hello:)))
    }

    /// Whether the limits come from a real hello (now or earlier) rather than the defaults.
    public var uploadLimitsKnown: Bool { self.hello != nil || self.lastUploadPolicy != nil }

    /// Why this entry waits for a better network, if it does: a large upload (nothing Send Now
    /// released) that the flush would send next in its chat, while the Gateway is connected and
    /// the network is expensive or constrained. Anything behind another unsent message, or
    /// offline, is just queued.
    public func hold(for entry: OutboxEntry) -> OutboxHold? {
        guard entry.state == .queued, !entry.sendOnAnyNetwork, !entry.isMemoryOnly,
              self.state.isConnected, self.hello != nil
        else { return nil }
        let heads: [String: String]
        if let cached = self.outboxEligibleHeads {
            heads = cached
        } else {
            var computed: [String: String] = [:]
            var visitedSessions = Set<String>()
            for candidate in self.outbox.entries {
                self.outboxHeadScanVisits += 1
                guard visitedSessions.insert(candidate.sessionKey).inserted else { continue }
                if candidate.state == .queued, !candidate.isMemoryOnly {
                    computed[candidate.sessionKey] = candidate.id
                }
            }
            self.outboxEligibleHeads = computed
            heads = computed
        }
        guard heads[entry.sessionKey] == entry.id else { return nil }
        guard self.uploadBytes(for: entry) >= OutboxEntry.largeUploadBytes else { return nil }
        if self.network.isConstrained { return .constrained }
        if self.network.isExpensive { return .expensive }
        return nil
    }

    /// Total attachment bytes of an entry, from disk refs or the in-memory copies.
    public func uploadBytes(for entry: OutboxEntry) -> Int {
        max(entry.attachmentBytes, self.outboxAttachments[entry.id]?.reduce(0) { $0 + $1.data.count } ?? 0)
    }

    /// The limits come from a saved policy rather than a live hello (offline): the UI says so.
    public var uploadLimitsAreLastKnown: Bool {
        !(self.hello != nil && self.state.isConnected) && self.lastUploadPolicy != nil
    }

    /// Brings every chat's rows in line with the current holds (the network changed).
    public func resyncOutboxHolds() {
        for key in self.outbox.sessionKeys { self.chats[key]?.syncOutbox(self.outbox.entries(for: key)) }
    }

    /// Watches the network: the holds shown in chats follow it, and a cheap network flushes what waited.
    func startNetworkWatch() {
        guard self.networkWatch == nil else { return }
        self.network.start()
        self.networkWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let network = self?.network else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = network.isExpensive
                        _ = network.isConstrained
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard let self else { return }
                self.resyncOutboxHolds()
                if self.state.isConnected { await self.flushOutbox() }
            }
        }
    }

    /// Attachment bytes this Gateway's outbox keeps on disk.
    public var outboxAttachmentBytes: Int {
        self.outbox.entries.reduce(0) { $0 + $1.attachments.reduce(0) { $0 + $1.byteCount } }
    }

    /// Whether `bytes` more of attachments still fit on disk (store on, not the demo, under the cap).
    public func canPersistAttachments(bytes: Int) -> Bool {
        !self.profile.isDemo && OutboxAttachmentStore.isAvailable(root: self.outboxRoot)
            && self.outboxAttachmentBytes + bytes <= OutboxAttachmentStore.maxTotalBytes
    }

    /// Queues writing the attachment files (before the outbox JSON that will reference them) and
    /// returns their refs, or nil when they can't be kept on disk.
    func persistAttachments(_ attachments: [OutgoingAttachment], entryId: String) -> [OutboxAttachmentRef]? {
        let bytes = attachments.reduce(0) { $0 + $1.data.count }
        guard self.canPersistAttachments(bytes: bytes),
              OutboxAttachmentStore.enqueueWrite(attachments, entryId: entryId, gatewayId: self.id, root: self.outboxRoot)
        else { return nil }
        return OutboxAttachmentStore.refs(for: attachments)
    }

    func moveOutboxAttachments(from id: String, to newId: String) {
        guard !self.profile.isDemo else { return }
        OutboxAttachmentStore.enqueueMove(from: id, to: newId, gatewayId: self.id, root: self.outboxRoot)
    }

    /// Reads a persisted entry's attachment bytes from disk; nil when they can't be read.
    func readAttachments(for entry: OutboxEntry) async -> [OutgoingAttachment]? {
        guard !self.profile.isDemo else { return nil }
        return await OutboxAttachmentStore.read(entry: entry, gatewayId: self.id, root: self.outboxRoot)
    }

    /// The bytes of an entry's attachments (memory-only ones from memory, persisted ones read from
    /// disk and not kept); empty when unavailable.
    func attachmentBytes(for entry: OutboxEntry) async -> [OutgoingAttachment] {
        if let memory = self.outboxAttachments[entry.id] { return memory }
        return await self.readAttachments(for: entry) ?? []
    }

    func attachmentFilesExist(for entry: OutboxEntry) async -> Bool {
        await OutboxAttachmentStore.filesExist(for: entry, gatewayId: self.id, root: self.outboxRoot)
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
            // The queued seating plan's bytes, where `deliver` looks for in-memory attachments.
            if self.outbox.entry(id: DemoOutbox.queuedAttachmentId) != nil {
                self.outboxAttachments[DemoOutbox.queuedAttachmentId] = [DemoGateway.seatingPlan]
            }
            return
        }
        let (saved, _) = await OutboxStore.load(gatewayId: self.id, root: self.outboxRoot)
        // Saving starts only now, so what's composed while the file is read doesn't overwrite it.
        self.outboxRestored = true
        guard var saved, !saved.isEmpty else {
            OutboxAttachmentStore.enqueueSweep(keeping: Set(self.outbox.entries.map(\.id)), gatewayId: self.id, root: self.outboxRoot)
            if !self.outbox.persistable.isEmpty { OutboxStore.enqueueSave(self.outbox, gatewayId: self.id, root: self.outboxRoot) }
            return
        }
        saved.recoverAfterLaunch()
        let restored = saved.entries.filter { !$0.attachments.isEmpty }
        // Anything composed while the file was being read goes after what was saved.
        for entry in self.outbox.entries where saved.entry(id: entry.id) == nil { saved.enqueue(entry) }
        // Restored messages show at once; nothing sends until their attachment files are checked.
        self.outboxValidating = true
        self.outbox = saved
        OutboxAttachmentStore.enqueueSweep(keeping: Set(saved.entries.map(\.id)), gatewayId: self.id, root: self.outboxRoot)
        let lifecycle = self.replySendLifecycle
        let missing = await OutboxAttachmentStore.entriesMissingFiles(restored, gatewayId: self.id, root: self.outboxRoot)
        self.outboxValidating = false
        // An entry whose attachment files are gone can't be sent: it fails (non-retryable, so it
        // stays put with Delete) instead of vanishing.
        let message = "Couldn’t send: the attachments are no longer available. Delete this message and attach them again."
        for id in missing where self.outbox.entry(id: id).map({ $0.state != .sending }) == true {
            self.outbox.markFailed(id: id, kind: .rejected(message), message: message)
        }
        // A store stopped or replaced meanwhile doesn't send; its next start (or successor) does.
        guard self.outboxRestored, lifecycle == self.replySendLifecycle else { return }
        if self.state.isConnected, self.hello != nil { await self.flushOutbox() }
    }

    func outboxChanged(from old: Outbox) {
        self.wakeReplyAcceptanceWaiters()
        for (id, task) in self.replyReservationPreparations where self.outbox.entry(id: id) == nil {
            task.cancel()
        }
        let changed = Set(old.entries.map(\.sessionKey) + self.outbox.entries.map(\.sessionKey)).filter {
            old.entries(for: $0) != self.outbox.entries(for: $0)
        }
        for key in changed {
            self.chats[key]?.syncOutbox(self.outbox.entries(for: key))
        }
        for id in self.outboxAttachments.keys where self.outbox.entry(id: id) == nil {
            self.outboxAttachments.removeValue(forKey: id)
        }
        if self.outboxRestored, !self.profile.isDemo {
            let current = Set(self.outbox.entries.map(\.id))
            for entry in old.entries where !entry.attachments.isEmpty && !current.contains(entry.id) {
                OutboxAttachmentStore.enqueueRemove(entryId: entry.id, gatewayId: self.id, root: self.outboxRoot)
            }
        }
        guard self.outboxRestored, !self.profile.isDemo, old.persistable != self.outbox.persistable else { return }
        OutboxStore.enqueueSave(self.outbox, gatewayId: self.id, root: self.outboxRoot)
    }

    /// Writes the outbox to disk now, on this thread: the app is about to quit.
    public func saveOutboxNow() {
        guard self.outboxRestored, !self.profile.isDemo else { return }
        OutboxStore.saveNow(self.outbox, gatewayId: self.id, root: self.outboxRoot)
    }

    /// Saves the outbox one last time (unless it's being discarded) and stops saving it: a store
    /// replacing this one (after an edit) reads that file, and a send still finishing here
    /// mustn't overwrite it afterwards.
    func retireOutbox(save: Bool = true) {
        if save { self.saveOutboxNow() }
        self.outboxRestored = false
    }

    /// Drops entries whose send already shows in the transcript.
    func reconcileOutbox(committedKeys: Set<String>) {
        guard !committedKeys.isEmpty, self.outbox.entries.contains(where: { committedKeys.contains($0.id) }) else { return }
        self.outbox.reconcile(committedKeys: committedKeys)
    }

    /// Sends every queued message, oldest first and in order per chat. One flush at a time; a
    /// flush stops when the connection drops (what's left stays queued for the next one).
    public func flushOutbox() async {
        // `loadOutbox` flushes once the restored attachments are checked.
        guard !self.outboxFlushing, !self.outboxValidating else { return }
        self.outboxFlushing = true
        defer { self.outboxFlushing = false }
        var checked: Set<String> = []
        while self.state.isConnected, self.hello != nil, let entry = self.outbox.nextToSend(holding: { self.hold(for: $0) != nil }) {
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
