import Foundation
import Observation

/// Pending attachment in the composer. `data` is already sized for the Gateway's limits.
public struct OutgoingAttachment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let mimeType: String
    public let data: Data
    /// Identifies this immutable payload instance for local preview work. It is deliberately
    /// excluded from equality and hashing, which keep their existing upload semantics.
    public let previewIdentity: UUID

    public init(id: UUID = UUID(), fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        self.previewIdentity = UUID()
    }

    public var isImage: Bool { self.mimeType.hasPrefix("image/") }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.fileName == rhs.fileName && lhs.mimeType == rhs.mimeType && lhs.data == rhs.data
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
        hasher.combine(self.fileName)
        hasher.combine(self.mimeType)
        hasher.combine(self.data)
    }
}

/// The Gateway's upload policy from its hello, saved per Gateway so limits are known offline.
public struct UploadPolicy: Codable, Equatable, Sendable {
    public var maxPayload: Int?
    public var maxImageBytes: Int?
    public var maxAttachmentBytes: Int?

    public init(maxPayload: Int? = nil, maxImageBytes: Int? = nil, maxAttachmentBytes: Int? = nil) {
        self.maxPayload = maxPayload
        self.maxImageBytes = maxImageBytes
        self.maxAttachmentBytes = maxAttachmentBytes
    }

    public init(hello: GatewayHello) {
        self.init(maxPayload: hello.maxPayload, maxImageBytes: hello.maxImageBytes, maxAttachmentBytes: hello.maxAttachmentBytes)
    }
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

