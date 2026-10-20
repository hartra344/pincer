import Foundation
import Observation

extension GatewayStore {
    // MARK: Chats

    public func chat(for key: String) -> ChatStore {
        self.residency.touch(key)
        if let existing = self.chats[key] { return existing }
        let store = ChatStore(sessionKey: key, agentId: self.sessions[key]?.agentId, gateway: self)
        self.chats[key] = store
        store.syncOutbox(self.outbox.entries(for: key))
        self.enforceChatBudget()
        return store
    }

    /// Saves every chat's pending draft now, e.g. before the app is suspended.
    func flushDrafts() async {
        for chat in self.chats.values {
            await chat.flushDraft()
        }
    }

    func discardDraft(_ key: String) {
        if let chat = self.chats[key] {
            chat.draft = ComposerDraft()
        } else {
            let id = self.id
            Task { await DraftStore.remove(gatewayId: id, sessionKey: key) }
        }
    }

    func openChat(_ key: String) async {
        let chat = self.chat(for: key)
        await chat.load()
        await self.markRead(key)
    }

    public func markRead(_ key: String) async {
        guard let row = self.sessions[key], row.isUnread, self.state.isConnected,
              !self.markingRead.contains(key) else { return }
        self.markingRead.insert(key)
        let sent = (try? await self.connection.request("sessions.patch", ["key": .string(key), "unread": false])) != nil
        self.markingRead.remove(key)
        if self.recheckRead.remove(key) != nil, sent { self.markVisibleChatsRead() }
    }

    // MARK: Mutations

    /// Creates a chat and, with `select`, opens it in the main window.
    public func createSession(agentId: String?, label: String?, category: String? = nil, select: Bool = true) async -> String? {
        let selectionRevision = self.selectionIntentRevision
        var params: [String: JSONValue] = ["agentId": .string(agentId ?? self.defaultAgentId)]
        if let label = label?.nilIfEmpty { params["label"] = .string(label) }
        if let category = category?.nilIfEmpty { params["category"] = .string(category) }
        do {
            let result = try await self.connection.request("sessions.create", .object(params), timeout: 30)
            guard let key = result["key"]?.text ?? result["session"]?["key"]?.text else { return nil }
            if let row = result["session"].flatMap(SessionRow.init) {
                self.setSession(row, for: key)
            } else {
                await self.refreshSessions()
            }
            if select, self.selectionIntentRevision == selectionRevision { self.selectedKey = key }
            return key
        } catch {
            self.lastError = error.localizedDescription
            return nil
        }
    }

    public func patch(_ key: String, _ fields: [String: JSONValue]) async {
        var params = fields
        params["key"] = .string(key)
        if fields["archived"] != nil, let sessionId = self.sessions[key]?.sessionId {
            params["expectedSessionId"] = .string(sessionId)
        }
        do {
            _ = try await self.connection.request("sessions.patch", .object(params))
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Loads the models an agent can use. Cached per agent; `refresh` refetches.
    public func loadModels(agentId: String, refresh: Bool = false) async {
        guard self.state.isConnected, refresh || self.modelCatalogs[agentId] == nil,
              self.loadingModelCatalogs.insert(agentId).inserted
        else { return }
        defer { self.loadingModelCatalogs.remove(agentId) }
        do {
            // `includeDetails` adds each model's effective `contextTokens`; released Gateways reject it.
            let result: JSONValue
            if let detailed = try? await self.connection.request(
                "models.list", ["agentId": .string(agentId), "includeDetails": true], timeout: 30)
            {
                result = detailed
            } else {
                result = try await self.connection.request("models.list", ["agentId": .string(agentId)], timeout: 30)
            }
            self.modelCatalogs[agentId] = result["models"]?.array?.compactMap(ModelChoice.init) ?? []
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// How full a session's context is. The row's own limits win; otherwise the serving model's window
    /// from `models.list` (see `loadModels`), then the Gateway default.
    public func contextUsage(for key: String) -> ContextUsage? {
        guard let row = self.sessions[key] else { return nil }
        return ContextUsage(row: row, fallbackLimit: self.fallbackContextLimit(for: row))
    }

    /// Whether `contextUsage` needs the agent's model catalog to find a limit.
    public func needsModelCatalogForContext(_ key: String) -> Bool {
        guard let row = self.sessions[key], row.totalTokens != nil,
              row.promptBudgetTokens == nil, row.contextTokens == nil
        else { return false }
        return self.modelCatalogs[row.agentId] == nil
    }

    private func fallbackContextLimit(for row: SessionRow) -> Int? {
        let refs = [row.activeModelRef, row.modelRef, self.defaultModelRef].compactMap(\.self)
        let catalog = self.modelCatalogs[row.agentId] ?? []
        for ref in refs {
            if let limit = catalog.first(where: { $0.ref == ref || $0.modelId == ref })?.contextTokens { return limit }
        }
        return self.defaultContextTokens
    }

    /// `sessions.compact` needs `operator.admin`; without it, "Compact now" sends `/compact` instead.
    public var canCompactDirectly: Bool {
        guard self.hello?.scopes.contains(GatewayConnection.adminScope) == true else { return false }
        return GatewayMethodSupport.supports("sessions.compact", advertised: self.hello?.methods)
    }

    /// Slash commands for a session (Gateway `commands.list` plus client commands). Falls back to a
    /// built-in list until the Gateway answers, or when it can't list commands.
    public func slashCommands(for sessionKey: String) -> [SlashCommand] {
        SlashCommand.withClientCommands(self.commandCatalogs[sessionKey]?.commands ?? SlashCommand.fallback)
    }

    /// Fetches a session's commands. Plugins, skills and config change what's available, so a
    /// catalog is refetched once it's older than a minute.
    public func loadCommands(sessionKey: String, agentId: String?) async {
        if let cached = self.commandCatalogs[sessionKey], cached.connectionEpoch == self.connectionEpoch,
           Date().timeIntervalSince(cached.fetchedAt) < 60
        {
            return
        }
        guard self.state.isConnected, self.loadingCommands.insert(sessionKey).inserted else { return }
        defer { self.loadingCommands.remove(sessionKey) }
        if !GatewayMethodSupport.supports("commands.list", advertised: self.hello?.methods) { return }
        let epoch = self.connectionEpoch
        var params: [String: JSONValue] = ["includeArgs": true, "scope": "text"]
        if let agentId { params["agentId"] = .string(agentId) }
        var result = try? await self.connection.request(
            "commands.list", .object(params.merging(["sessionKey": .string(sessionKey)]) { $1 }), timeout: 15)
        if result == nil {
            // Chats that haven't been written to yet aren't sessions the Gateway can scope to.
            result = try? await self.connection.request("commands.list", .object(params), timeout: 15)
        }
        guard let result, result["commands"]?.array != nil else { return }
        self.commandCatalogs[sessionKey] = CommandCatalog(
            commands: SlashCommand.parse(result), fetchedAt: Date(), connectionEpoch: epoch)
    }

    /// Sets the model new messages in a session use; `nil` goes back to the agent's default.
    /// Messages already written keep the model the Gateway recorded for them.
    public func setModel(_ key: String, to ref: String?) async {
        await self.patch(key, ["model": ref.map(JSONValue.string) ?? .null])
    }
}
