import Foundation
import Observation

extension ChatStore {
    // MARK: Events

    func handleChat(_ payload: JSONValue) {
        guard let runId = payload["runId"]?.text else { return }
        let state = payload["state"]?.string ?? ""
        switch state {
        case "status":
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            run.phase = payload["phase"]?.string
            self.live = run
        case "delta":
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            run.phase = nil
            if let snapshot = payload["message"], snapshot.object != nil,
               let item = ChatItem(snapshot, fallbackIndex: 0)
            {
                // The cumulative snapshot carries thinking and images as well as text.
                let text = item.plainText
                if !text.isEmpty { run.text = text }
                if let model = item.model {
                    run.model = model
                    run.provider = item.provider
                }
                if let thinking = item.thinkingText { run.thinking = thinking; self.sawThinking = true }
                let images = item.blocks.compactMap { block -> ImageRef? in
                    if case let .image(ref) = block { return ref }
                    return nil
                }
                if !images.isEmpty { run.images = images }
            } else if let delta = payload["deltaText"]?.string {
                run.text = payload["replace"]?.bool == true ? delta : run.text + delta
            }
            self.live = run
            if payload["replace"]?.bool == true { self.flushLive() }
        case "final", "aborted", "error":
            self.noteOutcome(runId, state == "final" ? .success : state == "error" ? .error : .none)
            if state == "error" {
                self.errorMessage = payload["errorMessage"]?.text ?? "The run failed."
            }
            if state != "final", runId == self.compactionRunId {
                self.compactionRunId = nil
                self.compaction = .failed(state == "error" ? self.errorMessage ?? "Compaction failed." : "Compaction was stopped.")
            }
            self.finishRun(runId)
        default:
            break
        }
    }

    func handleAgent(_ payload: JSONValue) {
        guard let runId = payload["runId"]?.text, let stream = payload["stream"]?.string else { return }
        let data = payload["data"] ?? .null
        switch stream {
        case "tool":
            guard let callId = data["toolCallId"]?.text else { return }
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            let phase = data["phase"]?.string
            if let index = run.tools.firstIndex(where: { $0.id == callId }) {
                if phase == "result" {
                    run.tools[index].isRunning = false
                    run.tools[index].isError = data["isError"]?.bool ?? false
                    if let result = data["result"] {
                        run.tools[index].result = ContentBlock.prettyJSON(result)
                        run.tools[index].details = ToolActivity.fileEditDetails(result["details"] ?? data["details"])
                    }
                }
            } else if phase == "start" {
                run.tools.append(ToolActivity(
                    id: callId,
                    name: data["name"]?.text ?? "tool",
                    arguments: data["args"].flatMap(ContentBlock.prettyJSON),
                    result: nil,
                    isError: false,
                    isRunning: true))
            }
            self.live = run
        case "assistant":
            guard let text = data["text"]?.string, var run = self.live, run.runId == runId else { return }
            if run.text.isEmpty || text.count >= run.text.count { run.text = text }
            self.live = run
        case "thinking", "reasoning":
            guard var run = self.live, run.runId == runId, let text = data["text"]?.string else { return }
            run.thinking = text
            self.sawThinking = true
            self.live = run
        case "compaction":
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            let phase = data["phase"]?.string
            run.isCompacting = phase == "start"
            self.live = run
            // The persisted marker lands in the transcript once compaction finishes.
            if phase == "end" { self.scheduleReload(after: .milliseconds(500)) }
        case "lifecycle":
            let phase = data["phase"]?.string
            if phase == "end" || phase == "error" {
                // The Gateway ends a stopped run with `phase: end, aborted: true`: neither outcome.
                let outcome: AvatarOutcome = phase == "error" ? .error : data["aborted"]?.bool == true ? .none : .success
                self.noteOutcome(runId, outcome)
                self.finishRun(runId)
            }
        case "plan":
            // Durable cards are authoritative; this stream only stands in on Gateways without them.
            guard self.progressCardStoreAvailable == false, data["phase"]?.string == "update" else { return }
            self.legacyPlanRevision += 1
            self.progressCard = ProgressCard(legacyPlan: data, revision: self.legacyPlanRevision)
        default:
            break
        }
    }

    func handleSessionMessage(_ payload: JSONValue) {
        // A dehydrated chat has no transcript to append to; the next load fetches what it missed.
        guard !self.isDehydrated else {
            self.stale = true
            return
        }
        guard let message = payload["message"], let item = ChatItem(message, fallbackIndex: self.items.count) else {
            self.scheduleReload()
            return
        }
        if let transcriptId = item.transcriptId,
           let index = self.items.firstIndex(where: { $0.transcriptId == transcriptId })
        {
            self.items[index] = item
        } else if let key = item.idempotencyKey,
                  let index = self.items.firstIndex(where: { $0.isPending && $0.idempotencyKey == key })
        {
            self.items[index] = item
        } else if item.role == .user,
                  let index = self.items.firstIndex(where: { $0.isAwaitingDelivery && $0.plainText == item.plainText })
        {
            self.items[index] = item
        } else {
            self.items.append(item)
        }
        self.recoverCappedMessages()
        if let key = item.idempotencyKey { self.gateway?.reconcileOutbox(committedKeys: [key]) }
        if item.thinkingText != nil { self.sawThinking = true }
        if var run = self.live, item.role == .assistant || item.role == .toolResult {
            // Committed output supersedes the streamed preview of the same step.
            let committedToolIds = Set(item.blocks.compactMap { block -> String? in
                if case let .toolCall(id, _, _) = block { return id }
                return nil
            } + [item.toolCallId].compactMap { $0 })
            if item.role == .assistant {
                run.text = ""
                run.thinking = nil
                run.images = []
            }
            run.tools.removeAll { committedToolIds.contains($0.id) }
            self.live = run
        }
    }