    /// Limits from a saved or live policy; without one, the defaults.
    public init(policy: UploadPolicy?) {
        self.init(maxPayload: policy?.maxPayload, maxImageBytes: policy?.maxImageBytes, maxAttachmentBytes: policy?.maxAttachmentBytes)
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
        replyToId: String? = nil, locationContext: LocationContextSnapshot? = nil) -> [String: JSONValue]
    {
        var params: [String: JSONValue] = ["sessionKey": .string(sessionKey)]
        if let agentId, SessionKey.agentId(from: sessionKey) == nil {
            params["agentId"] = .string(agentId)
        }
        params["message"] = .string(message)
        params["idempotencyKey"] = .string(idempotencyKey)
        if let replyToId { params["replyToId"] = .string(replyToId) }
        if let locationContext, !ChatWorkContext.isCommand(message) {
            params["workContext"] = ChatWorkContext.location(locationContext)
        }
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
    /// Whether the latest run event is actively advancing assistant text.
    public var isTextStreaming = false
    /// UTF-8 byte count is O(1) to read and lets cumulative snapshots signal growth without rescanning.
    var textUTF8Count = 0
    /// A reply directive that began at the end of a streamed frame and is still incomplete.
    var pendingReplyDirective: Replies.PendingDirective?
    /// Incremental Markdown state needed to keep code literals safe across delta boundaries.
    var replyLexicalState = Replies.StreamLexicalState()
    /// Bytes parsed as reply candidates (separate from the linear lexical pass over each new delta).
    var replyDirectiveParseBytes = 0
    /// Bytes visited by the incremental lexical scanner; this must scale with incoming deltas only.
    var replyDirectiveLexBytes = 0
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

    public internal(set) var items: [ChatItem] = [] {
        didSet {
            if self.items != oldValue { self.contentRevision += 1 }
            guard !self.headless else { return }
            self.rebuild(itemsChanged: true)
            self.scheduleSave()
        }
    }
    public internal(set) var entries: [TranscriptEntry] = []
    public internal(set) var live: LiveRun? {
        didSet {
            self.liveChanged(from: oldValue)
            if (oldValue == nil) != (self.live == nil) { self.updateIsRunning() }
        }
    }
    /// Minimum time between published transcripts while text or thinking streams in (60 Hz cap).
    nonisolated(unsafe) static var liveFlushInterval: TimeInterval = 1.0 / 60
    @ObservationIgnored var lastPublishAt = Date.distantPast
    @ObservationIgnored var pendingFlush: Task<Void, Never>?
    @ObservationIgnored var outboxImagePreviews = OutboxImagePreviewCache()
    @ObservationIgnored var outboxPreviewAttempts: Set<OutboxImagePreviewKey> = []
    @ObservationIgnored var outboxPreviewActiveKeys: Set<OutboxImagePreviewKey> = []
    @ObservationIgnored var outboxPreviewTask: Task<Void, Never>?
    @ObservationIgnored var outboxPreviewGeneration = 0
    @ObservationIgnored var legacyLocationProjectionTokens: [String: UUID] = [:]
    @ObservationIgnored var legacyLocationProjectionWorkerCount = 0
    @ObservationIgnored var outboxImagePreviewProbe: (@Sendable () -> Void)?
    @ObservationIgnored var hasPendingLive = false
    /// How many leading `entries` come from committed items; the rest is the live tail. `nil` until
    /// `entries` has been rebuilt from `items`, so the next rebuild rebuilds the committed part too.
    @ObservationIgnored var committedEntryCount: Int?
    /// Whether a run is in progress here, streamed or reported by the session row. Stored, and only
    /// written on transitions, so views reading it don't re-render on every streamed token.
    public internal(set) var isRunning = false
    /// This chat's session row, kept in step by `GatewayStore` and only written when that row changes,
    /// so views reading it don't re-render when some other session changes.
    public internal(set) var sessionRow: SessionRow?
    public internal(set) var isLoading = false
    public internal(set) var hasLoaded = false
    public internal(set) var isSending = false
    public internal(set) var hasMoreHistory = false
    /// Cached items exist on disk before the first committed item in memory (the window is a
    /// contiguous newest suffix of the transcript).
    public internal(set) var olderInCache = false
    /// Whether anything older than what's loaded can still be paged in, from the cache or the Gateway.
    public var hasOlderItems: Bool { self.olderInCache || self.hasMoreHistory }
    public internal(set) var isLoadingOlder = false
    public var errorMessage: String?
    /// Called once when a run ends successfully, with its last assistant message that has speakable text (never for
    /// history loads, aborted or failed runs). Read Aloud's auto-read uses it.
    @ObservationIgnored public var onFinalAssistantReply: (@MainActor (ChatItem) -> Void)? {
        didSet {
            // Work accepted by one window must not cross to a replacement handler.
            self.dropPendingReply()
        }
    }
    /// Who installed `onFinalAssistantReply`, so a closing window only removes its own handler.
    @ObservationIgnored public weak var onFinalAssistantReplyOwner: AnyObject?
    /// The newest live assistant message with speakable text since the last live user message, and whether a
    /// successful run ended before one arrived. See `noteRunSucceeded`.
    @ObservationIgnored var liveReplyCandidate: ChatItem?
    @ObservationIgnored var awaitingFinalReply = false
    @ObservationIgnored var autoReadRunId: String?
    @ObservationIgnored package var liveReplyPreparationQueue = LiveReplyPreparationQueue.shared
    @ObservationIgnored var liveReplyPreparationOwnerID = UUID()
    @ObservationIgnored var liveReplyPreparationGeneration: UInt64 = 0
    @ObservationIgnored var liveReplyPreparationSequence: UInt64 = 0
    @ObservationIgnored var liveReplyPreparationRevision: UInt64 = 0
    @ObservationIgnored var liveReplyPreparationOutstanding = 0
    /// Queue-order membership is fixed when successful completion arrives. Later events may
    /// refresh a member without moving it, while new work cannot extend this completed-run barrier.
    @ObservationIgnored var liveReplyFinalBarrierOrders: Set<UInt64>?
    /// Retained as a diagnostic sequence snapshot; membership decisions use queue orders above.
    @ObservationIgnored var liveReplyFinalBarrierSequence: UInt64?
    @ObservationIgnored var liveReplyFinalBarrierRemaining = 0
    @ObservationIgnored var liveReplyGenerationSuppressed = false
    @ObservationIgnored var liveReplyLifecycleRunId: String?
    /// Contains only IDs with queued work; queue admission bounds this map to at most 33 rows.
    @ObservationIgnored var liveReplyItemTokens: [String: UInt64] = [:] // per-item revision
    @ObservationIgnored var liveReplyWorkSequences: [String: UInt64] = [:] // stable per-item FIFO position
    @ObservationIgnored var liveReplyCandidateSequence: UInt64?
    @ObservationIgnored var liveReplyCandidateQueueOrder: UInt64?
    /// Whether the transcript contains any reasoning; used to hint at `/reasoning on`.
    public internal(set) var sawThinking = false
    /// The agent's task checklist for this session, shown above the composer.
    public internal(set) var progressCard: ProgressCard?
    /// Unsent composer text and attachments, kept across chat switches and saved to disk.
    public var draft = ComposerDraft() {
        didSet {
            guard !self.headless, !self.restoringDraft, self.draft != oldValue else { return }
            self.draftEdited = true
            self.scheduleDraftSave()
        }
    }
    /// The message the composer is replying to. Per chat, in memory only.
    public var replyTarget: ReplyTarget? {
        didSet {
            if oldValue?.selectionID != self.replyTarget?.selectionID { self.refreshSelectedReplyPreview() }
        }
    }
    @ObservationIgnored package var replyPreviewPreparation = ReplyPreviewPreparationService.shared
    @ObservationIgnored var replyPreviewPublication: Task<Void, Never>?
    @ObservationIgnored var replyPreviewLifecycle = 0
#if DEBUG
    @ObservationIgnored package var replyPreparationDidReserve: (@MainActor (String) -> Void)?
#endif
    /// The user message being edited (Edit & Resend). Per chat, in memory only.
    public var editTarget: MessageEditTarget?
    /// The chat's transcript tips (`sessions.branches.list`), oldest first; see `refreshBranches()`.
    public internal(set) var branches: [SessionBranch] = []
    /// An Edit & Resend is in flight (rewind, then send); Send is off meanwhile.
    public internal(set) var isSendingEdit = false
    /// Idempotency key of the message the latest Edit & Resend or Regenerate sent: where its branches fork.
    var branchAnchorKey: String?
    @ObservationIgnored var branchRefreshGeneration = 0
    @ObservationIgnored var branchRefreshTask: Task<Void, Never>?
    /// A passing, non-error note for the chat's notice bar (not a send failure).
    public var notice: String? {
        didSet { self.noticeRevision &+= 1 }
    }
    /// Notice ownership changes on every assignment, including identical repeated text.
    @ObservationIgnored private(set) var noticeRevision: UInt64 = 0
    /// The quoted message being looked for in older history, while paging.
    public internal(set) var locatingReplyId: String?
    /// How the latest run ended, and when, for the avatar's transient success and error poses.
    public internal(set) var lastOutcome = AvatarOutcome.none
    public internal(set) var lastOutcomeAt: Date?
    @ObservationIgnored var outcomeRunId: String?
    /// Reactions the agent added with its `message` tool, by transcript id.
    public internal(set) var agentReactions: [String: [String]] = [:]
    /// Reactions on this chat's messages as the Gateway stores them (`session.reactions.*`), by transcript id.
    public internal(set) var sharedReactions: [String: [ReactionSummary]] = [:]
    /// Your Gateway reaction identity once this chat has synced its reactions on the connection; nil while
    /// reactions use `users.prefs`.
    public internal(set) var reactionSelfId: String?
    @ObservationIgnored var reactionSync = ReactionSync()
    /// Committed items by transcript id.
    @ObservationIgnored var itemsByTranscriptId: [String: ChatItem] = [:]
    /// The latest "Compact now" request, for the composer's context meter.
    public internal(set) var compaction: CompactionState? {
        didSet { if oldValue?.isRunning != self.compaction?.isRunning { self.rebuild(itemsChanged: false) } }
    }
    /// The `/compact` run whose end finishes `compaction`, when it was sent as a command.
    @ObservationIgnored var compactionRunId: String?

    @ObservationIgnored let historyLimit = 120
    /// Most committed items kept in memory for a chat that isn't open.
    #if os(macOS)
    static let defaultWindowLimit = 3_000
    #else
    static let defaultWindowLimit = 1_200
    #endif
    @ObservationIgnored var windowLimit = ChatStore.defaultWindowLimit
    /// Items per page when scrolling back through the cache; lookups (find, jump) use larger ones.
    static let olderCachePageSize = 200
    static let lookupCachePageSize = 2_000
    @ObservationIgnored let gatewayId: UUID
    /// Where this chat's transcript is cached; tests give each chat its own folder.
    @ObservationIgnored var cacheRoot: URL? = TranscriptCache.root
    /// Background cache filler: no UI, no live subscription.
    @ObservationIgnored let headless: Bool
    @ObservationIgnored var cacheChecked = false
    /// Bumped whenever `items` actually changes, so saves can tell a real change from a refresh
    /// that fetched the same transcript again.
    @ObservationIgnored package var contentRevision = 0
    /// What the transcript cache holds, as of the last save or restore of this store.
    @ObservationIgnored var savedState: CacheState?
    /// The last restore couldn't read the cache (`.unavailable`); saving now would replace the
    /// older history on disk with only what's loaded, so nothing is written until a restore succeeds.
    @ObservationIgnored var cacheUnreadable = false
    @ObservationIgnored var forwardedSenderRefreshPending = false
    @ObservationIgnored var forwardedSenderRefreshCompleted = false
    /// The session was deleted, so its transcript is never cached again.
    @ObservationIgnored var cachingStopped = false
    /// What restoring from the transcript cache found; nil until it's been tried.
    @ObservationIgnored var cacheOutcome: TranscriptCache.LoadOutcome?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    /// Injectable deadline source/waiter keeps transcript-save scheduling deterministic in tests.
    @ObservationIgnored var saveNow: @MainActor () -> Date = { Date() }
    @ObservationIgnored var waitForSaveDeadline: @MainActor (Date) async throws -> Void = { deadline in
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
    }
    @ObservationIgnored var saveDeadline: Date?
    @ObservationIgnored var saveDeadlineRunId: String?
    @ObservationIgnored var saveScheduleGeneration = 0
    @ObservationIgnored var backfillTask: Task<Void, Never>?
    @ObservationIgnored var olderTask: Task<Bool, Never>?
    /// `chat.history` offset (counted back from the newest message) of the next older page.
    @ObservationIgnored var olderOffset: Int?
    /// Whether older pages have been prepended beyond the latest page.
    @ObservationIgnored var hasPagedOlder = false
    @ObservationIgnored var reloadTask: Task<Void, Never>?
    @ObservationIgnored var progressCardTask: Task<Void, Never>?
    /// Whether the Gateway serves `progressCard.get`; nil until known. Without it, `plan` stream
    /// events drive the card instead.
    @ObservationIgnored var progressCardStoreAvailable: Bool?
    @ObservationIgnored var legacyPlanRevision = 0
    /// Full copies of capped messages by transcript id, re-applied when history re-sends the cap.
    @ObservationIgnored var fullMessages: [String: ChatItem] = [:]
    /// Capped messages being fetched, or that the Gateway couldn't return in full.
    @ObservationIgnored var recoveryAttempted: Set<String> = []
    /// A bulk transcript install or retryable fetch failure needs one later recovery pass.
    @ObservationIgnored var cappedRecoveryPending = false
#if DEBUG
    /// Saturating work counter for the consumed capped-message recovery scan.
    @ObservationIgnored package var cappedRecoveryRowsVisitedForTesting = 0
    /// Rows visited by scans started synchronously from accepted `session.message` events.
    @ObservationIgnored package var acceptedEventRecoveryRowsVisitedForTesting = 0
    /// A narrow transport seam for exercising the real full-message recovery completion/catch path.
    @ObservationIgnored package var cappedMessageRecoveryRequestForTesting: (@MainActor (String) async throws -> JSONValue)?

    package func resetCappedRecoveryRowsVisitedForTesting() {
        self.cappedRecoveryRowsVisitedForTesting = 0
        self.acceptedEventRecoveryRowsVisitedForTesting = 0
    }
#endif
    /// Largest text field requested per message, matching the Control UI.
    @ObservationIgnored let fullMessageMaxChars = 500_000
    @ObservationIgnored var draftChecked = false
    /// The draft changed here, so a saved one arriving late must not replace it.
    @ObservationIgnored var draftEdited = false
    @ObservationIgnored var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored var restoringDraft = false
    /// Heavy contents were dropped to save memory; the next `load()` restores them from the cache.
    @ObservationIgnored var isDehydrated = false

    init(sessionKey: String, agentId: String?, gateway: GatewayStore, headless: Bool = false) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.gateway = gateway
        self.gatewayId = gateway.id
        self.cacheRoot = gateway.cacheRoot
        self.headless = headless
        self.sessionRow = gateway.sessions[sessionKey]
        self.isRunning = self.sessionRow?.hasActiveRun == true
    }

