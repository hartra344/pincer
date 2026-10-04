import Foundation

/// A user message being edited in the composer. Nothing changes on the Gateway until Send.
public struct MessageEditTarget: Equatable, Sendable {
    public let messageId: String
    /// The persisted transcript id `sessions.rewind` / `sessions.fork` cut before.
    public let entryId: String
    public let originalText: String
    /// The composer's content before the edit began; Cancel puts it back.
    public var savedDraft: ComposerDraft

    public init(messageId: String, entryId: String, originalText: String, savedDraft: ComposerDraft) {
        self.messageId = messageId
        self.entryId = entryId
        self.originalText = originalText
        self.savedDraft = savedDraft
    }
}

extension ChatStore {
    static let forkMethod = "sessions.fork"

    // MARK: Availability

    /// `sessions.fork` is advertised (or the Gateway doesn't list its methods) and the connection can write.
    public var canBranchMessages: Bool {
        guard let gateway else { return false }
        let scopes = gateway.hello?.scopes ?? []
        guard gateway.profile.isDemo || scopes.contains("operator.write") || scopes.contains(GatewayConnection.adminScope) else { return false }
        let methods = gateway.hello?.methods ?? []
        return methods.isEmpty || methods.contains(Self.forkMethod)
    }

    /// The Gateway refuses fork, rewind and branch switches while the agent is working.
    var isBusyForHistoryChange: Bool { self.isRunning || self.live != nil }

    /// `sessions.rewind` is advertised and the connection has `operator.admin`.
    public var canRewindMessages: Bool { self.gateway?.sessionManager.canRewind == true }

    private func committedItem(_ messageId: String) -> (index: Int, item: ChatItem)? {
        guard let index = self.items.firstIndex(where: { $0.id == messageId || $0.transcriptId == messageId }) else { return nil }
        let item = self.items[index]
        guard !item.isPending, let entry = item.transcriptId, !entry.hasPrefix(ChatItem.pendingInputPrefix) else { return nil }
        return (index, item)
    }

    public func canBranch(from messageId: String) -> Bool {
        self.canBranchMessages && !self.isBusyForHistoryChange && self.committedItem(messageId) != nil
    }

    public func canEdit(_ messageId: String) -> Bool {
        guard self.canRewindMessages, !self.isBusyForHistoryChange, let found = self.committedItem(messageId) else { return false }
        return found.item.role == .user
    }

    /// The last assistant reply, when a user message precedes it and no run is streaming.
    public func canRegenerate(_ messageId: String) -> Bool {
        guard self.canRewindMessages, !self.isBusyForHistoryChange,
              let found = self.committedItem(messageId), found.item.role == .assistant else { return false }
        guard self.items.lastIndex(where: { $0.role == .assistant && !$0.isPending }) == found.index else { return false }
        return self.precedingUser(before: found.index) != nil
    }

    private func precedingUser(before index: Int) -> ChatItem? {
        self.items[..<index].last { $0.role == .user && $0.isCommittedEntry }
    }

    // MARK: Branch

