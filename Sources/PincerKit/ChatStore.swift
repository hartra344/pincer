import Foundation
import Observation

/// Pending attachment in the composer. `data` is already sized for the Gateway's limits.
public struct OutgoingAttachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public init(id: UUID = UUID(), fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }

    public var isImage: Bool { self.mimeType.hasPrefix("image/") }
}

/// Largest attachment the Gateway takes. Base64 inflates ~4/3 and the whole frame must fit
/// `maxPayload`, so both limits stay under 70% of it.
public struct UploadLimits: Sendable, Equatable {
    public let imageBytes: Int
    public let fileBytes: Int

    public init(maxPayload: Int?, maxImageBytes: Int?, maxAttachmentBytes: Int?) {
        let payloadBudget = Int(Double(maxPayload ?? 25_000_000) * 0.7)
        self.imageBytes = min(maxImageBytes ?? 5_000_000, payloadBudget)
        self.fileBytes = min(maxAttachmentBytes ?? 10_000_000, payloadBudget)
    }

    public init(hello: GatewayHello?) {
        self.init(maxPayload: hello?.maxPayload, maxImageBytes: hello?.maxImageBytes, maxAttachmentBytes: hello?.maxAttachmentBytes)
    }
}

/// `chat.send` parameters, shared by the composer and the Share extension.
public enum ChatSendRequest {
    public static func params(
        sessionKey: String,
        agentId: String?,
        message: String,
        idempotencyKey: String,
        attachments: [OutgoingAttachment]) -> [String: JSONValue]
    {
        var params: [String: JSONValue] = ["sessionKey": .string(sessionKey)]
        if let agentId, SessionKey.agentId(from: sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        params["message"] = .string(message)
        params["idempotencyKey"] = .string(idempotencyKey)
        if !attachments.isEmpty {
            params["attachments"] = .array(attachments.map { attachment in
                [
                    "type": .string(attachment.isImage ? "image" : "file"),
                    "mimeType": .string(attachment.mimeType),
                    "fileName": .string(attachment.fileName),
                    "content": .string(attachment.data.base64EncodedString()),
                    "sizeBytes": .number(Double(attachment.data.count)),
                ]
            })
        }
        return params
    }
}

/// Live state of the current run, rendered as a streaming assistant turn.
public struct LiveRun: Sendable, Hashable {
    public var runId: String
    public var text = ""
    public var thinking: String?
    public var tools: [ToolActivity] = []
    public var images: [ImageRef] = []
    public var phase: String?
    public var isCompacting = false
    public var startedAt = Date()
    /// Model named by the streamed snapshot, when the Gateway includes one.
    public var model: String?
    public var provider: String?
}

/// One session's transcript ("channel"). History comes from `chat.history`; live output from
/// `chat` deltas, `agent` tool events and `session.message` transcript appends.
@MainActor
@Observable
public final class ChatStore: Identifiable {
    public nonisolated let sessionKey: String
    public nonisolated var id: String { self.sessionKey }
    public let agentId: String?
    @ObservationIgnored weak var gateway: GatewayStore?

    public private(set) var items: [ChatItem] = [] {
        didSet {
            guard !self.headless else { return }
            self.rebuild(itemsChanged: true)
            self.scheduleSave()
        }
    }
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var live: LiveRun? {
        didSet { self.rebuild(itemsChanged: false) }
    }
    /// Transcript built from committed items; streaming only re-adds the live turn on top.
    @ObservationIgnored private var committedEntries: [TranscriptEntry] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var isSending = false
    public private(set) var hasMoreHistory = false
    public private(set) var isLoadingOlder = false
    public var errorMessage: String?
    /// Whether the transcript contains any reasoning; used to hint at `/reasoning on`.
    public private(set) var sawThinking = false
    /// The agent's task checklist for this session, shown above the composer.
    public private(set) var progressCard: ProgressCard?
    /// Unsent composer text and attachments, kept across chat switches and saved to disk.
    public var draft = ComposerDraft() {
        didSet {
            guard !self.headless, !self.restoringDraft, self.draft != oldValue else { return }
            self.draftEdited = true
            self.scheduleDraftSave()
        }
    }
    /// The latest "Compact now" request, for the composer's context meter.
    public private(set) var compaction: CompactionState? {
        didSet { if oldValue?.isRunning != self.compaction?.isRunning { self.rebuild(itemsChanged: false) } }
    }
    /// The `/compact` run whose end finishes `compaction`, when it was sent as a command.
    @ObservationIgnored private var compactionRunId: String?

