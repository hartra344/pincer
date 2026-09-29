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
        attachments: [OutgoingAttachment],
        replyToId: String? = nil) -> [String: JSONValue]
    {
        var params: [String: JSONValue] = ["sessionKey": .string(sessionKey)]
        if let agentId, SessionKey.agentId(from: sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        params["message"] = .string(message)
        params["idempotencyKey"] = .string(idempotencyKey)
        if let replyToId { params["replyToId"] = .string(replyToId) }
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
        didSet {
            self.rebuild(itemsChanged: false)
            if (oldValue == nil) != (self.live == nil) { self.updateIsRunning() }
        }
    }
    /// Whether a run is in progress here, streamed or reported by the session row. Stored, and only
    /// written on transitions, so views reading it don't re-render on every streamed token.
    public private(set) var isRunning = false
    /// This chat's session row, kept in step by `GatewayStore` and only written when that row changes,
    /// so views reading it don't re-render when some other session changes.
    public private(set) var sessionRow: SessionRow?
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
    /// The message the composer is replying to. Per chat, in memory only.
    public var replyTarget: ReplyTarget?
    /// A passing, non-error note for the chat's notice bar (not a send failure).
    public var notice: String?
    /// The quoted message being looked for in older history, while paging.
    public private(set) var locatingReplyId: String?
    /// How the latest run ended, and when, for the avatar's transient success and error poses.
    public private(set) var lastOutcome = AvatarOutcome.none
    public private(set) var lastOutcomeAt: Date?
    @ObservationIgnored private var outcomeRunId: String?
    /// Reactions the agent added with its `message` tool, by transcript id.
    public private(set) var agentReactions: [String: [String]] = [:]
    /// Committed items by transcript id.
    @ObservationIgnored private var itemsByTranscriptId: [String: ChatItem] = [:]
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
    /// The session was deleted, so its transcript is never cached again.
    @ObservationIgnored private var cachingStopped = false
    /// What restoring from the transcript cache found; nil until it's been tried.
    @ObservationIgnored private(set) var cacheOutcome: TranscriptCache.LoadOutcome?
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
        self.sessionRow = gateway.sessions[sessionKey]
        self.isRunning = self.sessionRow?.hasActiveRun == true
    }

    func syncSessionRow(_ row: SessionRow?) {
        guard row != self.sessionRow else { return }
        self.sessionRow = row
        self.updateIsRunning()
    }

    private func updateIsRunning() {
        let running = self.live != nil || self.sessionRow?.hasActiveRun == true
        if running != self.isRunning { self.isRunning = running }
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
    /// Without a usable one (missing, or discarded as corrupt, outdated or from a newer app)
    /// nothing is shown: the chat stays loading until the Gateway's history arrives.
    private func restoreFromCache() async {
        guard !self.cacheChecked else { return }
        self.cacheChecked = true
        let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: self.gatewayId, sessionKey: self.sessionKey)
        self.cacheOutcome = outcome
        // Unsent messages shown before the cache arrived stay, after it.
        guard let snapshot, !snapshot.items.isEmpty, self.items.allSatisfy(\.isPending) else { return }
        // Item count never exceeds the raw message count, so this offset can only overlap (deduped
        // by id), never skip; the first older page's `nextOffset` makes it exact again.
        self.olderOffset = snapshot.items.count
        self.hasMoreHistory = !snapshot.complete
        self.hasPagedOlder = true
        self.items = snapshot.items + self.items
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
        Self.snapshot(items: self.items, hasMoreHistory: self.hasMoreHistory,
                      activityMs: self.gateway?.sessions[self.sessionKey]?.activityMs)
    }

    /// Committed items, newest `maxItems` kept; complete only when nothing older was left out.
    nonisolated static func snapshot(items: [ChatItem], hasMoreHistory: Bool, activityMs: Double?,
                                     maxItems: Int = TranscriptCache.maxItems) -> TranscriptCache.Snapshot
    {
        let committed = items.filter { !$0.isPending }
        let kept = committed.suffix(maxItems)
        return TranscriptCache.Snapshot(
            items: Array(kept),
            complete: !hasMoreHistory && kept.count == committed.count,
            activityMs: activityMs)
    }

    /// The Gateway rewrote this chat's history (rewind, branch switch, recovery): drops what's
    /// loaded, including tool details, runs `clearCache` once no save can land, then refetches.
    func reloadAfterHistoryChange(clearingCache clearCache: @MainActor () async -> Void = {}) async {
        self.saveTask?.cancel()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cacheChecked = true
        self.hasPagedOlder = false
        self.olderOffset = nil
        self.hasMoreHistory = false
        self.fullMessages = [:]
        self.recoveryAttempted = []
        let pending = self.items.filter(\.isPending)
        if pending != self.items { self.items = pending }
        self.hasLoaded = false
        await clearCache()
        await self.load(force: true)
    }

    /// The session was deleted: nothing more is written to the transcript cache.
    func stopCaching() {
        self.saveTask?.cancel()
        self.backfillTask?.cancel()
        self.olderTask?.cancel()
        self.cachingStopped = true
    }

    /// The store is going away: writes what's loaded now, then nothing more is cached.
    func finishCaching() async {
        let save = self.hasLoaded && !self.cachingStopped
        self.stopCaching()
        if save { await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey) }
    }

    /// Writes what's loaded to the transcript cache now (after it was cleared).
    func saveToCache() async {
        guard self.hasLoaded, !self.cachingStopped else { return }
        self.saveTask?.cancel()
        await TranscriptCache.save(self.snapshot(), gatewayId: self.gatewayId, sessionKey: self.sessionKey)
    }

    private func scheduleSave() {
        guard self.hasLoaded, !self.cachingStopped else { return }
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
        self.gateway?.reconcileOutbox(committedKeys: committedKeys)
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
    /// stays in the transcript with Retry. Sends with attachments need a connection. With
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
        if !connected, requiresConnection || !attachments.isEmpty {
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
        if !attachments.isEmpty { gateway.outboxAttachments[idempotencyKey] = attachments }
        self.items.append(pending)
        gateway.outbox.enqueue(entry)
        guard connected, gateway.outbox.isHead(id: idempotencyKey) else {
            if requiresConnection || !attachments.isEmpty {
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
        let outcome = await self.deliver(entry, keepFailure: !requiresConnection)
        if case .failed = outcome { return outcome }
        if let replyTo, self.replyTarget == replyTo { self.replyTarget = nil }
        return outcome
    }

    /// Sends one outbox entry now, reusing its idempotency key. On success the entry leaves the
    /// outbox and the message waits for the transcript; on failure it's marked by kind (see
    /// `Outbox.markFailed`), or with `keepFailure` off, dropped along with its row.
    @discardableResult
    func deliver(_ entry: OutboxEntry, keepFailure: Bool = true) async -> SendOutcome {
        guard let gateway else { return .failed("Couldn’t send: the Gateway is gone.") }
        var key = entry.id
        let attachments = gateway.outboxAttachments[key] ?? []
        if entry.hasAttachments, attachments.isEmpty {
            let message = "Couldn’t send: the attachments are no longer available. Delete this message and attach them again."
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
    /// away if it's first in its chat; offline, it stays failed while the Gateway reconnects.
    public func retry(outboxId: String) {
        guard let gateway, let entry = gateway.outbox.entry(id: outboxId), entry.isFailed else { return }
        if entry.hasAttachments {
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

    /// Deletes a queued or failed message; one being sent right now can't be.
    public func deleteQueued(outboxId: String) {
        guard let gateway, let entry = gateway.outbox.entry(id: outboxId), entry.state != .sending else { return }
        gateway.outbox.delete(id: outboxId)
    }

    /// This chat's unsent messages, oldest first.
    public var unsentEntries: [OutboxEntry] {
        self.gateway?.outbox.entries(for: self.sessionKey) ?? []
    }

    private func discardUnsent(_ key: String) {
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
        }
        for entry in entries where !seen.contains(entry.id) {
            var item = ChatItem(id: "outbox:\(entry.id)", role: .user, blocks: entry.text.isEmpty ? [] : [.text(entry.text)],
                                timestamp: entry.createdAt, idempotencyKey: entry.id, isPending: true)
            item.outboxState = entry.state
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
    private func noteOutcome(_ runId: String, _ outcome: AvatarOutcome) {
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
            var byId: [String: ChatItem] = [:]
            for item in self.items where item.isReplyable {
                if let id = item.transcriptId { byId[id] = item }
            }
            self.itemsByTranscriptId = byId
            let reactions = Reactions.agentReactions(in: self.items)
            if reactions != self.agentReactions { self.agentReactions = reactions }
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
                turn.textIds = [nil]
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

    // MARK: Replies

    /// A loaded, committed message by transcript id.
    public func message(withId id: String) -> ChatItem? {
        self.itemsByTranscriptId[id]
    }

    /// What a Reply on `messageId` would target. `you` and `agent` name the senders.
    public func replyTarget(for messageId: String, you: String, agent: String) -> ReplyTarget? {
        guard let item = self.message(withId: messageId) else { return nil }
        let text = MediaDirectives.extract(from: item.plainText).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.isEmpty ? (item.blocks.contains { if case .image = $0 { true } else { false } } ? "Image" : "Attachment") : text
        return ReplyTarget(messageId: messageId, senderLabel: item.senderName(you: you, agent: agent, agents: self.gateway?.agents ?? []),
                           preview: preview, isAssistant: item.role == .assistant)
    }

    /// The newest committed message a reply can target (for ⇧⌘R).
    public var latestReplyableId: String? {
        self.items.last { item in
            item.isReplyable && (item.role == .user || !item.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }?.transcriptId
    }

    /// The quote card for a user turn that replies to another message.
    public func quote(for item: ChatItem) -> ReplyQuote? {
        guard let targetId = item.replyToId else { return nil }
        if let target = self.message(withId: targetId) {
            let line = Replies.previewLine(MediaDirectives.extract(from: target.plainText).text)
            let sender: ReplyQuote.Sender = if let from = target.sender {
                .label(from.displayName(agents: self.gateway?.agents ?? []))
            } else {
                target.role == .user ? .you : .agent
            }
            return ReplyQuote(targetId: targetId, sender: sender,
                              text: line.isEmpty ? item.replyToPreview?.text : line)
        }
        if let preview = item.replyToPreview {
            return ReplyQuote(targetId: targetId, sender: preview.senderLabel.map { .label($0) },
                              text: Replies.previewLine(preview.text))
        }
        return ReplyQuote(targetId: targetId, sender: nil, text: nil)
    }

    /// Loads older history until the message is loaded (at most 40 pages). Returns whether it is;
    /// when history runs out or the page cap is hit, says so in `notice`. One lookup at a time.
    @discardableResult
    public func locate(_ id: String) async -> Bool {
        if self.message(withId: id) != nil { return true }
        guard self.locatingReplyId == nil else { return false }
        self.locatingReplyId = id
        defer { self.locatingReplyId = nil }
        for _ in 0..<40 where self.hasMoreHistory {
            guard await self.loadOlder() else { return false }
            if self.message(withId: id) != nil { return true }
        }
        if self.message(withId: id) != nil { return true }
        self.notice = self.hasMoreHistory
            ? "The original message is too far back to show."
            : "The original message isn't in this chat's history anymore."
        return false
    }

    // MARK: Reactions

    /// Emoji reactions on one message: the agent's first, then yours.
    public func reactionGroups(for messageId: String, agentName: String) -> [ReactionGroup] {
        let mine = self.gateway?.myReactions(sessionKey: self.sessionKey, messageId: messageId) ?? []
        return Reactions.groups(agent: self.agentReactions[messageId] ?? [], agentName: agentName, mine: mine)
    }

    /// Your latest message while the agent works on it, for the transient 👀.
    public var ackMessageId: String? {
        Reactions.ackTarget(items: self.items, isRunning: self.isRunning, runId: self.live?.runId,
                            agentReactions: self.agentReactions)
    }

    /// Adds `emoji` to the message, or removes it when it's already yours. Syncs through
    /// `users.prefs`, and mirrors it to the bridged channel's message when the Gateway can.
    public func toggleReaction(_ emoji: String, on messageId: String) {
        guard let gateway, let item = self.message(withId: messageId) else { return }
        let mine = gateway.myReactions(sessionKey: self.sessionKey, messageId: messageId)
        let removing = mine.contains(emoji)
        if !removing { Reactions.noteRecent(emoji) }
        gateway.setReactions(Reactions.toggling(emoji, in: mine), sessionKey: self.sessionKey, messageId: messageId)
        self.forwardReaction(emoji, remove: removing, on: item)
    }

    private func forwardReaction(_ emoji: String, remove: Bool, on item: ChatItem) {
        guard let gateway, gateway.supportsMessageAction, item.role == .user,
              let channelMessageId = item.channelMessageId
        else { return }
        let row = gateway.sessions[self.sessionKey]
        guard let sessionChannel = row?.channel ?? row?.raw["lastChannel"]?.text ?? item.transportChannel,
              sessionChannel != "webchat", sessionChannel != "internal"
        else { return }
        let channel = item.transportChannel ?? sessionChannel
        guard !gateway.reactionForwardingOff.contains(channel) else { return }
        let params = Reactions.messageActionParams(
            channel: channel, sessionKey: self.sessionKey, channelMessageId: channelMessageId, emoji: emoji,
            remove: remove, conversationRef: item.conversationRef, idempotencyKey: UUID().uuidString.lowercased())
        let epoch = gateway.connectionEpoch
        Task { [weak self, weak gateway] in
            do {
                _ = try await gateway?.connection.request("message.action", .object(params), timeout: 30)
            } catch {
                guard let self, let gateway, gateway.connectionEpoch == epoch else { return }
                if Reactions.isUnsupported(error) { gateway.reactionForwardingOff.insert(channel) }
                if gateway.reactionNoticeShown.insert(self.sessionKey).inserted {
                    self.notice = "Couldn't add the reaction in \(channel.capitalized). It's saved in Pincer only."
                }
            }
        }
    }

    private func params(keyName: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = [keyName: .string(self.sessionKey)]
        if let agentId, SessionKey.agentId(from: self.sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        return params
    }
}
