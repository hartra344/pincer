import Foundation
import Observation

extension GatewayStore {
    /// Sees every event this store handles, in wire order (for Shortcuts reusing this connection).
    func addEventTap(_ tap: @escaping @MainActor (GatewayEvent) -> Void) -> Int {
        self.nextEventTap += 1
        self.eventTaps[self.nextEventTap] = tap
        return self.nextEventTap
    }

    func removeEventTap(_ token: Int) {
        self.eventTaps.removeValue(forKey: token)
    }

    func handle(_ event: GatewayEvent) {
        for tap in self.eventTaps.values { tap(event) }
        self.deviceNode.handleOperatorEvent(event)
        let payload = event.payload
        switch event.name {
        case PortalStore.changedEvent:
            self.portals.handle(event: event.name)
        case "sessions.changed":
            self.applySessionChange(payload)
        case "users.prefs.changed":
            let keys = payload["keys"]?.array?.compactMap(\.string)
            let maps = self.syncedMaps.filter { keys?.contains($0.pref) ?? true && !self.consumeExpectedEcho($0.pref) }
            if !maps.isEmpty { Task { await self.pullMaps(maps) } }
        case "session.reaction":
            guard let key = payload["sessionKey"]?.text else { return }
            for chat in self.chats.values where chat.matchesProgressCardKey(key) { chat.handleReactionEvent(payload) }
        case "chat":
            guard let key = payload["sessionKey"]?.text else { return }
            if let runId = payload["runId"]?.text { self.runSessions[runId] = key }
            self.recordRunActivity(event)
            self.chats[key]?.handleChat(payload)
            if let state = payload["state"]?.string, state == "final" || state == "error" || state == "aborted" {
                self.filesModelCache[key]?.runEnded()
            }
            if payload["state"]?.string == "final" {
                self.notifyReply(sessionKey: key, runId: payload["runId"]?.text, snapshot: payload["message"])
                self.noteReplyLanded(key, runId: payload["runId"]?.text, message: payload["message"])
            }
        case "agent":
            guard let runId = payload["runId"]?.text else { return }
            let key = payload["sessionKey"]?.text ?? self.runSessions[runId]
            self.recordRunActivity(event, sessionKey: key)
            if let key { self.chats[key]?.handleAgent(payload) }
        case "session.message":
            let key = payload["sessionKey"]?.text ?? payload["session"]?["key"]?.text
            if let row = payload["session"].flatMap(SessionRow.init) {
                self.setSession(row.keepingPreview(of: self.sessions[row.key]), for: row.key)
                self.recordReconciledRow(row.key)
            }
            if let key { self.chats[key]?.handleSessionMessage(payload) }
        case "progressCard.changed":
            guard let key = payload["sessionKey"]?.text else { return }
            for chat in self.chats.values where chat.matchesProgressCardKey(key) {
                chat.handleProgressCardChanged(payload)
            }
        case "exec.approval.requested":
            if let approval = ExecApproval(payload) {
                self.approvals.removeAll { $0.id == approval.id }
                self.approvals.append(approval)
                self.notifier?.notifyApproval(approval, gateway: self)
            }
        case "question.requested":
            if let prompt = QuestionPrompt(payload) {
                let isNew = !self.questions.contains { $0.id == prompt.id }
                self.upsertQuestion(prompt)
                if isNew, prompt.isAnswerable() { self.notifier?.notifyQuestion(prompt, gateway: self) }
            }
        case "question.resolved":
            if let id = payload["id"]?.text {
                self.questions.removeAll { $0.id == id }
            }
        case DeviceManagementModel.requestedEvent, DeviceManagementModel.resolvedEvent, DeviceManagementModel.changedEvent,
             DeviceManagementModel.nodeRequestedEvent, DeviceManagementModel.nodeResolvedEvent:
            self.devices.handle(event: event.name, payload: payload)
        case "cron":
            self.automations.handleCronEvent(payload)
        case MCPServers.oauthChangedEvent, MCPServers.statusChangedEvent:
            self.mcp.handle(event)
        case "plugins.changed":
            self.settings.handlePluginsChanged()
        case "health", "heartbeat", "presence", "shutdown":
            self.health.handle(event: event.name, payload: payload)
            if event.name == "health" { self.channels.healthDidChange() }
        case "exec.approval.resolved":
            if let id = payload["id"]?.text ?? payload["request"]?["id"]?.text {
                self.approvals.removeAll { $0.id == id }
                self.clearApprovalNotifications(id)
            }
            self.approvalHistory.handleApprovalResolved()
            self.execPolicy.handleApprovalResolved()
        default:
            break
        }
    }