    @ObservationIgnored private let historyLimit = 120
    @ObservationIgnored private let gatewayId: UUID
    /// Background cache filler: no UI, no live subscription.
    @ObservationIgnored private let headless: Bool
    @ObservationIgnored private var cacheChecked = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var olderTask: Task<Bool, Never>?
    /// `chat.history` offset (counted back from the newest message) of the next older page.
    @ObservationIgnored private var olderOffset: Int?
    /// Whether older pages have been prepended beyond the latest page.
    @ObservationIgnored private var hasPagedOlder = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var progressCardTask: Task<Void, Never>?
    /// Whether the Gateway serves `progressCard.get`; nil until known. Without it, `plan` stream
    /// events drive the card instead.
    @ObservationIgnored private var progressCardStoreAvailable: Bool?
    @ObservationIgnored private var legacyPlanRevision = 0
    /// Full copies of capped messages by transcript id, re-applied when history re-sends the cap.
    @ObservationIgnored private var fullMessages: [String: ChatItem] = [:]
    /// Capped messages being fetched, or that the Gateway couldn't return in full.
    @ObservationIgnored private var recoveryAttempted: Set<String> = []
    /// Largest text field requested per message, matching the Control UI.
    @ObservationIgnored private let fullMessageMaxChars = 500_000
    @ObservationIgnored private var draftChecked = false
    /// The draft changed here, so a saved one arriving late must not replace it.
    @ObservationIgnored private var draftEdited = false
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var restoringDraft = false

    init(sessionKey: String, agentId: String?, gateway: GatewayStore, headless: Bool = false) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.gateway = gateway
        self.gatewayId = gateway.id
        self.headless = headless
    }

    public var isRunning: Bool {
        self.live != nil || (self.gateway?.sessions[self.sessionKey]?.hasActiveRun ?? false)
    }

    // MARK: Loading

    @ObservationIgnored private var loadInFlight = false