    // MARK: Progress card

    /// Whether a `progressCard.changed` key names this session. Cards are keyed by the qualified
    /// `agent:<id>:<rest>` form even when the chat uses a bare key.
    func matchesProgressCardKey(_ key: String) -> Bool {
        let key = key.lowercased()
        let own = self.sessionKey.lowercased()
        if key == own { return true }
        guard SessionKey.agentId(from: own) == nil, let agentId = self.agentId ?? SessionKey.agentId(from: key)
        else { return false }
        return key == "agent:\(agentId.lowercased()):\(own)"
    }

    func handleProgressCardChanged(_ payload: JSONValue) {
        if let revision = payload["revision"]?.int, let card = self.progressCard, card.revision >= revision,
           self.progressCardStoreAvailable == true
        {
            return
        }
        self.refreshProgressCard()
    }

    /// Reads the durable card. Only the latest read may publish, so a slow reply can't overwrite a newer one.
    func refreshProgressCard() {
        guard let gateway, gateway.state.isConnected, !self.headless else { return }
        if let methods = gateway.hello?.methods, !methods.isEmpty, !methods.contains("progressCard.get") {
            self.progressCardStoreAvailable = false
            return
        }
        self.progressCardTask?.cancel()
        self.progressCardTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.connection.request(
                    "progressCard.get", .object(self.params(keyName: "sessionKey")), timeout: 15)
                guard !Task.isCancelled else { return }
                self.progressCardStoreAvailable = true
                let card = result["card"].flatMap(ProgressCard.init)
                if card != self.progressCard { self.progressCard = card }
            } catch {
                guard !Task.isCancelled else { return }
                // Older Gateways reject the method (or its scope); fall back to the plan stream.
                if self.progressCardStoreAvailable == nil { self.progressCardStoreAvailable = false }
            }
        }
    }

    /// Clears a finished card. The revision guard keeps a newer update from being dismissed unseen.
    public func dismissProgressCard() async {
        guard let gateway, let card = self.progressCard else { return }
        guard self.progressCardStoreAvailable == true else {
            self.progressCard = nil
            return
        }
        var params = self.params(keyName: "sessionKey")
        params["expectedRevision"] = .number(Double(card.revision))
        do {
            let result = try await gateway.connection.request("progressCard.put", .object(params), timeout: 15)
            let next = result["card"].flatMap(ProgressCard.init)
            if self.progressCard?.revision == card.revision || next == nil { self.progressCard = next }
        } catch {
            self.refreshProgressCard()
        }
    }

    /// Records how a run ended, once per run (its `chat` final and `lifecycle` end both report it).
    func noteOutcome(_ runId: String, _ outcome: AvatarOutcome) {
        guard self.outcomeRunId != runId else { return }
        self.outcomeRunId = runId
        self.lastOutcome = outcome
        self.lastOutcomeAt = outcome == .none ? nil : Date()
    }

    /// Inputs for the agent's avatar; derive its state with `AvatarStateMachine`.
    public var avatarSignals: AvatarSignals {
        // A run that has ended stays live until its reload lands; it's done, not still replying.
        let live = self.live.flatMap { $0.runId == self.outcomeRunId ? nil : $0 }
        let runningTool = live?.tools.last(where: \.isRunning)?.name
        let streaming = !(live?.text.isEmpty ?? true)
        let compacting = live?.isCompacting == true || self.compaction?.isRunning == true
        return AvatarSignals(
            isRunning: self.live != nil && live == nil ? false : self.isRunning,
            isThinking: live != nil && runningTool == nil && !streaming && !compacting,
            isStreaming: streaming,
            runningToolName: runningTool,
            awaitingApproval: self.gateway?.approvals.contains { $0.sessionKey == self.sessionKey } ?? false,
            isCompacting: compacting,
            lastOutcome: self.lastOutcome,
            outcomeAt: self.lastOutcomeAt)
    }

    func finishRun(_ runId: String) {
        self.flushLive()
        guard self.live == nil || self.live?.runId == runId else { return }
        if self.finishedRunIds.contains(runId) { return }
        guard self.isSubscribed else {
            // A background chat: reload when it is opened instead of resubscribing.
            self.markStale()
            if self.live?.runId == runId { self.live = nil }
            return
        }
        self.finishedRunIds.append(runId)
        if self.finishedRunIds.count > 32 { self.finishedRunIds.removeFirst(self.finishedRunIds.count - 32) }
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            let before = self?.loadCount
            await self?.load(force: true)
            guard !Task.isCancelled else { return }
            // A failed or cancelled reload must not swallow the run's only history read.
            if let self, self.loadCount == before {
                self.finishedRunIds.removeAll { $0 == runId }
                self.stale = true
            }
            if self?.live?.runId == runId { self?.live = nil }
            await self?.finishCompaction(runId: runId)
        }
    }
}
