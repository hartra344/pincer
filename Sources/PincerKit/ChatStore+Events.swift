import Foundation
import Observation

extension ChatStore {
    // MARK: Events

    func handleChat(_ payload: JSONValue) {
        guard let runId = payload["runId"]?.text else { return }
        let state = payload["state"]?.string ?? ""
        switch state {
        case "status":
            self.awaitingFinalReply = false
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            run.phase = payload["phase"]?.string
            if run.phase == "thinking" { run.isTextStreaming = false }
            self.live = run
        case "delta":
            self.awaitingFinalReply = false
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            run.phase = nil
            if let snapshot = payload["message"], snapshot.object != nil,
               let item = ChatItem(snapshot, fallbackIndex: 0)
            {
                // The cumulative snapshot carries thinking and images as well as text.
                let text = item.plainText
                let hadPriorText = run.textUTF8Count > 0
                if payload["replace"]?.bool == true {
                    run.text = text
                    run.textUTF8Count = text.utf8.count
                    run.isTextStreaming = !text.isEmpty
                    run.pendingReplyDirective = nil
                    run.replyLexicalState.reset()
                } else if !text.isEmpty {
                    let textUTF8Count = text.utf8.count
                    let grew = textUTF8Count > run.textUTF8Count
                    if let delta = payload["deltaText"]?.string, !delta.isEmpty {
                        run.text = text
                        run.textUTF8Count = textUTF8Count
                        run.isTextStreaming = true
                    } else if grew {
                        run.text = text
                        run.textUTF8Count = textUTF8Count
                        run.isTextStreaming = true
                    } else {
                        run.text = text
                        run.textUTF8Count = textUTF8Count
                    }
                }
                self.updatePendingReplyDirective(&run, delta: payload["deltaText"]?.string, snapshotText: text,
                                                 establishLexicalContext: !hadPriorText && (payload["deltaText"]?.string?.isEmpty ?? true))
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
                if payload["replace"]?.bool == true {
                    run.replyLexicalState.reset()
                    run.replyDirectiveLexBytes += delta.utf8.count
                    _ = run.replyLexicalState.advance(delta)
                    let parsed = delta.contains("[[") ? Replies.extractStreamingDirective(delta) : nil
                    if parsed != nil { run.replyDirectiveParseBytes += delta.utf8.count }
                    run.text = parsed?.target == nil ? delta : parsed?.text ?? delta
                    run.textUTF8Count = run.text.utf8.count
                    run.isTextStreaming = !run.text.isEmpty
                    run.pendingReplyDirective = nil
                    if let candidate = parsed?.pending, run.text.hasSuffix(candidate) {
                        let start = run.text.utf8.count - candidate.utf8.count
                        run.pendingReplyDirective = Replies.PendingDirective(
                            text: candidate, startUTF8: start)
                    }
                } else if !delta.isEmpty {
                    let previousCount = run.textUTF8Count
                    run.text += delta
                    run.textUTF8Count += delta.utf8.count
                    run.isTextStreaming = true
                    self.filterReplyDirective(&run, delta: delta, previousCount: previousCount)
                }
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
            if state == "final" { self.noteRunSucceeded(runId) } else { self.dropPendingReply() }
        default:
            break
        }
    }

    private func updatePendingReplyDirective(_ run: inout LiveRun, delta: String?, snapshotText: String,
                                             establishLexicalContext: Bool) {
        let scanText = delta.flatMap { $0.isEmpty ? nil : $0 } ?? (establishLexicalContext ? snapshotText : nil)
        if let scanText { run.replyDirectiveLexBytes += scanText.utf8.count }
        let markers: [Replies.StreamMarker]
        if let scanText {
            markers = run.replyLexicalState.advance(scanText)
            run.replyDirectiveLexBytes += run.replyLexicalState.lookaheadBytes
        } else {
            markers = []
        }
        if let pending = run.pendingReplyDirective {
            let byteCount = snapshotText.utf8.count
            if pending.startUTF8 <= byteCount {
                let rest = snapshotText.utf8.dropFirst(pending.startUTF8)
                let remainingCount = byteCount - pending.startUTF8
                guard remainingCount <= 4_096 else {
                    run.pendingReplyDirective = nil
                    return
                }
                guard rest.prefix(pending.text.utf8.count).elementsEqual(pending.text.utf8) else {
                    run.pendingReplyDirective = nil
                    return
                }
                let candidate = String(decoding: rest, as: UTF8.self)
                run.replyDirectiveParseBytes += remainingCount
                if !candidate.contains("]]"), !candidate.contains("\n") {
                    run.pendingReplyDirective = Replies.PendingDirective(text: candidate,
                                                                         startUTF8: pending.startUTF8)
                } else {
                    run.pendingReplyDirective = nil
                }
            } else {
                run.pendingReplyDirective = nil // A complete snapshot was already normalized by ChatItem.
            }
        }
        guard let marker = markers.last else { return }
        let candidate = Self.directiveCandidate(startUTF8: marker.startUTF8, in: scanText ?? "")
        run.replyDirectiveParseBytes += candidate.utf8.count
        let parsed = Replies.extractStreamingDirective(candidate)
        guard let pending = parsed.pending, snapshotText.hasSuffix(pending) else { return }
        let start = snapshotText.utf8.count - pending.utf8.count
        run.pendingReplyDirective = Replies.PendingDirective(text: pending, startUTF8: start)
    }

    private func filterReplyDirective(_ run: inout LiveRun, delta: String, previousCount: Int) {
        run.replyDirectiveLexBytes += delta.utf8.count
        let markers = run.replyLexicalState.advance(delta)
        run.replyDirectiveLexBytes += run.replyLexicalState.lookaheadBytes
        var ranges: [Range<Int>] = []
        var pendingConsumedByteCount = 0
        if var pending = run.pendingReplyDirective {
            let close = delta.range(of: "]]" )
            let splitClose = pending.text.hasSuffix("]") && delta.hasPrefix("]")
            if close != nil || splitClose {
                let candidate = pending.text + (splitClose ? "]" : String(delta[..<close!.upperBound]))
                if candidate.utf8.count <= 4_096 {
                    run.replyDirectiveParseBytes += candidate.utf8.count
                    let parsed = Replies.extractStreamingDirective(candidate)
                    if let targetRange = parsed.targetRangeUTF8 {
                        ranges.append((pending.startUTF8 + targetRange.lowerBound)..<(pending.startUTF8 + targetRange.upperBound))
                    }
                    pendingConsumedByteCount = splitClose ? 1 : String(delta[..<close!.upperBound]).utf8.count
                }
                run.pendingReplyDirective = nil
            } else if pending.text.utf8.count + delta.utf8.count <= 4_096, markers.isEmpty {
                pending.text += delta
                run.pendingReplyDirective = pending
                return
            } else {
                run.pendingReplyDirective = nil
            }
        }

        var consumedThroughByte = pendingConsumedByteCount == 0 ? -1 : pendingConsumedByteCount
        for marker in markers {
            guard marker.startUTF8 >= consumedThroughByte else { continue }
            let candidate = Self.directiveCandidate(startUTF8: marker.startUTF8, in: delta)
            run.replyDirectiveParseBytes += candidate.utf8.count
            let parsed = Replies.extractStreamingDirective(candidate)
            consumedThroughByte = marker.startUTF8 + candidate.utf8.count
            if let targetRange = parsed.targetRangeUTF8 {
                let start = previousCount + marker.startUTF8 + targetRange.lowerBound
                ranges.append(start..<(previousCount + marker.startUTF8 + targetRange.upperBound))
            } else if let pending = parsed.pending, marker.startUTF8 == markers.last?.startUTF8, run.text.hasSuffix(pending) {
                let start = run.text.utf8.count - pending.utf8.count
                run.pendingReplyDirective = Replies.PendingDirective(text: pending, startUTF8: start)
            }
        }
        if !ranges.isEmpty {
            run.text = Self.removingReplyDirectives(ranges, from: run.text)
            run.textUTF8Count = run.text.utf8.count
            if var pending = run.pendingReplyDirective {
                let tail = String(decoding: run.text.utf8.suffix(pending.text.utf8.count), as: UTF8.self)
                if !tail.isEmpty, pending.text.hasPrefix(tail) {
                    pending.text = tail
                    pending.startUTF8 = run.text.utf8.count - tail.utf8.count
                    run.pendingReplyDirective = pending
                } else {
                    run.pendingReplyDirective = nil
                }
            }
        }
    }

    private static func directiveCandidate(startUTF8: Int, in text: String) -> String {
        let prefix = startUTF8 < 0 ? "[" : ""
        let offset = max(0, startUTF8)
        let available = text.utf8.dropFirst(offset).prefix(4_096 - prefix.utf8.count)
        let suffix = String(decoding: available, as: UTF8.self)
        let candidate = prefix + suffix
        guard let close = candidate.range(of: "]]" ) else { return candidate }
        return String(candidate[..<close.upperBound])
    }

    private static func removingReplyDirectives(_ ranges: [Range<Int>], from text: String) -> String {
        let bytes = text.utf8
        var result = String()
        result.reserveCapacity(text.utf8.count)
        var cursor = 0
        var leadingWhitespace = true
        for range in ranges {
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count else { continue }
            let start = Self.stringIndex(utf8Offset: cursor, in: text)
            let end = Self.stringIndex(utf8Offset: range.lowerBound, in: text)
            let between = text[start..<end]
            result += between
            if leadingWhitespace, !between.allSatisfy(\.isWhitespace) {
                leadingWhitespace = false
            }
            var after = range.upperBound
            while after < bytes.count,
                  (bytes[bytes.index(bytes.startIndex, offsetBy: after)] == 0x20 || bytes[bytes.index(bytes.startIndex, offsetBy: after)] == 0x09) {
                after += 1
            }
            if leadingWhitespace || after < bytes.count && bytes[bytes.index(bytes.startIndex, offsetBy: after)] == 0x0A {
                cursor = after
            } else {
                cursor = range.upperBound
            }
        }
        result += text[Self.stringIndex(utf8Offset: cursor, in: text)...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringIndex(utf8Offset: Int, in text: String) -> String.Index {
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
        return String.Index(index, within: text)!
    }

    func handleAgent(_ payload: JSONValue) {
        guard let runId = payload["runId"]?.text, let stream = payload["stream"]?.string else { return }
        let data = payload["data"] ?? .null
        switch stream {
        case "tool":
            guard let callId = data["toolCallId"]?.text else { return }
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            let phase = data["phase"]?.string
            if phase == "start" || phase == "result" { run.isTextStreaming = false }
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
            guard var run = self.live, run.runId == runId else { return }
            let hasDelta = data["delta"]?.string.map { !$0.isEmpty } ?? false
            guard let text = data["text"]?.string else {
                if hasDelta { run.isTextStreaming = true; self.live = run }
                return
            }
            let wasTextEmpty = run.text.isEmpty
            let textUTF8Count = text.utf8.count
            let grew = textUTF8Count > run.textUTF8Count
            if data["replace"]?.bool == true || run.text.isEmpty || textUTF8Count >= run.textUTF8Count {
                run.text = text
                run.textUTF8Count = textUTF8Count
            }
            if data["replace"]?.bool == true { run.isTextStreaming = !text.isEmpty }
            else if hasDelta || grew || (wasTextEmpty && !text.isEmpty) { run.isTextStreaming = true }
            self.live = run
        case "thinking", "reasoning":
            guard var run = self.live, run.runId == runId, let text = data["text"]?.string else { return }
            run.thinking = text
            run.isTextStreaming = false
            self.sawThinking = true
            self.live = run
        case "compaction":
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            let phase = data["phase"]?.string
            run.isCompacting = phase == "start"
            if run.isCompacting { run.isTextStreaming = false }
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
                if outcome == .success { self.noteRunSucceeded(runId) } else { self.dropPendingReply() }
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
            self.trackLiveReply(item)
        }
        self.scheduleLegacyLocationProjection(item)
        // A committed user message is a persistence boundary: search must see it while its
        // reply is still streaming. Later assistant output uses the bounded live-save window.
        if item.role == .user { self.flushScheduledSave() }
        if let key = item.idempotencyKey {
            self.releaseCommittedOutboxImagePreviews([key])
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
                run.textUTF8Count = 0
                run.isTextStreaming = false
                run.thinking = nil
                run.images = []
            }
            run.tools.removeAll { committedToolIds.contains($0.id) }
            self.live = run
        }
    }

    /// Legacy rows are rare; normal live messages pay a 256-character suffix check only.
    /// Revision tokens prevent an old worker result replacing a newer event for the same ID.
    /// Sixteen outstanding workers bound memory; overflow is cleaned by the existing worker history load.
    private func scheduleLegacyLocationProjection(_ item: ChatItem) {
        self.legacyLocationProjectionTokens.removeValue(forKey: item.id)
        guard item.role == .user, item.sender == nil,
              item.blocks.contains(where: { block in
                  if case let .text(text) = block { return ChatWorkContext.mayHaveLegacyFooter(text) }
                  return false
              }) else { return }
        guard self.legacyLocationProjectionWorkerCount < 16 else {
            self.scheduleReload()
            return
        }
        let token = UUID()
        self.legacyLocationProjectionTokens[item.id] = token
        self.legacyLocationProjectionWorkerCount += 1
        let revision = self.contentRevision
        Task { [weak self] in
            let projected = await Task.detached(priority: .utility) {
                var projected = item
                projected.projectLegacyLocationForDisplay()
                return projected
            }.value
            guard let self else { return }
            self.legacyLocationProjectionWorkerCount -= 1
            guard self.legacyLocationProjectionTokens[item.id] == token else { return }
            self.legacyLocationProjectionTokens.removeValue(forKey: item.id)
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            guard self.contentRevision == revision else {
                self.scheduleLegacyLocationProjection(self.items[index])
                return
            }
            // Finished text only; current row identity, media, reply fields and transport facts stay intact.
            self.items[index].blocks = projected.blocks
        }
    }

    /// Remembers live assistant text so the run's last reply can be handed to auto-read when the run succeeds.
    private func trackLiveReply(_ item: ChatItem) {
        if item.role == .user { self.dropPendingReply(); return }
        guard item.role == .assistant, !item.isPending, SpeechText.speakableText(for: item) != nil else { return }
        if self.awaitingFinalReply {
            self.awaitingFinalReply = false
            self.onFinalAssistantReply?(item)
        } else {
            self.liveReplyCandidate = item
        }
    }

    func dropPendingReply() {
        self.liveReplyCandidate = nil
        self.awaitingFinalReply = false
    }

    /// A run ended successfully: auto-read speaks its last reply, now or when it arrives.
    func noteRunSucceeded(_ runId: String) {
        guard self.autoReadRunId != runId else { return }
        self.autoReadRunId = runId
        if let item = self.liveReplyCandidate {
            self.liveReplyCandidate = nil
            self.onFinalAssistantReply?(item)
        } else {
            self.awaitingFinalReply = true
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
        let streaming = live?.isTextStreaming == true
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
        self.flushScheduledSave()
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
            // The final reply had until now to arrive; a later message isn't this run's.
            self?.awaitingFinalReply = false
            await self?.finishCompaction(runId: runId)
        }
    }
}