    public func load(force: Bool = false) async {
        await self.restoreDraft()
        await self.restoreFromCache()
        guard let gateway, gateway.state.isConnected else { return }
        if self.hasLoaded, !force { return }
        if self.loadInFlight, !force { return }
        self.loadInFlight = true
        defer { self.loadInFlight = false }
        self.isLoading = !self.hasLoaded
        defer { self.isLoading = false }
        do {
            _ = try? await gateway.connection.request(
                "sessions.messages.subscribe",
                .object(self.params(keyName: "key")),
                timeout: 10)
            var params = self.params(keyName: "sessionKey")
            params["limit"] = .number(Double(self.historyLimit))
            let result = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
            let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
            self.apply(history: result, parsed: parsed)
            self.hasLoaded = true
            self.errorMessage = nil
            self.scheduleSave()
            self.startBackfill()
            self.refreshProgressCard()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Shows the cached transcript before the Gateway answers; the newest page is merged over it.
    private func restoreFromCache() async {
        guard !self.cacheChecked else { return }
        self.cacheChecked = true
        guard let snapshot = await TranscriptCache.load(gatewayId: self.gatewayId, sessionKey: self.sessionKey),
              !snapshot.items.isEmpty, self.items.isEmpty
        else { return }
        // Item count never exceeds the raw message count, so this offset can only overlap (deduped
        // by id), never skip; the first older page's `nextOffset` makes it exact again.
        self.olderOffset = snapshot.items.count
        self.hasMoreHistory = !snapshot.complete
        self.hasPagedOlder = true
        self.items = snapshot.items
    }

    /// Brings back the draft saved on disk, unless one was started here in the meantime.
    private func restoreDraft() async {
        guard !self.draftChecked, !self.headless else { return }
        self.draftChecked = true
        guard let saved = await DraftStore.load(gatewayId: self.gatewayId, sessionKey: self.sessionKey),
              !self.draftEdited
        else { return }
        self.restoringDraft = true
        self.draft = saved
        self.restoringDraft = false
    }

    private func scheduleDraftSave(after delay: Duration = .milliseconds(400)) {
        let previous = self.draftSaveTask
        previous?.cancel()
        let draft = self.draft
        self.draftSaveTask = Task { [gatewayId, sessionKey] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            // Saves land in order, so an older draft never overwrites a newer one.
            await previous?.value
            await DraftStore.save(draft, gatewayId: gatewayId, sessionKey: sessionKey)
        }
    }

    /// Writes a pending draft now, e.g. before the app is suspended.
    public func flushDraft() async {
        guard self.draftSaveTask != nil else { return }
        self.scheduleDraftSave(after: .zero)
        await self.draftSaveTask?.value
    }

    /// Brings the on-disk cache up to date with the full history, without touching the UI.
    func fillCache() async {
        await self.restoreFromCache()
        guard let gateway, gateway.state.isConnected else { return }
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        guard let result = try? await gateway.connection.request("chat.history", .object(params), timeout: 30) else { return }
        let parsed = await Self.parseDetached(result["messages"]?.array ?? [], fallbackBase: 0)
        self.apply(history: result, parsed: parsed)
        self.live = nil
        self.hasLoaded = true
        while self.hasMoreHistory, !Task.isCancelled {
            guard await self.loadOlder() else { return }
        }
        guard !Task.isCancelled else { return }
        await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
    }

    private func snapshot() -> TranscriptCache.Snapshot {
        let committed = self.items.filter { !$0.isPending }
        let kept = committed.suffix(TranscriptCache.maxItems)
        return TranscriptCache.Snapshot(
            items: Array(kept),
            complete: !self.hasMoreHistory && kept.count == committed.count,
            activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs)
    }

    private func scheduleSave() {
        guard self.hasLoaded else { return }
        self.saveTask?.cancel()
        self.saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
        }
    }

    /// Pulls the whole history in right after opening, while you're parked at the bottom, so
    /// scrolling up never waits on the network. Resumes on reconnect if it was cut short.
    private func startBackfill() {
        guard self.backfillTask == nil, self.hasMoreHistory else { return }
        self.backfillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasMoreHistory else { break }
                guard await self.loadOlder() else { break }
            }
            self?.backfillTask = nil
        }
    }

    /// Prepends the next older page, keeping everything already loaded (and its row identity).
    /// Returns false when it couldn't reach the Gateway.
    @discardableResult
    public func loadOlder() async -> Bool {
        // Concurrent callers share the in-flight page rather than returning early and spinning.
        if let inFlight = self.olderTask { return await inFlight.value }
        guard self.hasMoreHistory else { return true }
        guard self.olderOffset != nil else { return false }
        self.isLoadingOlder = true
        let task = Task {
            let ok = await self.fetchOlderPage()
            // Cleared by the task itself so every waiter sees it finished.
            self.olderTask = nil
            self.isLoadingOlder = false
            return ok
        }
        self.olderTask = task
        return await task.value
    }

    private func fetchOlderPage() async -> Bool {
        guard let offset = self.olderOffset, let gateway, gateway.state.isConnected else { return false }
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        params["offset"] = .number(Double(offset))
        do {
            let page = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
            let raw = page["messages"]?.array ?? []
            // Negative fallback indexes keep id-less messages from colliding with the newest page's.
            let older = await Self.parseDetached(raw, fallbackBase: -(offset + raw.count))
            let known = Set(self.items.map(\.id))
            let fresh = older.filter { !known.contains($0.id) }
            self.olderOffset = page["nextOffset"]?.int ?? (offset + older.count)
            self.hasMoreHistory = (page["hasMore"]?.bool ?? (older.count >= self.historyLimit)) && !older.isEmpty
            self.hasPagedOlder = true
            if !fresh.isEmpty { self.items = fresh + self.items }
            self.recoverCappedMessages()
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    /// Parsing a page off the main actor keeps scrolling smooth while history streams in.
    private nonisolated static func parseDetached(_ messages: [JSONValue], fallbackBase: Int) async -> [ChatItem] {
        await Task.detached(priority: .userInitiated) { Self.parse(messages, fallbackBase: fallbackBase) }.value
    }

    private nonisolated static func parse(_ messages: [JSONValue], fallbackBase: Int = 0) -> [ChatItem] {
        var parsed: [ChatItem] = []
        parsed.reserveCapacity(messages.count)
        var seen: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            guard var item = ChatItem(message, fallbackIndex: fallbackBase + index) else { continue }
            let count = seen[item.id, default: 0]
            seen[item.id] = count + 1
            if count > 0 { item.id += "#\(count)" }
            parsed.append(item)
        }
        return parsed
    }

    private func apply(history: JSONValue, parsed: [ChatItem]) {
        let messages = history["messages"]?.array ?? []
        // Keep optimistic sends that the transcript hasn't committed yet.
        let committedKeys = Set(parsed.compactMap(\.idempotencyKey))
        let pending = self.items.filter { $0.isPending && !committedKeys.contains($0.idempotencyKey ?? "") }
        // The latest page replaces the tail; older pages the user scrolled back through stay put.
        // Overlap is found through a transcript id (index-based fallback ids aren't stable across
        // pages); no overlap means the loaded history is stale (e.g. the session was reset).
        var older: [ChatItem] = []
        if self.hasPagedOlder, let anchor = parsed.firstIndex(where: { $0.transcriptId != nil }),
           let match = self.items.firstIndex(where: { $0.transcriptId == parsed[anchor].transcriptId }),
           match >= anchor
        {
            let latest = Set(parsed.map(\.id))
            older = self.items[..<(match - anchor)].filter { !$0.isPending && !latest.contains($0.id) }
        } else {
            self.hasPagedOlder = false
            self.olderOffset = history["nextOffset"]?.int ?? messages.count
            self.hasMoreHistory = history["hasMore"]?.bool ?? (messages.count >= self.historyLimit)
        }
        let merged = older + parsed + pending
        if merged != self.items { self.items = merged }
        self.recoverCappedMessages()

        if let inFlight = history["inFlightRun"], let runId = inFlight["runId"]?.text {
            var run = self.live?.runId == runId ? self.live! : LiveRun(runId: runId)
            if let text = inFlight["text"]?.string, !text.isEmpty { run.text = text }
            self.live = run
            self.gateway?.track(runId: runId, sessionKey: self.sessionKey)
        } else if history["sessionInfo"]?["hasActiveRun"]?.bool == false {
            // A `/compact` run that ended while events were missed (e.g. a reconnect) still settles.
            if let runId = self.compactionRunId, self.live?.runId == runId {
                Task { await self.finishCompaction(runId: runId) }
            }
            self.live = nil
        }
    }

    // MARK: Capped messages

    /// History caps each text field (8,000 chars by default) and flags the message; like the
    /// Control UI, fetch the full copy with `chat.message.get` and swap it in.
    private func recoverCappedMessages() {
        var items = self.items
        var substituted = false
        var missing: [String] = []
        for index in items.indices where items[index].isCapped {
            guard let messageId = items[index].transcriptId else { continue }
            if let full = self.fullMessages[messageId] {
                items[index] = Self.restoring(full, over: items[index])
                substituted = true
            } else if self.recoveryAttempted.insert(messageId).inserted {
                missing.append(messageId)
            }
        }
        if substituted { self.items = items }
        for messageId in missing {
            Task { [weak self] in await self?.fetchFullMessage(messageId) }
        }
    }

    private func fetchFullMessage(_ messageId: String) async {
        guard let gateway, gateway.state.isConnected else {
            self.recoveryAttempted.remove(messageId)
            return
        }
        var params = self.params(keyName: "sessionKey")
        params["messageId"] = .string(messageId)
        params["maxChars"] = .number(Double(self.fullMessageMaxChars))
        let result: JSONValue
        do {
            result = try await gateway.connection.request("chat.message.get", .object(params), timeout: 30)
        } catch {
            // Transport failures retry on the next history pass; Gateway refusals below don't.
            self.recoveryAttempted.remove(messageId)
            return
        }
        guard result["ok"]?.bool == true, let message = result["message"],
              let full = ChatItem(message, fallbackIndex: 0), !full.isCapped
        else { return }
        self.fullMessages[messageId] = full
        guard let index = self.items.firstIndex(where: { $0.transcriptId == messageId && $0.isCapped }) else { return }
        self.items[index] = Self.restoring(full, over: self.items[index])
    }

    /// The full copy with the capped row's identity, so the row keeps its place and scroll anchor.
    private static func restoring(_ full: ChatItem, over capped: ChatItem) -> ChatItem {
        var item = full
        item.id = capped.id
        item.isPending = capped.isPending
        item.idempotencyKey = full.idempotencyKey ?? capped.idempotencyKey
        return item
    }

    private func scheduleReload(after delay: Duration = .milliseconds(250)) {
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.load(force: true)
        }
    }

    // MARK: Sending

    /// Whether the Gateway accepted a `chat.send`. A run id is optional: accepted sends may not have one.
    public enum SendOutcome: Equatable, Sendable {
        case sent(runId: String?)
        case failed(String)
    }

    /// Sends and returns the run id, or nil when there's none or the send failed (see `errorMessage`).
    @discardableResult
    public func send(_ text: String, attachments: [OutgoingAttachment] = []) async -> String? {
        if case let .sent(runId) = await self.sendMessage(text, attachments: attachments) { return runId }
        return nil
    }

    /// Sends, telling an accepted send apart from a failed one.
    @discardableResult
    public func sendMessage(_ text: String, attachments: [OutgoingAttachment] = []) async -> SendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .failed("Couldn’t send: the message is empty.") }
        guard let gateway else { return .failed("Couldn’t send: the Gateway is gone.") }
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
        self.items.append(ChatItem(role: .user, blocks: blocks, idempotencyKey: idempotencyKey, isPending: true))
        self.isSending = true
        defer { self.isSending = false }

        let params = ChatSendRequest.params(
            sessionKey: self.sessionKey, agentId: self.agentId, message: trimmed,
            idempotencyKey: idempotencyKey, attachments: attachments)
        do {
            let result = try await gateway.connection.request("chat.send", .object(params), timeout: 60)
            let runId = result["runId"]?.text
            if let runId {
                gateway.track(runId: runId, sessionKey: self.sessionKey)
                if self.live?.runId != runId { self.live = LiveRun(runId: runId) }
            }
            self.errorMessage = nil
            return .sent(runId: runId)
        } catch {
            self.items.removeAll { $0.idempotencyKey == idempotencyKey && $0.isPending }
            let message = "Couldn’t send: \(error.localizedDescription)"
            self.errorMessage = message
            return .failed(message)
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
            let runId = await self.send(instructions.isEmpty ? "/compact" : "/compact \(instructions)")
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

    private func finishCompaction(runId: String) async {
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
        case "final", "aborted", "error":
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
                    if let result = data["result"] { run.tools[index].result = ContentBlock.prettyJSON(result) }
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
            if phase == "end" || phase == "error" { self.finishRun(runId) }
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
                  let index = self.items.firstIndex(where: { $0.isPending && $0.plainText == item.plainText })
        {
            self.items[index] = item
        } else {
            self.items.append(item)
        }
        self.recoverCappedMessages()
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

    private func finishRun(_ runId: String) {
        guard self.live == nil || self.live?.runId == runId else { return }
        self.reloadTask?.cancel()
        self.reloadTask = Task { [weak self] in
            await self?.load(force: true)
            if self?.live?.runId == runId { self?.live = nil }
            await self?.finishCompaction(runId: runId)
        }
    }

    // MARK: Presentation

    private func rebuild(itemsChanged: Bool) {
        if itemsChanged {
            self.committedEntries = TranscriptBuilder.build(self.items)
            if !self.sawThinking {
                self.sawThinking = self.items.contains { $0.thinkingText != nil }
            }
        }
        var entries = self.committedEntries
        if let live {
            var turn = AssistantTurn(id: "live-\(live.runId)", timestamp: live.startedAt)
            if let thinking = live.thinking { turn.thinking = [thinking] }
            turn.tools = live.tools
            let parsed = MediaDirectives.extract(from: MediaDirectives.withoutPartialDirective(live.text))
            if !parsed.text.isEmpty {
                turn.text = [parsed.text]
                turn.textTimestamps = [live.startedAt]
            }
            turn.images = live.images + parsed.images
            turn.files = parsed.files
            turn.isStreaming = true
            if let model = live.model {
                turn.model = model
                turn.provider = live.provider
            } else if let row = self.gateway?.sessions[self.sessionKey] {
                // Until the reply is committed, it's being written by the session's current model.
                turn.model = row.activeModelRef ?? row.modelRef
            }
            entries.append(.assistant(turn))
            if live.isCompacting { entries.append(.marker(id: "live-compaction-\(live.runId)", label: "Compacting context…")) }
        } else if self.compaction?.isRunning == true {
            entries.append(.marker(id: "live-compaction", label: "Compacting context…"))
        }
        if entries != self.entries { self.entries = entries }
    }

    var liveRunId: String? { self.live?.runId }

    private func params(keyName: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = [keyName: .string(self.sessionKey)]
        if let agentId, SessionKey.agentId(from: self.sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        return params
    }
}