    func applySessionChange(_ payload: JSONValue) {
        self.sessionManager.handleSessionsChanged(payload)
        if let reason = payload["reason"]?.text, SessionManager.transcriptChangingReasons.contains(reason),
           let key = payload["session"]?["key"]?.text ?? payload["sessionKey"]?.text ?? payload["key"]?.text
        {
            Task { await self.transcriptChanged(key: key, change: .changed(editorText: nil)) }
        }
        if DebugLog.enabled {
            let row = payload["session"]
            let fields = ["pinned", "unread", "color", "category", "label", "archived", "reasoningLevel"]
                .map { "\($0)=\(row?[$0].map { DebugLog.brief(.object(["v": $0])) } ?? "-")" }
            DebugLog.write("← sessions.changed key=\(row?["key"]?.text ?? payload["key"]?.text ?? "?") reason=\(payload["reason"]?.text ?? "-") \(fields.joined(separator: " "))")
        }
        for ancestor in payload["ancestorSessions"]?.array?.compactMap(SessionRow.init) ?? [] {
            self.setSession(ancestor.keepingPreview(of: self.sessions[ancestor.key]), for: ancestor.key)
            self.recordReconciledRow(ancestor.key)
        }
        if let row = payload["session"].flatMap(SessionRow.init) {
            let previous = self.sessions[row.key]
            self.setSession(row.keepingPreview(of: previous), for: row.key)
            self.recordReconciledRow(row.key)
            if self.bootstrapped, let previous, !row.isNestedHelper,
               row.activityMs > previous.activityMs, row.isUnread, !row.hasActiveRun,
               previous.hasActiveRun || !previous.isUnread
            {
                self.notifier?.notifyActivity(row: row, gateway: self)
            }
            return
        }
        let reason = payload["reason"]?.string
        if reason == "groups" {
            self.listReconcile?.needsTrailingRefresh = true
            Task { await self.loadGroups() }
        }
        if let key = payload["key"]?.text ?? payload["sessionKey"]?.text, reason == "delete" || reason == "deleted" {
            let removedId = payload["sessionId"]?.text
            if self.listReconcile != nil {
                self.listReconcile?.rows.removeValue(forKey: key)
                self.listReconcile?.deleted[key] = removedId
            }
            if removedId == nil || self.sessions[key]?.sessionId == removedId {
                self.setSession(nil, for: key)
                Task { await self.transcriptChanged(key: key, change: .deleted) }
                self.discardDraft(key)
                self.outbox.removeSession(key)
                if self.selectedKey == key { self.selectedKey = self.defaultSessionKey }
            }
            return
        }
        self.scheduleRefresh()
    }

    private func notifyReply(sessionKey: String, runId: String?, snapshot: JSONValue?) {
        guard let row = self.sessions[sessionKey], !row.isNestedHelper else { return }
        let text = snapshot.flatMap { ChatItem($0, fallbackIndex: 0) }?.plainText
        self.notifier?.notifyReply(row: row, text: text ?? row.preview, dedupe: runId, gateway: self)
    }

    func track(runId: String, sessionKey: String) {
        self.runSessions[runId] = sessionKey
    }
}
