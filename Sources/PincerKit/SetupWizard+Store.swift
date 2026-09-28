import Foundation

extension SetupRules {
    /// The config edits that make `agentId` the default agent (`agents.entries.<id>.default`) and
    /// `modelRef` the default model (`agents.defaults.model.primary`, or `agents.defaults.model`
    /// when the config keeps it as a plain string). Nil values remove a key.
    public static func defaultsEdits(config: JSONValue, agentId: String?, modelRef: String?) -> [(path: [String], value: JSONValue?)] {
        var edits: [(path: [String], value: JSONValue?)] = []
        if let agentId {
            let entries = config["agents"]?["entries"]?.object ?? [:]
            for (id, entry) in entries.sorted(by: { $0.key < $1.key }) where id != agentId && entry["default"]?.bool == true {
                edits.append((["agents", "entries", id, "default"], nil))
            }
            if entries[agentId]?["default"]?.bool != true {
                edits.append((["agents", "entries", agentId, "default"], .bool(true)))
            }
        }
        if let modelRef {
            let current = config["agents"]?["defaults"]?["model"]
            if current?.text != nil {
                if current?.text != modelRef { edits.append((["agents", "defaults", "model"], .string(modelRef))) }
            } else if current?["primary"]?.text != modelRef {
                edits.append((["agents", "defaults", "model", "primary"], .string(modelRef)))
            }
        }
        return edits
    }
}

extension GatewayStore {
    /// Why the wizard can't save a default agent or model here, or nil when it can.
    public var setupDefaultsBlocker: String? {
        guard self.settings.canEdit else { return SetupWizardModel.fullManagementMessage }
        if let methods = self.hello?.methods, !methods.isEmpty, !methods.contains("config.patch") {
            return "This Gateway doesn't accept config changes."
        }
        if self.settings.hasChanges { return "Gateway Settings has unsaved changes. Save or discard them first." }
        return nil
    }

    /// Sets the default agent and model with `config.patch` through Gateway Settings. Returns an
    /// error message, or nil when saved (or nothing changed).
    public func saveSetupDefaults(agentId: String?, modelRef: String?) async -> String? {
        if let blocker = self.setupDefaultsBlocker { return blocker }
        let settings = self.settings
        if !settings.hasLoaded { await settings.load() }
        guard settings.hasLoaded else { return settings.loadState.error ?? "Couldn't load the Gateway's settings." }
        let edits = SetupRules.defaultsEdits(config: settings.config, agentId: agentId, modelRef: modelRef)
        guard !edits.isEmpty else { return nil }
        for edit in edits { settings.set(edit.path, edit.value) }
        guard await settings.save(note: "Pincer: Set Up Gateway") else {
            let message = settings.saveState.error ?? "Couldn't save."
            settings.discardChanges()
            return message
        }
        await self.reloadAgents()
        await self.refreshSessions()
        return nil
    }

    /// Opens a new chat with the default agent and sends `text`. Done once the Gateway accepts the
    /// send; the wizard watches `chat(for: key)` for the reply.
    public func sendSetupTestMessage(_ text: String) async -> (key: String?, outcome: ChatStore.SendOutcome) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, .failed("Type a message first.")) }
        guard let key = await self.setupTestSessionKey() else {
            return (nil, .failed(self.lastError ?? "Couldn't start a chat."))
        }
        let outcome = await self.chat(for: key).sendMessage(text, requiresConnection: true)
        if case .sent = outcome { self.setup.markTestMessageSent(chatKey: key) }
        return (key, outcome)
    }

    public nonisolated static let setupTestLabel = "Setup Test"

    /// Reuses the default agent's unarchived "Setup Test" chat, else creates one.
    private func setupTestSessionKey() async -> String? {
        let agentId = self.defaultAgentId
        if let row = self.sessions.values.first(where: {
            $0.raw["label"]?.text == Self.setupTestLabel && $0.agentId == agentId && !$0.isArchived
        }) { return row.key }
        return await self.createSession(agentId: agentId, label: Self.setupTestLabel)
    }
}

extension CommandPalette {
    public static let setupGatewayCommand = "setupGateway"

    /// ⌘K "Set Up Gateway…" for the selected gateway (none without one; disabled while disconnected).
    @MainActor public static func setupGatewayItem(gateway: GatewayStore?) -> PaletteItem? {
        guard let gateway else { return nil }
        let setup = gateway.setup
        let subtitle: String? = setup.progress.completed ? nil
            : "\(setup.settledCount) of \(SetupStep.allCases.count) steps"
        return PaletteItem(id: "command:\(self.setupGatewayCommand)", title: "Set Up Gateway…", subtitle: subtitle,
                           symbol: "checklist", keywords: ["setup", "wizard", "onboarding", "getting started"],
                           section: .commands, action: .command(self.setupGatewayCommand),
                           isEnabled: gateway.state.isConnected)
    }
}