    func syncSessionRow(_ row: SessionRow?) {
        guard row != self.sessionRow else { return }
        self.sessionRow = row
        self.updateIsRunning()
    }

    func updateIsRunning() {
        let running = self.live != nil || self.sessionRow?.hasActiveRun == true
        guard !self.headless, running != self.isRunning else { return }
        self.isRunning = running
        self.gateway?.chatRunStateChanged(self.sessionKey, running: running)
    }

    // MARK: Loading

    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var loadGeneration = 0
    var loadInFlight: Bool { self.loadTask != nil }
    @ObservationIgnored var subscribedEpoch: Int?
    /// Names this chat's observer on the Gateway, so another chat or client on the same connection can't drop it.
    @ObservationIgnored let subscriptionId = UUID().uuidString
    @ObservationIgnored var subscribedWithId = false
    @ObservationIgnored var stale = false
    @ObservationIgnored var loadCount = 0
    @ObservationIgnored var finishedRunIds: [String] = []

    // MARK: Presentation

    /// Only the reply text or reasoning grew: everything else about the run is unchanged.
    static func isTextGrowth(from old: LiveRun?, to new: LiveRun?) -> Bool {
        guard let old, let new, old.runId == new.runId else { return false }
        return old.tools == new.tools && old.images == new.images && old.phase == new.phase
            && old.isCompacting == new.isCompacting && old.startedAt == new.startedAt
            && old.model == new.model && old.provider == new.provider
    }