    /// Forks a new chat from `messageId` and opens it. A user message forks before itself and
    /// hands its text to the new composer; any other message forks right after it, and the last
    /// one forks the whole chat (`sessions.create` with `fork`).
    @discardableResult
    public func branch(from messageId: String) async -> String? {
        guard let gateway, let found = self.committedItem(messageId) else { return nil }
        do {
            let newKey: String
            var editorText: String?
            let target: ChatItem? = found.item.role == .user
                ? found.item
                : self.items[(found.index + 1)...].first { $0.role == .user && $0.isCommittedEntry }
            if let target, let targetId = target.transcriptId {
                var params: [String: JSONValue] = ["sessionKey": .string(self.sessionKey), "entryId": .string(targetId)]
                if let agentId { params["agentId"] = .string(agentId) }
                let result = try await gateway.connection.request(Self.forkMethod, .object(params), timeout: 30)
                guard let key = result["sessionKey"]?.text ?? result["key"]?.text else {
                    throw GatewayError.protocolViolation("sessions.fork returned no key")
                }
                newKey = key
                if target.id == found.item.id { editorText = result["editorText"]?.text ?? found.item.plainText }
            } else {
                var params: [String: JSONValue] = [
                    "parentSessionKey": .string(self.sessionKey), "fork": .bool(true), "forkFrom": .string("last-completed"),
                ]
                params["agentId"] = .string(agentId ?? SessionKey.agentId(from: self.sessionKey) ?? gateway.defaultAgentId)
                let result = try await gateway.connection.request("sessions.create", .object(params), timeout: 30)
                guard let key = result["key"]?.text ?? result["session"]?["key"]?.text else {
                    throw GatewayError.protocolViolation("sessions.create returned no key")
                }
                newKey = key
            }
            await gateway.refreshSessions()
            let chat = gateway.chat(for: newKey)
            if let editorText, !editorText.isEmpty, chat.draft.isEmpty { chat.draft.text = editorText }
            gateway.selectedKey = newKey
            return newKey
        } catch {
            self.errorMessage = L("Couldn’t branch: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Edit & Resend

    @discardableResult
    public func beginEdit(_ messageId: String) -> Bool {
        guard self.canEdit(messageId), let found = self.committedItem(messageId), let entryId = found.item.transcriptId else { return false }
        let saved = self.editTarget?.savedDraft ?? self.draft
        let text = found.item.plainText
        self.replyTarget = nil
        self.editTarget = MessageEditTarget(messageId: found.item.id, entryId: entryId, originalText: text, savedDraft: saved)
        self.draft = ComposerDraft(text: text)
        return true
    }

    public func cancelEdit() {
        guard let target = self.editTarget else { return }
        self.editTarget = nil
        self.draft = target.savedDraft
    }

    /// Rewinds to before the edited message, then sends `text` with `attachments` and the images the
    /// rewound message carried. After the rewind the pre-edit draft comes back; on a rewind failure
    /// edit mode and the edited text stay. Ignored while an earlier `sendEdit` is still running.
    public func sendEdit(_ text: String, attachments: [OutgoingAttachment]) async -> SendOutcome {
        guard let target = self.editTarget else { return await self.sendMessage(text, attachments: attachments) }
        guard !self.isSendingEdit else { return .failed(L("Couldn’t edit: the previous edit is still being sent.")) }
        self.isSendingEdit = true
        defer { self.isSendingEdit = false }
        let outcome: RewindOutcome
        do {
            outcome = try await self.rewind(to: target.entryId)
        } catch {
            let message = L("Couldn’t edit: \(error.localizedDescription)")
            self.errorMessage = message
            return .failed(message)
        }
        let savedDraft = self.editTarget?.savedDraft ?? target.savedDraft
        self.editTarget = nil
        self.draft = savedDraft
        return await self.sendMarkingBranchAnchor { await self.sendMessage(text, attachments: attachments + outcome.attachments) }
    }

    /// Sends, then remembers the sent message's key as the place the chat's branches fork.
    private func sendMarkingBranchAnchor(_ send: () async -> SendOutcome) async -> SendOutcome {
        let before = Set(self.items.compactMap(\.idempotencyKey))
        let outcome = await send()
        if let key = self.items.last(where: { $0.role == .user && $0.idempotencyKey.map { !before.contains($0) } == true })?.idempotencyKey {
            self.branchAnchorKey = key
        }
        return outcome
    }

    // MARK: Regenerate

    @discardableResult
    public func regenerate(_ messageId: String) async -> Bool {
        guard self.canRegenerate(messageId), !self.isSendingEdit, let found = self.committedItem(messageId),
              let user = self.precedingUser(before: found.index), let entryId = user.transcriptId else { return false }
        self.editTarget = nil
        do {
            let outcome = try await self.rewind(to: entryId)
            let text = outcome.editorText ?? user.plainText
            switch await self.sendMarkingBranchAnchor({ await self.sendMessage(text, attachments: outcome.attachments) }) {
            case .failed(let message), .failedInline(let message):
                self.errorMessage = L("Couldn’t regenerate: \(message)")
                return false
            case .sent, .queued:
                return true
            }
        } catch {
            self.errorMessage = L("Couldn’t regenerate: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Rewind

    struct RewindOutcome {
        var editorText: String?
        var attachments: [OutgoingAttachment]
    }

    /// `sessions.rewind`, then drops the cached transcript so the cut path reloads before anything is sent.
    private func rewind(to entryId: String) async throws -> RewindOutcome {
        guard let gateway else { throw GatewayError.notConnected }
        var params: [String: JSONValue] = ["sessionKey": .string(self.sessionKey), "entryId": .string(entryId)]
        if let agentId { params["agentId"] = .string(agentId) }
        let result = try await gateway.connection.request(SessionManager.rewindMethod, .object(params), timeout: 30)
        let attachments = (result["editorAttachments"]?.array ?? []).enumerated().compactMap { index, value -> OutgoingAttachment? in
            guard let mime = value["mimeType"]?.text, let base64 = value["data"]?.text,
                  let data = Data(base64Encoded: base64) else { return nil }
            let ext = mime.split(separator: "/").last.map(String.init) ?? "bin"
            return OutgoingAttachment(fileName: "image-\(index + 1).\(ext)", mimeType: mime, data: data)
        }
        await gateway.transcriptChanged(key: self.sessionKey, change: .changed(editorText: nil))
        return RewindOutcome(editorText: result["editorText"]?.text, attachments: attachments)
    }
}

extension ChatItem {
    /// A persisted transcript entry (not an optimistic send or a pending-input placeholder).
    var isCommittedEntry: Bool {
        guard !self.isPending, let id = self.transcriptId else { return false }
        return !id.hasPrefix(ChatItem.pendingInputPrefix)
    }
}
