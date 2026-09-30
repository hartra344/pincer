import Foundation
import Observation

extension ChatStore {
    // MARK: Sending

    /// Whether the Gateway accepted a `chat.send`. A run id is optional: accepted sends may not have one.
    public enum SendOutcome: Equatable, Sendable {
        case sent(runId: String?)
        /// In the outbox: offline, or waiting behind an earlier message of this chat. It goes out
        /// on its own once the Gateway is back.
        case queued
        /// Not sent, and it stays in the transcript marked failed, with Retry and Delete.
        case failedInline(String)
        /// Not sent, and nothing was kept: the caller still has the message.
        case failed(String)
    }

    /// Sends and returns the run id, or nil when there's none or the send didn't go out.
    @discardableResult
    public func send(_ text: String, attachments: [OutgoingAttachment] = [], replyTo: ReplyTarget? = nil,
                     requiresConnection: Bool = false) async -> String?
    {
        let outcome = await self.sendMessage(text, attachments: attachments, replyTo: replyTo, requiresConnection: requiresConnection)
        if case let .sent(runId) = outcome { return runId }
        return nil
    }

    /// Sends through the outbox, telling an accepted send apart from a queued or failed one. With
    /// `replyTo`, the message replies to that one (`replyToId`), or quotes it on Gateways that
    /// don't take `replyToId`; an accepted or queued reply clears `replyTarget`.
    ///
    /// Text messages written offline are queued and sent in order on reconnect; a failed send
    /// stays in the transcript with Retry. Attachments are kept on disk with them (up to
    /// `OutboxAttachmentStore.maxTotalBytes` per Gateway); past that, or with the store off, a send
    /// with attachments needs a connection and lives for this launch only. With
    /// `requiresConnection` (Quick Capture, setup's test message, commands) nothing is queued or
    /// kept: offline or failed sends come back as `.failed` with `errorMessage` set.
    @discardableResult
    public func sendMessage(_ text: String, attachments: [OutgoingAttachment] = [], replyTo: ReplyTarget? = nil,
                            requiresConnection: Bool = false) async -> SendOutcome
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .failed("Couldn’t send: the message is empty.") }
        guard let gateway else { return .failed("Couldn’t send: the Gateway is gone.") }
        let connected = gateway.state.isConnected
        let attachmentBytes = attachments.reduce(0) { $0 + $1.data.count }
        let persistsAttachments = !attachments.isEmpty && gateway.canPersistAttachments(bytes: attachmentBytes)
        let memoryOnly = !attachments.isEmpty && !persistsAttachments
        if !connected, requiresConnection || memoryOnly {
            let message = "Couldn’t send: \(GatewayError.notConnected.localizedDescription)"
            self.errorMessage = message
            return .failed(message)
        }
        let idempotencyKey = UUID().uuidString.lowercased()
        var blocks: [ContentBlock] = trimmed.isEmpty ? [] : [.text(trimmed)]
        for attachment in attachments {
            if attachment.isImage {
                blocks.append(.image(ImageRef(
                    artifactId: nil, base64: attachment.data.base64EncodedString(), url: nil,
                    mimeType: attachment.mimeType, alt: attachment.fileName, width: nil, height: nil)))
            } else {
                blocks.append(.file(FileRef(name: attachment.fileName, mimeType: attachment.mimeType)))
            }
        }
        let createdAt = Date()
        var pending = ChatItem(role: .user, blocks: blocks, timestamp: createdAt, idempotencyKey: idempotencyKey, isPending: true)
        pending.outboxState = .queued
        var entry = OutboxEntry(id: idempotencyKey, sessionKey: self.sessionKey, agentId: self.agentId, text: trimmed,
                                createdAt: createdAt, hasAttachments: !attachments.isEmpty)
        if let replyTo {
            let preview = ReplyPreview(text: Replies.previewLine(replyTo.preview), senderLabel: replyTo.senderLabel)
            pending.replyToId = replyTo.messageId
            pending.replyToPreview = preview
            entry.replyToId = replyTo.messageId
            entry.replyPreview = preview
        }
        if !attachments.isEmpty {
            if persistsAttachments, let refs = gateway.persistAttachments(attachments, entryId: idempotencyKey) {
                entry.attachments = refs
            } else {
                gateway.outboxAttachments[idempotencyKey] = attachments
            }
        }
        self.items.append(pending)
        gateway.outbox.enqueue(entry)
        guard connected, gateway.outbox.isHead(id: idempotencyKey) else {
            if requiresConnection || entry.isMemoryOnly {
                // Behind an earlier message of this chat: this send can't wait in the queue.
                self.discardUnsent(idempotencyKey)
                let message = "Couldn’t send: an earlier message in this chat hasn’t gone out yet."
                self.errorMessage = message
                return .failed(message)
            }
            if let replyTo, self.replyTarget == replyTo { self.replyTarget = nil }
            if connected { Task { await gateway.flushOutbox() } }
            return .queued
        }
        let outcome = await self.deliver(entry, keepFailure: !requiresConnection, attachments: attachments)
        if case .failed = outcome { return outcome }
        if let replyTo, self.replyTarget == replyTo { self.replyTarget = nil }
        return outcome
    }

    /// Sends one outbox entry now, reusing its idempotency key. On success the entry leaves the
    /// outbox and the message waits for the transcript; on failure it's marked by kind (see
    /// `Outbox.markFailed`), or with `keepFailure` off, dropped along with its row.
    @discardableResult
    func deliver(_ entry: OutboxEntry, keepFailure: Bool = true, attachments provided: [OutgoingAttachment]? = nil) async -> SendOutcome {
        guard let gateway else { return .failed("Couldn’t send: the Gateway is gone.") }
        var key = entry.id
        // Bytes of persisted attachments are read for this send only, never kept in memory.
        var attachments = provided ?? gateway.outboxAttachments[key] ?? []
        if entry.hasAttachments, attachments.isEmpty, !entry.attachments.isEmpty {
            if let loaded = await gateway.readAttachments(for: entry) {
                attachments = loaded
            } else if gateway.attachmentFilesExist(for: entry) {
                // The files are there but unreadable (say the device is locked): worth a Retry.
                let message = "Couldn’t send: the attachments couldn’t be read. Try again."
                gateway.outbox.markFailed(id: key, kind: .transient, isConnected: true, message: message)
                return .failedInline(message)
            }
        }
        if entry.hasAttachments, attachments.isEmpty {
            let message = "Couldn’t send: the attachments are no longer available. Delete this message and attach them again."
            gateway.outbox.markFailed(id: key, kind: .rejected(message), message: message)
            return .failedInline(message)
        }
        if let tooLarge = attachments.first(where: { attachment in
            let limits = gateway.uploadLimits
            return attachment.data.count > (attachment.isImage ? limits.imageBytes : limits.fileBytes)
        }) {
            let limits = gateway.uploadLimits
            let limit = tooLarge.isImage ? limits.imageBytes : limits.fileBytes
            let message = L("Couldn’t send: \(tooLarge.fileName) is larger than this Gateway accepts (\(Int64(limit).formatted(.byteCount(style: .file)))).")
            gateway.outbox.markFailed(id: key, kind: .rejected(message), message: message)
            return .failedInline(message)
        }
        gateway.outbox.markSending(id: key)
        self.isSending = true
        defer { self.isSending = false }

        let quoted = entry.replyToId.map { _ in
            Replies.quotedFallback(sender: entry.replyPreview?.senderLabel ?? "", preview: entry.replyPreview?.text ?? "",
                                   text: entry.text)
        }
        func params(replying: Bool) -> [String: JSONValue] {
            ChatSendRequest.params(
                sessionKey: self.sessionKey, agentId: entry.agentId ?? self.agentId, message: replying ? entry.text : (quoted ?? entry.text),
                idempotencyKey: key, attachments: attachments, replyToId: replying ? entry.replyToId : nil)
        }
        let replying = entry.replyToId != nil && !gateway.replyToUnsupported
        do {
            let result: JSONValue
            do {
                result = try await gateway.connection.request("chat.send", .object(params(replying: replying)), timeout: 60)
            } catch where replying && Replies.isReplyToRejection(error) {
                // An older Gateway: quote the original in the text instead, for this connection.
                // Other params need another key; retries of this message reuse the new one.
                gateway.replyToUnsupported = true
                let retryKey = UUID().uuidString.lowercased()
                if let index = self.items.firstIndex(where: { $0.isPending && $0.idempotencyKey == key }) {
                    self.items[index].idempotencyKey = retryKey
                }
                gateway.outboxAttachments[retryKey] = gateway.outboxAttachments.removeValue(forKey: key)
                if !entry.attachments.isEmpty { gateway.moveOutboxAttachments(from: key, to: retryKey) }
                gateway.outbox.rekey(id: key, to: retryKey)
                key = retryKey
                result = try await gateway.connection.request("chat.send", .object(params(replying: false)), timeout: 60)
            }
            // Accepted: the row stays pending until the transcript commits it.
            if let index = self.items.firstIndex(where: { $0.isPending && $0.idempotencyKey == key }) {
                self.items[index].outboxState = nil
            }
            gateway.outbox.markSent(id: key)
            let runId = result["runId"]?.text
            if let runId {
                gateway.track(runId: runId, sessionKey: self.sessionKey)
                if self.live?.runId != runId { self.live = LiveRun(runId: runId) }
            }
            self.errorMessage = nil
            return .sent(runId: runId)
        } catch {
            let message = "Couldn’t send: \(error.localizedDescription)"
            guard keepFailure else {
                self.discardUnsent(key)
                self.errorMessage = message
                return .failed(message)
            }
            let connected = gateway.state.isConnected && !SendFailure.isDisconnect(error)
            gateway.outbox.markFailed(id: key, kind: SendFailure.classify(error), isConnected: connected,
                                      message: SendFailure.message(for: error))
            return gateway.outbox.entry(id: key)?.state == .queued ? .queued : .failedInline(message)
        }
    }

    /// Queues a failed message again; it goes out with its original idempotency key as soon as
    /// the Gateway is connected (reconnecting now if it isn't). One with attachments is sent right
    /// away if it's first in its chat; offline, it stays failed while the Gateway reconnects. (Only
    /// memory-only ones; attachments kept on disk are queued like text.)
    public func retry(outboxId: String) {
        guard let gateway, let entry = gateway.outbox.entry(id: outboxId), entry.isFailed else { return }
        if entry.isMemoryOnly {
            guard gateway.state.isConnected else { return gateway.reconnectIfNeeded() }
            guard gateway.outbox.isHead(id: outboxId) else { return }
            gateway.outbox.retry(id: outboxId)
            Task {
                await self.deliver(entry)
                await gateway.flushOutbox()
            }
            return
        }
        gateway.outbox.retry(id: outboxId)
        if gateway.state.isConnected {
            Task { await gateway.flushOutbox() }
        } else {
            gateway.reconnectIfNeeded()
        }
    }

    /// Uploads a held large message now, over whatever network this is.
    public func sendNow(outboxId: String) {
        guard let gateway, gateway.outbox.entry(id: outboxId)?.state == .queued else { return }
        gateway.updateOutbox { $0.allowAnyNetwork(id: outboxId) }
        self.syncOutbox(gateway.outbox.entries(for: self.sessionKey))
        if gateway.state.isConnected { Task { await gateway.flushOutbox() } }
    }

    /// Deletes a queued or failed message; one being sent right now can't be.
    public func deleteQueued(outboxId: String) {
        guard let gateway, let entry = gateway.outbox.entry(id: outboxId), entry.state != .sending else { return }
        gateway.outbox.delete(id: outboxId)
    }

    /// This chat's unsent messages, oldest first.
    public var unsentEntries: [OutboxEntry] {
        self.gateway?.outbox.entries(for: self.sessionKey) ?? []
    }

    func discardUnsent(_ key: String) {
        self.gateway?.outbox.delete(id: key)
        self.items.removeAll { $0.isPending && $0.idempotencyKey == key }
    }

    /// Brings the transcript's unsent rows in line with the outbox: states change in place,
    /// deleted entries' rows go, and entries without a row (restored after a relaunch, or seeded)
    /// get one at the end.
    func syncOutbox(_ entries: [OutboxEntry]) {
        guard !self.headless else { return }
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items = self.items
        items.removeAll { item in
            guard item.outboxState != nil, let key = item.idempotencyKey else { return false }
            return byId[key] == nil
        }
        var seen: Set<String> = []
        var committed: Set<String> = []
        for index in items.indices {
            guard let key = items[index].idempotencyKey, let entry = byId[key] else { continue }
            seen.insert(key)
            guard items[index].isPending else {
                committed.insert(key)
                continue
            }
            if items[index].outboxState != entry.state { items[index].outboxState = entry.state }
            let hold = self.gateway?.hold(for: entry)
            if items[index].outboxHold != hold { items[index].outboxHold = hold }
            let bytes = hold == nil ? nil : self.gateway?.uploadBytes(for: entry)
            if items[index].outboxUploadBytes != bytes { items[index].outboxUploadBytes = bytes }
        }
        for entry in entries where !seen.contains(entry.id) {
            var item = ChatItem(id: "outbox:\(entry.id)", role: .user, blocks: (entry.text.isEmpty ? [] : [.text(entry.text)])
                                + entry.attachments.map { .file(FileRef(name: $0.fileName, mimeType: $0.mimeType)) },
                                timestamp: entry.createdAt, idempotencyKey: entry.id, isPending: true)
            item.outboxState = entry.state
            item.outboxHold = self.gateway?.hold(for: entry)
            item.outboxUploadBytes = item.outboxHold == nil ? nil : self.gateway?.uploadBytes(for: entry)
            item.replyToId = entry.replyToId
            item.replyToPreview = entry.replyPreview
            items.append(item)
        }
        if items != self.items { self.items = items }
        if !committed.isEmpty {
            // After this outbox change has settled; the transcript already has these.
            Task { [weak gateway] in gateway?.reconcileOutbox(committedKeys: committed) }
        }
    }

    /// Compacts the session's context now, reporting token counts before and after in `compaction`.
    /// Uses `sessions.compact` when allowed (it needs `operator.admin`); instructions, or a connection
    /// without admin, go through the `/compact` command instead.
    public func compact(instructions: String = "") async {
        guard let gateway, self.compaction?.isRunning != true else { return }
        let before = gateway.sessions[self.sessionKey]?.totalTokens
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.compaction = .running(before: before)
        guard instructions.isEmpty, gateway.canCompactDirectly else {
            let runId = await self.send(instructions.isEmpty ? "/compact" : "/compact \(instructions)", requiresConnection: true)
            if let runId {
                self.compactionRunId = runId
            } else {
                self.compaction = .failed(self.errorMessage ?? "Couldn’t start compaction.")
            }
            return
        }
        do {
            let result = try await gateway.connection.request(
                "sessions.compact", .object(self.params(keyName: "key")), timeout: 300)
            let reason = result["reason"]?.text
            if result["ok"]?.bool == false {
                self.compaction = .failed(reason.map { "Couldn’t compact: \($0)" } ?? "Compaction failed.")
            } else if result["compacted"]?.bool == false {
                self.compaction = .skipped(reason ?? "There was nothing to compact.")
            } else {
                let tokensBefore = result["result"]?["tokensBefore"]?.int ?? before
                var tokensAfter = result["result"]?["tokensAfter"]?.int
                if tokensAfter == nil {
                    await gateway.refreshSessions()
                    tokensAfter = gateway.sessions[self.sessionKey]?.totalTokens
                }
                self.compaction = .finished(before: tokensBefore, after: tokensAfter)
            }
            self.scheduleReload()
        } catch {
            self.compaction = .failed("Couldn’t compact: \(error.localizedDescription)")
        }
    }

    /// Forgets a finished compaction's result (a running one stays).
    public func clearCompaction() {
        guard self.compaction?.isRunning != true else { return }
        self.compaction = nil
    }

    func finishCompaction(runId: String) async {
        guard self.compactionRunId == runId, case let .running(before) = self.compaction else { return }
        self.compactionRunId = nil
        await self.gateway?.refreshSessions()
        self.compaction = .finished(before: before, after: self.gateway?.sessions[self.sessionKey]?.totalTokens)
    }

    public func abort() async {
        guard let gateway else { return }
        var params = self.params(keyName: "sessionKey")
        if let runId = self.live?.runId { params["runId"] = .string(runId) }
        _ = try? await gateway.connection.request("chat.abort", .object(params))
    }
}