    func liveChanged(from old: LiveRun?) {
        if Self.isTextGrowth(from: old, to: self.live) {
            self.publishLiveCoalesced()
        } else {
            self.rebuild(itemsChanged: false)
        }
    }

    func publishLiveCoalesced() {
        let interval = Self.liveFlushInterval
        let elapsed = Date().timeIntervalSince(self.lastPublishAt)
        if elapsed >= interval {
            self.rebuild(itemsChanged: false)
            return
        }
        self.hasPendingLive = true
        guard self.pendingFlush == nil else { return }
        let remaining = Self.coalescedFlushDelay(interval: interval, elapsed: elapsed)
        self.pendingFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.flushLive()
        }
    }

    static func coalescedFlushDelay(interval: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        max(0, interval - max(0, elapsed))
    }

    /// Publishes any coalesced live update now.
    func flushLive() {
        guard self.hasPendingLive else { return }
        self.rebuild(itemsChanged: false)
    }

    func rebuild(itemsChanged: Bool) {
        self.pendingFlush?.cancel()
        self.pendingFlush = nil
        self.hasPendingLive = false
        self.lastPublishAt = Date()
        // `entries` is the only copy of the transcript (#315): committed entries first, then the live
        // tail, which streaming replaces in place.
        var committed: [TranscriptEntry]?
        if itemsChanged || self.committedEntryCount == nil {
            committed = TranscriptBuilder.build(self.items)
        }
        if itemsChanged {
            var byId: [String: ChatItem] = [:]
            for item in self.items where item.isReplyable {
                if let id = item.transcriptId { byId[id] = item }
            }
            self.itemsByTranscriptId = byId
            self.refreshSelectedReplyPreview()
            let reactions = Reactions.agentReactions(in: self.items)
            if reactions != self.agentReactions { self.agentReactions = reactions }
            if !self.sawThinking {
                self.sawThinking = self.items.contains { $0.hasThinkingContent }
            }
        }
        var entries: [TranscriptEntry] = []
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
        if var all = committed {
            let count = all.count
            all.append(contentsOf: entries)
            if all != self.entries { self.entries = all }
            self.committedEntryCount = count
        } else if let count = self.committedEntryCount, self.entries.count >= count {
            if !self.entries[count...].elementsEqual(entries) {
                self.entries.replaceSubrange(count..., with: entries)
            }
        }
    }

    public var liveRunId: String? { self.live?.runId }
}
