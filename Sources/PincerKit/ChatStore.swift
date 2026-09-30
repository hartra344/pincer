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
    /// Minimum time between published transcripts while text or thinking streams in (~30 Hz).
    nonisolated(unsafe) static var liveFlushInterval: TimeInterval = 1.0 / 30
    @ObservationIgnored var lastPublishAt = Date.distantPast
    @ObservationIgnored var pendingFlush: Task<Void, Never>?
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
    @ObservationIgnored public var onFinalAssistantReply: (@MainActor (ChatItem) -> Void)?
    /// Who installed `onFinalAssistantReply`, so a closing window only removes its own handler.
    @ObservationIgnored public weak var onFinalAssistantReplyOwner: AnyObject?
    /// The newest live assistant message with speakable text since the last live user message, and whether a
    /// successful run ended before one arrived. See `noteRunSucceeded`.
    @ObservationIgnored var liveReplyCandidate: ChatItem?
    @ObservationIgnored var awaitingFinalReply = false
    @ObservationIgnored var autoReadRunId: String?
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
    public var replyTarget: ReplyTarget?
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
    public var notice: String?
    /// The quoted message being looked for in older history, while paging.
    public internal(set) var locatingReplyId: String?
    /// How the latest run ended, and when, for the avatar's transient success and error poses.
    public internal(set) var lastOutcome = AvatarOutcome.none
    public internal(set) var lastOutcomeAt: Date?
    @ObservationIgnored var outcomeRunId: String?
    /// Reactions the agent added with its `message` tool, by transcript id.
    public internal(set) var agentReactions: [String: [String]] = [:]
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
    @ObservationIgnored var contentRevision = 0
    /// What the transcript cache holds, as of the last save or restore of this store.
    @ObservationIgnored var savedState: CacheState?
    /// The last restore couldn't read the cache (`.unavailable`); saving now would replace the
    /// older history on disk with only what's loaded, so nothing is written until a restore succeeds.
    @ObservationIgnored var cacheUnreadable = false
    /// The session was deleted, so its transcript is never cached again.
    @ObservationIgnored var cachingStopped = false
    /// What restoring from the transcript cache found; nil until it's been tried.
    @ObservationIgnored var cacheOutcome: TranscriptCache.LoadOutcome?
    @ObservationIgnored var saveTask: Task<Void, Never>?
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

    @ObservationIgnored var loadInFlight = false
    @ObservationIgnored var subscribedEpoch: Int?
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
        let remaining = interval - elapsed
        self.pendingFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.flushLive()
        }
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
            let reactions = Reactions.agentReactions(in: self.items)
            if reactions != self.agentReactions { self.agentReactions = reactions }
            if !self.sawThinking {
                self.sawThinking = self.items.contains { $0.thinkingText != nil }
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
