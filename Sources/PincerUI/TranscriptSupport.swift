import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One row of the native transcript list (`TranscriptList`): a message, or the spinner shown while
/// older history is still streaming in above.
enum TranscriptRow: Equatable, Sendable {
    case loadingOlder
    case entry(TranscriptEntry)

    var id: String {
        switch self {
        case .loadingOlder: "loading-older"
        case let .entry(entry): entry.id
        }
    }

    /// A message the owner just sent that the Gateway hasn't committed yet. The list jumps to it,
    /// even if the reader had scrolled up, and then follows the reply.
    var isPendingSend: Bool {
        if case let .entry(.user(item)) = self { item.isPending } else { false }
    }

    @MainActor static func rows(for chat: ChatStore) -> [TranscriptRow] {
        (chat.hasOlderItems ? [.loadingOlder] : []) + chat.entries.map(TranscriptRow.entry)
    }
}

/// Which thinking blocks and tool cards are open. Kept outside the rows because the list recycles
/// row views: state stored in a row view would follow it to another message.
@MainActor
final class TranscriptDisclosure {
    private var expanded: [String: Bool] = [:]
    /// Queries and current matches of the search within a tool card.
    let toolSearch = ToolCardSearchStore()

    func isExpanded(_ id: String, default value: Bool) -> Bool {
        self.expanded[id] ?? value
    }

    func set(_ id: String, expanded: Bool) {
        self.expanded[id] = expanded
    }

    /// Records a default once, so it sticks when the condition that chose it (a live stream) ends.
    func setIfUnset(_ id: String, expanded: Bool) {
        if self.expanded[id] == nil { self.expanded[id] = expanded }
    }
}

/// Everything a transcript row needs besides its own content.
@MainActor
struct TranscriptContext {
    let gateway: GatewayStore
    let disclosure: TranscriptDisclosure
    let agent: AgentSummary
    let sessionKey: String
    /// Opens an image full size. Provided by `ChatView`, which owns the sheet.
    let previewImage: (ImageRef) -> Void
    /// Offers a downloaded attachment to the user to save. Provided by `ChatView`.
    let saveFile: (FileRef, Data) -> Void
    /// The chat's replies and reactions.
    var chat: ChatStore?
    /// Starts a reply to a message in the composer. Provided by `ChatView`.
    var reply: (String) -> Void = { _ in }
    /// Copies a `pincer://` link to a message. Provided by `ChatView`.
    var copyLink: (String) -> Void = { _ in }
    /// Stars or un-stars a message. Provided by `ChatView`.
    var toggleBookmark: (String) -> Void = { _ in }
    var isBookmarked: (String) -> Bool = { _ in false }
    /// Opens an ```html fence in the sandboxed preview. Provided by `ChatView`, which owns the sheet.
    var previewHTML: (String) -> Void = { _ in }
    /// Shows a downloaded attachment in Quick Look. Provided by `ChatView`, which owns the preview.
    var quickLook: (URL) -> Void = { _ in }
    /// Opens an MCP server in Gateway Settings. Provided by `ChatView`.
    var openMCPServer: (String) -> Void = { _ in }

    func differs(from other: TranscriptContext) -> Bool {
        self.agent != other.agent || self.sessionKey != other.sessionKey || self.disclosure !== other.disclosure
            || self.chat !== other.chat
    }

    /// Whether a message has reaction chips (the agent's or yours), for height estimates.
    @MainActor func hasReactions(_ messageId: String) -> Bool {
        guard ReactionFeature.isEnabled else { return false }
        if self.chat?.agentReactions[messageId]?.isEmpty == false { return true }
        if self.chat?.sharedReactions[messageId]?.isEmpty == false { return true }
        return !self.gateway.myReactions(sessionKey: self.sessionKey, messageId: messageId).isEmpty
    }
}

/// One line of the branch switcher's menu.
struct TranscriptBranchEntry {
    let leafEntryId: String
    let title: String
    let isActive: Bool
}

/// What row views can ask of the list they're in.
@MainActor
protocol TranscriptRowActions: AnyObject {
    var messagePartExcerptCache: MessagePartExcerptCache { get }
    func setExpanded(_ key: String, _ expanded: Bool, row: String)
    func openRun(_ sessionKey: String)
    /// Opens another chat, e.g. the one a forwarded message came from.
    func openChat(_ sessionKey: String)
    /// Opens the MCP server a tool card called in Gateway Settings.
    func openMCPServer(_ name: String)
    func preview(_ ref: ImageRef)
    /// Shows an ```html fence as a page in the sandboxed preview.
    func previewHTML(_ html: String)
    func open(_ url: URL)
    func loadImage(_ ref: ImageRef)
    func loadFilePreview(_ file: FileRef)
    /// Downloads the file and offers to save it; false when it couldn't be downloaded.
    func saveFile(_ file: FileRef) async -> Bool
    /// Downloads the file and shows it in Quick Look; false when it couldn't be downloaded.
    func quickLook(_ file: FileRef) async -> Bool
    /// Starts a reply to the message in the composer.
    func reply(to messageId: String)
    /// Branch from Here, Edit & Resend and Regenerate (each only offered when the chat can do it).
    func canBranch(from messageId: String) -> Bool
    func canEdit(_ messageId: String) -> Bool
    func canRegenerate(_ messageId: String) -> Bool
    func branch(from messageId: String)
    func edit(_ messageId: String)
    func regenerate(_ messageId: String)
    /// Copies a link that opens the chat scrolled to the message.
    func copyLink(to messageId: String)
    /// Bookmarks the message, or removes its bookmark.
    func toggleBookmark(_ messageId: String)
    func isBookmarked(_ messageId: String) -> Bool
    /// Read Aloud: speaks the message (or stops it when it's already being read).
    func readAloud(_ messageId: String)
    func isReadingAloud(_ messageId: String) -> Bool
    /// Whether the message has anything worth speaking.
    func canReadAloud(_ messageId: String) -> Bool
    /// Row-aware Read Aloud lookup used by native controls so a completed preparation can refresh
    /// only the transcript row that owns the message.
    func canReadAloud(_ messageId: String, rowID: String) -> Bool
    func readAloud(_ messageId: String, rowID: String)
    /// Adds your reaction, or removes it when it's already there.
    var reactionsEnabled: Bool { get }
    func toggleReaction(_ emoji: String, on messageId: String)
    /// Opens the emoji picker for a message, anchored to `rect` in `view`.
    func pickReaction(for messageId: String, from view: PView, rect: CGRect)
    /// The chat's branches, oldest first, for the switcher's menu.
    var branchEntries: [TranscriptBranchEntry] { get }
    /// Switches to the branch `offset` places from the active one (-1 previous, 1 next).
    func stepBranch(_ offset: Int)
    func switchBranch(to leafEntryId: String)
    /// Scrolls to the message a reply quotes (loading older history if needed) and flashes it.
    func showOriginal(_ messageId: String)
    /// Animates the latest reply's avatar.
    var liveAvatar: TranscriptLiveAvatar? { get }
    /// Sends an unsent (failed) message again, with its original idempotency key.
    func retrySend(_ id: String)
    /// Uploads a held large message over the current (expensive or constrained) network.
    func sendNow(_ id: String)
    /// Deletes a queued or failed message.
    func deleteSend(_ id: String)
}

extension TranscriptRowActions {
    var messagePartExcerptCache: MessagePartExcerptCache { .shared }
    func canReadAloud(_ messageId: String, rowID: String) -> Bool { self.canReadAloud(messageId) }
    func readAloud(_ messageId: String, rowID: String) { self.readAloud(messageId) }
}

/// Lays out rows for the AppKit and UIKit lists and tells them when a row's layout is stale:
/// its disclosure toggled, an image it shows loaded, a subagent run it links to appeared, or a
/// setting or the text size changed.
@MainActor
final class TranscriptRenderer: TranscriptRowActions {
    let messagePartExcerptCache: MessagePartExcerptCache
    private struct Entry {
        let row: TranscriptRow
        var layout: TranscriptRowLayout
        var stamp: Int
        var invalidated = false
    }

    private struct SpeechJob {
        let token: SpeechEligibilityCache.Token
        var rowID: String
        var layoutSerial: Int
        let chat: ChatStore
        var shouldStartPlayback: Bool
        var task: Task<Void, Never>?
    }

    private struct PendingSpeechPreparation {
        var rowID: String
        var layoutSerial: Int
        var shouldStartPlayback: Bool
        let orderToken: UInt64
    }

    private struct PendingSpeechOrderEntry {
        let messageID: String
        let token: UInt64
    }

    private actor SpeechPreparationWorker {
        func prepare(_ item: ChatItem, probe: (@Sendable (String) -> Void)?) -> SpeechEligibilityCache.Prepared? {
            guard !Task.isCancelled else { return nil }
            probe?(item.id)
            guard !Task.isCancelled else { return nil }
            return SpeechText.prepare(item)
        }

#if DEBUG
        func prepare(_ item: ChatItem, probe: (@Sendable (String) -> Void)?,
                     gate: (@Sendable (String) async -> Void)?) async -> SpeechEligibilityCache.Prepared?
        {
            guard !Task.isCancelled else { return nil }
            probe?(item.id)
            guard !Task.isCancelled else { return nil }
            await gate?(item.id)
            guard !Task.isCancelled else { return nil }
            return self.prepare(item, probe: nil)
        }
#endif
    }

    private static let speechPreparationWorker = SpeechPreparationWorker()

    /// Layouts kept for rows; the least recently used go first. Heights of rows without one
    /// live in the list, so a dropped layout only costs a relayout when the row is next drawn.
    static let layoutCacheLimit = 800

    private enum ImageState: Equatable { case loading, loaded, failed }

    private(set) var context: TranscriptContext
    let liveAvatar: TranscriptLiveAvatar? = TranscriptLiveAvatar()
    private(set) var highlight = TranscriptHighlight()
    private var settings: TranscriptSettings
    private var cache: [String: Entry] = [:]
    private var speechCache = SpeechEligibilityCache()
    private var speechJobs: [String: SpeechJob] = [:]
    private var speechWorkerCount = 0
    // Retain only IDs and row coordinates while the worker is full; ChatStore remains the source
    // of item snapshots. Both this queue and active jobs are bounded independently.
    private var pendingSpeechPreparations: [String: PendingSpeechPreparation] = [:]
    private var pendingSpeechOrder: [PendingSpeechOrderEntry] = []
    private var pendingSpeechHead = 0
    private var nextPendingSpeechOrderToken: UInt64 = 0
    #if DEBUG
    var pendingSpeechPreparationCount: Int { self.pendingSpeechPreparations.count }
    var pendingSpeechPreparationOrderCount: Int { self.pendingSpeechOrder.count - self.pendingSpeechHead }
    var activeSpeechPreparationCount: Int { self.speechWorkerCount }
    #endif
#if DEBUG
    /// A bounded test seam invoked on the worker before normalization; it never receives text.
    var speechPreparationProbe: (@Sendable (String) -> Void)?
    /// An async test gate before normalization. Production builds compile out the overload entirely.
    var speechPreparationGate: (@Sendable (String) async -> Void)?
#endif
    private var imageRows: [String: Set<String>] = [:]
    private var imageStates: [String: ImageState] = [:]
    private var imageRefs: [String: ImageRef] = [:]
    private var fileRows: [String: Set<String>] = [:]
    private var filePreviews: [String: FileContentLoader.Preview?] = [:]
    private var spawnRows: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var accessibilityObservation: NSObjectProtocol?
    #endif
    #if os(macOS)
    /// Dark Mode flips re-lay out rows, so rendered diagrams and math pick up the matching palette.
    private var appearanceObservation: NSKeyValueObservation?
    #endif
    /// The message flashing after a jump from its quote.
    private var flash: String?
    private var flashToken = 0
    private var ack: String?
    /// Testable page source for exercising the older-row loop without touching the transcript cache.
    var olderPageLoader: (@MainActor (ChatStore) async -> Bool)?

    /// Rows whose layout changed (nil means all of them), and a row to hold still on screen while
    /// they change, when the change came from a click in that row.
    private var serial = 0
    /// Layouts built (cache misses), for regression checks.
    private(set) var layoutBuildCount = 0
    #if DEBUG
    /// Counts row-body source extraction on the real premeasure path for the focused cache probe.
    private(set) var premeasureBodyBuildCount = 0
    #endif
    private var useStamp = 0
    /// Rows on screen, which are never evicted from the layout cache: an image or file arriving for
    /// one must still find it.
    var visibleRowIds: () -> Set<String> = { [] }
    /// A row was laid out again after its layout was evicted: id, width and height.
    var onRelayout: ((_ id: String, _ width: CGFloat, _ height: CGFloat) -> Void)?
    var onInvalidate: ((_ ids: Set<String>?, _ keepInPlace: String?) -> Void)?
    /// Scrolls a row into view the way Find does, at its `matchY`.
    var onReveal: ((_ id: String) -> Void)?

    init(context: TranscriptContext, messagePartExcerptCache: MessagePartExcerptCache? = nil) {
        self.context = context
        self.messagePartExcerptCache = messagePartExcerptCache ?? .shared
        self.settings = .current(for: context)
        self.observeImages()
        self.observeFiles()
        self.observeSessions()
        self.observeDecorations()
        self.observeQuoteReadiness()
        self.observeAck()
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.settingsChanged() }
        })
        #if os(macOS)
        self.accessibilityObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.settingsChanged() }
        }
        self.appearanceObservation = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.settingsChanged() } }
        }
        #endif
        #if os(iOS)
        self.observers.append(center.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                TranscriptStyle.reload()
                self?.invalidateAll()
            }
        })
        // A light/dark flip made while backgrounded is picked up on return (#369).
        self.observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceChanged() }
        })
        #endif
    }

    isolated deinit {
        for job in self.speechJobs.values { job.task?.cancel() }
        self.context.gateway.images.setVisible([], owner: ObjectIdentifier(self))
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        #if os(macOS)
        if let accessibilityObservation { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObservation) }
        #endif
    }

    /// Tells the image cache which images the rows on screen show, so it keeps them.
    func pinImages(of rows: some Sequence<TranscriptRow>, width: CGFloat) {
        var keys = Set<String>()
        for row in rows {
            for ref in self.layout(for: row, width: width).images { keys.insert(ref.cacheKey) }
        }
        self.context.gateway.images.setVisible(keys, owner: ObjectIdentifier(self))
    }

    func update(context: TranscriptContext) {
        let changed = context.differs(from: self.context)
        if context.gateway !== self.context.gateway {
            self.context.gateway.images.setVisible([], owner: ObjectIdentifier(self))
        }
        if changed, self.resumeOlderChat !== context.chat { self.resumeOlderChat = nil }
        self.context = context
        self.liveAvatar?.update(chat: context.chat)
        if changed {
            self.settings = .current(for: context)
            self.flash = nil
            self.ack = context.chat?.ackMessageId
            self.reset()
            self.observeDecorations()
            self.observeQuoteReadiness()
            self.observeAck()
        } else {
            self.settingsChanged()
        }
    }

    /// Applies what Find highlights, relaying out only the rows it changes. Returns the row to
    /// scroll to when the selected match should be brought into view.
    func update(highlight: TranscriptHighlight) -> String? {
        let old = self.highlight
        guard highlight != old else { return nil }
        self.highlight = highlight
        var stale: Set<String> = []
        if highlight.query != old.query || highlight.options != old.options {
            stale = old.rows.union(highlight.rows)
        } else if highlight.rows != old.rows {
            // Matches arrived for the query, or a message gained or lost one.
            stale = old.rows.symmetricDifference(highlight.rows)
        }
        if highlight.current != old.current {
            if let id = old.current?.entryId { stale.insert(id) }
            if let id = highlight.current?.entryId { stale.insert(id) }
        }
        let reveal = highlight.reveal != old.reveal ? highlight.current : nil
        if let reveal {
            // Relaid out even when it's the same match, in case its card was collapsed since.
            self.expand(for: reveal)
            stale.insert(reveal.entryId)
        }
        self.markLayoutInvalidated(stale)
        self.onInvalidate?(stale, nil)
        return reveal?.entryId
    }

    /// Opens the thinking group and tool card a match is in, so it's visible once scrolled to.
    private func expand(for match: TranscriptSearch.Match) {
        guard match.entryId.hasPrefix("a-") else { return }
        let turn = String(match.entryId.dropFirst(2))
        switch match.section {
        case .thinking:
            self.context.disclosure.set("steps:\(turn)", expanded: true)
            self.context.disclosure.set("thinking:\(turn)", expanded: true)
        case let .tool(id):
            self.context.disclosure.set("steps:\(turn)", expanded: true)
            self.context.disclosure.set("tool:\(id)", expanded: true)
        case .message:
            break
        }
    }

    var cachedLayoutCount: Int { self.cache.count }
    var premeasureStyleGeneration: Int { TranscriptStyle.generation }
    var premeasureDark: Bool { self.settings.dark }

    /// The spoken label of a row already laid out, without building anything.
    func cachedLabel(for row: TranscriptRow) -> String? {
        guard let entry = self.cache[row.id], !entry.invalidated, entry.row == row else { return nil }
        return entry.layout.accessibilityLabel
    }

    /// The row laid out at `width`, from cache when neither has changed.
    func layout(for row: TranscriptRow, width: CGFloat) -> TranscriptRowLayout {
        self.useStamp += 1
        if var entry = self.cache[row.id], !entry.invalidated, entry.layout.width == width, entry.row == row {
            entry.stamp = self.useStamp
            self.cache[row.id] = entry
            return entry.layout
        }
        let previous = self.cache[row.id]
        let rowContentChanged = previous.map { $0.row != row } ?? false
        if rowContentChanged, let previous {
            self.invalidateSpeechReadiness(for: previous.layout.messages.map(\.id))
        }
        let wasEvicted = self.cache[row.id] == nil
        self.layoutBuildCount += 1
        var layout = TranscriptSignposts.measure("RowLayout") {
            TranscriptLayoutBuilder(context: self.context, settings: self.settings, highlight: self.highlight,
                                    flash: self.flash, messagePartExcerptCache: self.messagePartExcerptCache)
                .layout(row, width: width)
        }
        self.serial += 1
        layout.serial = self.serial
        self.cache[row.id] = Entry(row: row, layout: layout, stamp: self.useStamp, invalidated: false)
        if rowContentChanged {
            self.invalidateSpeechReadiness(for: layout.messages.map(\.id))
        }
        let loader = self.context.gateway.images
        for ref in layout.images {
            let key = ref.cacheKey
            self.imageRefs[key] = ref
            self.imageRows[key, default: []].insert(row.id)
            self.imageStates[key] = loader.images[ref.cacheKey] != nil ? .loaded : loader.hasFailed(ref) ? .failed : .loading
        }
        let files = self.context.gateway.files
        for file in layout.files {
            self.fileRows[file.cacheKey, default: []].insert(row.id)
            self.filePreviews[file.cacheKey] = .some(files.preview(file))
        }
        if layout.hasSpawns { self.spawnRows.insert(row.id) } else { self.spawnRows.remove(row.id) }
        self.evictIfNeeded()
        if wasEvicted { self.onRelayout?(row.id, width, layout.height) }
        return layout
    }

    // MARK: Premeasure

    /// What a background pass would build and measure for `row`; nil when the row has to be laid out on
    /// main: one streaming (its text changes every flush), highlighted by Find, or without text.
    func premeasureIsHighlighted(_ id: String) -> Bool { self.highlight.rows.contains(id) }

    func premeasureBodies(for row: TranscriptRow) -> [PremeasureKey]? {
        #if DEBUG
        self.premeasureBodyBuildCount += 1
        #endif
        guard !self.highlight.rows.contains(row.id) else { return nil }
        return PremeasureSource.bodies(for: row, styleGeneration: TranscriptStyle.generation, dark: self.settings.dark)
    }

    func hasLayout(for row: TranscriptRow, width: CGFloat) -> Bool {
        guard let entry = self.cache[row.id], !entry.invalidated else { return false }
        return entry.layout.width == width && entry.row == row
    }

    var textEnvironment: TextBuildEnvironment { .current(dark: self.settings.dark) }

    /// Drops the least recently used layouts (down to 90% of the limit, so this isn't a scan per
    /// insert) along with what was tracked for them.
    private func evictIfNeeded() {
        guard self.cache.count > Self.layoutCacheLimit else { return }
        let keep = self.visibleRowIds()
        let target = Self.layoutCacheLimit * 9 / 10
        let victims = self.cache.filter { !keep.contains($0.key) }.sorted { $0.value.stamp < $1.value.stamp }
            .prefix(max(0, self.cache.count - target)).map(\.key)
        guard !victims.isEmpty else { return }
        let gone = Set(victims)
        for id in victims {
            if let entry = self.cache.removeValue(forKey: id) {
                self.invalidateSpeechReadiness(for: entry.layout.messages.map(\.id))
            }
        }
        self.spawnRows.subtract(gone)
        for (key, rows) in self.imageRows {
            let left = rows.subtracting(gone)
            if left.isEmpty {
                self.imageRows[key] = nil
                self.imageStates[key] = nil
                self.imageRefs[key] = nil
            } else if left.count != rows.count {
                self.imageRows[key] = left
            }
        }
        for (key, rows) in self.fileRows {
            let left = rows.subtracting(gone)
            if left.isEmpty {
                self.fileRows[key] = nil
                self.filePreviews[key] = nil
            } else if left.count != rows.count {
                self.fileRows[key] = left
            }
        }
    }

    func reset() {
        for job in self.speechJobs.values { job.task?.cancel() }
        self.speechJobs.removeAll()
        self.pendingSpeechPreparations.removeAll()
        self.pendingSpeechOrder.removeAll()
        self.pendingSpeechHead = 0
        self.speechCache.removeAll()
        self.cache.removeAll()
        self.imageRows.removeAll()
        self.imageStates.removeAll()
        self.imageRefs.removeAll()
        self.fileRows.removeAll()
        self.filePreviews.removeAll()
        self.spawnRows.removeAll()
    }

    private func invalidate(_ ids: Set<String>, keepInPlace: String? = nil) {
        guard !ids.isEmpty else { return }
        self.markLayoutInvalidated(ids)
        self.onInvalidate?(ids, keepInPlace)
    }

    private func markLayoutInvalidated(_ ids: Set<String>) {
        for id in ids {
            guard var entry = self.cache[id] else { continue }
            entry.invalidated = true
            self.cache[id] = entry
        }
    }

    private func invalidateSpeechReadiness(for messageIDs: [String]) {
        for id in Set(messageIDs) {
            self.speechCache.invalidate(messageID: id)
            self.speechJobs[id]?.task?.cancel()
            self.speechJobs[id] = nil
            self.pendingSpeechPreparations[id] = nil
        }
        self.compactPendingSpeechOrderIfNeeded()
    }

    private func invalidateAll() {
        self.reset()
        self.onInvalidate?(nil, nil)
    }

    // MARK: Observation

    private func observeImages() {
        let loader = self.context.gateway.images
        withObservationTracking {
            _ = loader.images
            _ = loader.failures
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.imagesChanged()
                self?.observeImages()
            }
        }
    }

    private func imagesChanged() {
        let loader = self.context.gateway.images
        var stale: Set<String> = []
        for (key, old) in self.imageStates {
            guard let rows = self.imageRows[key], let ref = self.imageRefs[key] else { continue }
            let now: ImageState = loader.images[ref.cacheKey] != nil ? .loaded : loader.hasFailed(ref) ? .failed : .loading
            if now != old {
                self.imageStates[key] = now
                stale.formUnion(rows)
            }
        }
        self.invalidate(stale)
    }

    private func observeFiles() {
        let files = self.context.gateway.files
        withObservationTracking {
            _ = files.previews
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.filesChanged()
                self?.observeFiles()
            }
        }
    }

    private func filesChanged() {
        let files = self.context.gateway.files
        var stale: Set<String> = []
        for (key, old) in self.filePreviews {
            let now = files.previews[key]
            if now != old {
                self.filePreviews[key] = .some(now)
                stale.formUnion(self.fileRows[key] ?? [])
            }
        }
        self.invalidate(stale)
    }

    private func observeSessions() {
        let gateway = self.context.gateway
        withObservationTracking {
            _ = gateway.sessions
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sessionsChanged()
                self?.observeSessions()
            }
        }
    }

    private func sessionsChanged() {
        // The session's reasoningLevel feeds the settings.
        if self.settingsChanged() { return }
        guard !self.spawnRows.isEmpty else { return }
        var stale: Set<String> = []
        for id in self.spawnRows {
            guard let entry = self.cache[id], case let .entry(.assistant(turn)) = entry.row else { continue }
            let builder = TranscriptLayoutBuilder(context: self.context, settings: self.settings,
                                                  messagePartExcerptCache: self.messagePartExcerptCache)
            for tool in turn.tools where builder.spawnedRun(tool) != entry.layout.runs[tool.id] {
                stale.insert(id)
                break
            }
        }
        self.invalidate(stale)
    }

    /// Reactions (yours, shared and the agent's), quotes whose original loaded, and a quote's lookup.
    /// Quote completion also invalidates cold/in-flight premeasure work through the controller's
    /// existing full-invalidation callback, rather than only comparing completed cached rows.
    private func observeQuoteReadiness() {
        guard let chat = self.context.chat else { return }
        withObservationTracking {
            _ = chat.quotePreviewRevision
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.invalidateAll()
                self.observeQuoteReadiness()
            }
        }
    }

    private func observeDecorations() {
        guard let chat = self.context.chat else { return }
        let gateway = self.context.gateway
        withObservationTracking {
            _ = chat.items
            _ = chat.agentReactions
            _ = chat.sharedReactions
            _ = chat.reactionSelfId
            _ = gateway.sessionReactionsOff
            _ = chat.locatingReplyId
            _ = chat.branchAnchorId
            _ = chat.canSwitchBranches
            _ = chat.isRunning
            _ = gateway.reactions
            _ = BookmarkStore.shared(gatewayId: gateway.id).bookmarks
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.decorationsChanged()
                self.observeDecorations()
            }
        }
    }

    private func decorationsChanged() {
        let builder = TranscriptLayoutBuilder(context: self.context, settings: self.settings, flash: self.flash,
                                              messagePartExcerptCache: self.messagePartExcerptCache)
        var stale: Set<String> = []
        for (id, entry) in self.cache where builder.decoration(for: entry.row) != entry.layout.decoration {
            stale.insert(id)
        }
        self.invalidate(stale)
    }

    /// The 👀 on your latest message comes and goes with runs, so only its old and new rows update.
    private func observeAck() {
        guard let chat = self.context.chat else { return }
        let ack = withObservationTracking {
            chat.ackMessageId
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, chat === self.context.chat else { return }
                self.observeAck()
            }
        }
        guard ack != self.ack else { return }
        let old = self.ack
        self.ack = ack
        self.invalidate(Set([old, ack].compactMap { $0 }.compactMap(self.rowId(containing:))))
    }

    /// The transcript row showing a message.
    private func rowId(containing messageId: String) -> String? {
        for entry in self.context.chat?.entries ?? [] {
            switch entry {
            case let .user(item) where item.transcriptId == messageId: return entry.id
            case let .assistant(turn) where turn.textIds.contains(messageId): return entry.id
            default: continue
            }
        }
        return nil
    }

    private func setFlash(_ messageId: String?) {
        let old = self.flash
        self.flash = messageId
        self.invalidate(Set([old, messageId].compactMap { $0 }.compactMap(self.rowId(containing:))))
    }

    #if os(iOS)
    /// The list's light/dark style changed: rich blocks (diagrams, math) are drawn per appearance,
    /// so rebuild rows if the rendered palette differs. iOS renders app-switcher snapshots in both
    /// styles while backgrounded; those flips are skipped and re-checked on becoming active.
    func appearanceChanged() {
        guard UIApplication.shared.applicationState != .background else { return }
        self.settingsChanged()
    }
    #endif

    @discardableResult private func settingsChanged() -> Bool {
        let settings = TranscriptSettings.current(for: self.context)
        guard settings != self.settings else { return false }
        self.settings = settings
        self.invalidateAll()
        return true
    }

    // MARK: TranscriptRowActions

    func setExpanded(_ key: String, _ expanded: Bool, row: String) {
        self.context.disclosure.set(key, expanded: expanded)
        self.invalidate([row], keepInPlace: row)
    }

    /// Search within a tool card: opens or closes it, sets the query or the current match. Only the
    /// card's row is laid out again; `reveal` scrolls to the current match.
    func setToolSearch(_ toolId: String, row: String, open: Bool? = nil, query: String? = nil, current: Int? = nil,
                       reveal: Bool = false)
    {
        let store = self.context.disclosure.toolSearch
        var state = store.state(for: toolId)
        if let query { state.query = query }
        if let current { state.current = current }
        store.set(state, for: toolId)
        if let open { self.context.disclosure.set(ToolCardSearchStore.key(toolId), expanded: open) }
        self.invalidate([row], keepInPlace: row)
        if reveal { self.onReveal?(row) }
    }

    func openRun(_ sessionKey: String) {
        self.context.gateway.selectedKey = sessionKey
    }

    func openChat(_ sessionKey: String) {
        let gateway = self.context.gateway
        gateway.selectedKey = gateway.resolveSessionKey(sessionKey)
    }

    func openMCPServer(_ name: String) {
        self.context.openMCPServer(name)
    }

    func preview(_ ref: ImageRef) {
        self.context.previewImage(ref)
    }

    func previewHTML(_ html: String) {
        self.context.previewHTML(html)
    }

    func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func loadImage(_ ref: ImageRef) {
        self.context.gateway.images.load(ref, sessionKey: self.context.sessionKey)
    }

    func loadFilePreview(_ file: FileRef) {
        self.context.gateway.files.loadPreview(file, sessionKey: self.context.sessionKey)
    }

    func saveFile(_ file: FileRef) async -> Bool {
        let context = self.context
        guard let data = await context.gateway.files.data(for: file, sessionKey: context.sessionKey) else { return false }
        context.saveFile(file, data)
        return true
    }

    func quickLook(_ file: FileRef) async -> Bool {
        let context = self.context
        guard let data = await context.gateway.files.data(for: file, sessionKey: context.sessionKey) else { return false }
        let name = file.name, mimeType = file.mimeType
        let url = await Task.detached(priority: .userInitiated) {
            try? FilePreviewFiles.write(data, name: name, mimeType: mimeType)
        }.value
        guard let url else { return false }
        context.quickLook(url)
        return true
    }

    func copyLink(to messageId: String) {
        self.context.copyLink(messageId)
    }

    func toggleBookmark(_ messageId: String) {
        self.context.toggleBookmark(messageId)
    }

    func isBookmarked(_ messageId: String) -> Bool {
        self.context.isBookmarked(messageId)
    }

    func reply(to messageId: String) {
        self.context.reply(messageId)
    }

    func canReadAloud(_ messageId: String) -> Bool {
        guard let item = self.context.chat?.message(withId: messageId), item.role == .assistant,
              !item.isPending, !item.isError,
              let entry = self.speechCache.value(messageID: messageId) else { return false }
        return entry.isEligible
    }

    func canReadAloud(_ messageId: String, rowID: String) -> Bool {
        guard let chat = self.context.chat,
              let item = chat.message(withId: messageId),
              item.role == .assistant, !item.isPending, !item.isError,
              let entry = self.cache[rowID], !entry.invalidated else {
            self.invalidateSpeechReadiness(for: [messageId])
            return false
        }
        let row = entry.layout
        if let prepared = self.speechCache.value(messageID: messageId) {
            return prepared.isEligible
        }
        self.queueSpeechPreparation(item, chat: chat, messageID: messageId, rowID: rowID,
                                    layoutSerial: row.serial, startPlayback: false)
        return false
    }

    func isReadingAloud(_ messageId: String) -> Bool { ReadAloudController.shared.isActive(messageId) }

    func readAloud(_ messageId: String) {
        let controller = ReadAloudController.shared
        if controller.isActive(messageId) { return controller.stop() }
        guard let item = self.context.chat?.message(withId: messageId), item.role == .assistant,
              !item.isPending, !item.isError,
              let value = self.speechCache.value(messageID: messageId), value.isEligible,
              let text = value.speechText,
              value.sourceRevision == self.context.chat?.contentRevision else { return }
        controller.start(messageId: messageId, text: text, gateway: self.context.gateway.voice)
    }

    func readAloud(_ messageId: String, rowID: String) {
        let controller = ReadAloudController.shared
        if controller.isActive(messageId) { controller.stop(); return }
        guard let chat = self.context.chat,
              let item = chat.message(withId: messageId),
              item.role == .assistant, !item.isPending, !item.isError,
              let entry = self.cache[rowID], !entry.invalidated else { return }
        let row = entry.layout
        if let value = self.speechCache.value(messageID: messageId) {
            if !value.isEligible, value.sourceRevision == chat.contentRevision { return }
            if value.isEligible, value.sourceRevision == chat.contentRevision, let text = value.speechText {
                controller.start(messageId: messageId, text: text, gateway: self.context.gateway.voice)
                return
            }
        }
        self.queueSpeechPreparation(item, chat: chat, messageID: messageId, rowID: rowID,
                                    layoutSerial: row.serial, startPlayback: true)
    }

    private func queueSpeechPreparation(_ item: ChatItem, chat: ChatStore, messageID: String,
                                        rowID: String, layoutSerial: Int, startPlayback: Bool) {
        if var job = self.speechJobs[messageID] {
            job.rowID = rowID
            job.layoutSerial = layoutSerial
            job.shouldStartPlayback = job.shouldStartPlayback || startPlayback
            self.speechJobs[messageID] = job
            return
        }
        // A visible transcript can be long; bound both the number of retained item snapshots and
        // the number of actor waiters created by a single renderer.
        guard self.speechWorkerCount < 16 else {
            self.deferSpeechPreparation(messageID: messageID, rowID: rowID,
                                        layoutSerial: layoutSerial, startPlayback: startPlayback)
            return
        }
        let token = self.speechCache.begin(messageID: messageID)
        let revision = chat.contentRevision
        #if DEBUG
        let probe = self.speechPreparationProbe
        let gate = self.speechPreparationGate
        #endif
        self.speechWorkerCount += 1
        let task = Task { [weak self, weak chat] in
            #if DEBUG
            let prepared = await Self.speechPreparationWorker.prepare(item, probe: probe, gate: gate)
            #else
            let prepared = await Self.speechPreparationWorker.prepare(item, probe: nil)
            #endif
            guard let self else { return }
            self.speechWorkerCount = max(0, self.speechWorkerCount - 1)
            guard !Task.isCancelled, let prepared, let chat else {
                self.drainPendingSpeechPreparations()
                return
            }
            self.finishSpeechPreparation(prepared, token: token, messageID: messageID,
                                         chat: chat, sourceRevision: revision)
        }
        self.speechJobs[messageID] = SpeechJob(token: token, rowID: rowID, layoutSerial: layoutSerial,
                                               chat: chat, shouldStartPlayback: startPlayback, task: task)
    }

    private func deferSpeechPreparation(messageID: String, rowID: String, layoutSerial: Int,
                                        startPlayback: Bool) {
        if var pending = self.pendingSpeechPreparations[messageID] {
            pending.rowID = rowID
            pending.layoutSerial = layoutSerial
            pending.shouldStartPlayback = pending.shouldStartPlayback || startPlayback
            self.pendingSpeechPreparations[messageID] = pending
            return
        }
        guard self.pendingSpeechPreparations.count < Self.layoutCacheLimit else { return }
        self.nextPendingSpeechOrderToken &+= 1
        let token = self.nextPendingSpeechOrderToken
        self.pendingSpeechPreparations[messageID] = PendingSpeechPreparation(
            rowID: rowID, layoutSerial: layoutSerial, shouldStartPlayback: startPlayback,
            orderToken: token)
        self.pendingSpeechOrder.append(PendingSpeechOrderEntry(messageID: messageID, token: token))
        self.compactPendingSpeechOrderIfNeeded()
    }

    private func drainPendingSpeechPreparations() {
        guard let chat = self.context.chat else {
            self.pendingSpeechPreparations.removeAll()
            self.pendingSpeechOrder.removeAll()
            self.pendingSpeechHead = 0
            return
        }
        while self.speechWorkerCount < 16, self.pendingSpeechHead < self.pendingSpeechOrder.count {
            let pendingOrder = self.pendingSpeechOrder[self.pendingSpeechHead]
            self.pendingSpeechHead += 1
            let messageID = pendingOrder.messageID
            guard let pending = self.pendingSpeechPreparations[messageID],
                  pending.orderToken == pendingOrder.token else { continue }
            self.pendingSpeechPreparations[messageID] = nil
            guard
                  let entry = self.cache[pending.rowID], !entry.invalidated,
                  entry.layout.serial == pending.layoutSerial,
                  entry.layout.messages.contains(where: { $0.id == messageID }),
                  let item = chat.message(withId: messageID), item.role == .assistant,
                  !item.isPending, !item.isError else { continue }
            self.queueSpeechPreparation(item, chat: chat, messageID: messageID, rowID: pending.rowID,
                                        layoutSerial: pending.layoutSerial,
                                        startPlayback: pending.shouldStartPlayback)
        }
        self.compactPendingSpeechOrderIfNeeded()
    }

    private func compactPendingSpeechOrderIfNeeded() {
        if self.pendingSpeechPreparations.isEmpty {
            self.pendingSpeechOrder.removeAll(keepingCapacity: true)
            self.pendingSpeechHead = 0
            return
        }
        if self.pendingSpeechHead > 64, self.pendingSpeechHead * 2 >= self.pendingSpeechOrder.count {
            self.pendingSpeechOrder.removeFirst(self.pendingSpeechHead)
            self.pendingSpeechHead = 0
        }
        if self.pendingSpeechOrder.count > Self.layoutCacheLimit * 2 {
            self.pendingSpeechOrder = self.pendingSpeechOrder.dropFirst(self.pendingSpeechHead).filter { entry in
                self.pendingSpeechPreparations[entry.messageID]?.orderToken == entry.token
            }
            self.pendingSpeechHead = 0
        }
    }

    private func finishSpeechPreparation(_ prepared: SpeechEligibilityCache.Prepared,
                                         token: SpeechEligibilityCache.Token, messageID: String,
                                         chat: ChatStore,
                                         sourceRevision: Int) {
        guard let job = self.speechJobs[messageID], job.token == token else { return }
        self.speechJobs[messageID] = nil
        defer { self.drainPendingSpeechPreparations() }
        guard job.chat === chat else { return }
        let rowID = job.rowID
        let layoutSerial = job.layoutSerial
        guard self.context.chat === chat, let current = chat.message(withId: messageID),
              let rowEntry = self.cache[rowID], !rowEntry.invalidated else {
            self.speechCache.invalidate(messageID: messageID)
            return
        }
        guard rowEntry.layout.serial == layoutSerial else {
            self.speechCache.invalidate(messageID: messageID)
            if rowEntry.layout.messages.contains(where: { $0.id == messageID }) {
                self.queueSpeechPreparation(current, chat: chat, messageID: messageID, rowID: rowID,
                                            layoutSerial: rowEntry.layout.serial,
                                            startPlayback: job.shouldStartPlayback)
            }
            return
        }
        guard chat.contentRevision == sourceRevision else {
            self.speechCache.invalidate(messageID: messageID)
            if let current = chat.message(withId: messageID),
               let currentRow = self.cache[rowID]?.layout,
               currentRow.messages.contains(where: { $0.id == messageID }) {
                self.queueSpeechPreparation(current, chat: chat, messageID: messageID, rowID: rowID,
                                            layoutSerial: currentRow.serial,
                                            startPlayback: job.shouldStartPlayback)
            }
            return
        }
        guard self.speechCache.complete(token, with: prepared, sourceRevision: sourceRevision) else { return }
        // Readiness changes a button's visibility, not packed geometry. Advance only the cached
        // layout token so native cells reconfigure without rebuilding or measuring the body.
        guard let readySerial = self.advanceReadinessLayoutSerial(rowID: rowID) else { return }
        // Other preparations in the same row should finish against the token the cell now expects.
        let jobIDs = self.speechJobs.compactMap { $0.value.rowID == rowID ? $0.key : nil }
        for id in jobIDs {
            self.speechJobs[id]?.layoutSerial = readySerial
        }
        let pendingIDs = self.pendingSpeechPreparations.compactMap { $0.value.rowID == rowID ? $0.key : nil }
        for id in pendingIDs {
            self.pendingSpeechPreparations[id]?.layoutSerial = readySerial
        }
        self.onInvalidate?(Set([rowID]), nil)
        guard job.shouldStartPlayback, prepared.isEligible, let text = prepared.speechText,
              chat.contentRevision == sourceRevision, self.context.chat === chat else { return }
        ReadAloudController.shared.start(messageId: messageID, text: text, gateway: self.context.gateway.voice)
    }

    private func advanceReadinessLayoutSerial(rowID: String) -> Int? {
        guard var entry = self.cache[rowID], !entry.invalidated else { return nil }
        self.serial += 1
        entry.layout.serial = self.serial
        self.cache[rowID] = entry
        return self.serial
    }

    func canBranch(from messageId: String) -> Bool { self.context.chat?.canBranch(from: messageId) ?? false }
    func canEdit(_ messageId: String) -> Bool { self.context.chat?.canEdit(messageId) ?? false }
    func canRegenerate(_ messageId: String) -> Bool { self.context.chat?.canRegenerate(messageId) ?? false }

    func branch(from messageId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.branch(from: messageId) }
    }

    func edit(_ messageId: String) {
        _ = self.context.chat?.beginEdit(messageId)
    }

    func regenerate(_ messageId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.regenerate(messageId) }
    }

    func toggleReaction(_ emoji: String, on messageId: String) {
        guard self.settings.reactionsEnabled else { return }
        self.context.chat?.toggleReaction(emoji, on: messageId)
    }

    func pickReaction(for messageId: String, from view: PView, rect: CGRect) {
        guard self.settings.reactionsEnabled else { return }
        guard let chat = self.context.chat else { return }
        let hint: String? = chat.usesGatewayReactions ? L("The agent sees your reactions on its next turn.") : nil
        ReactionPicker.present(from: view, rect: rect, hint: hint) { [weak self] emoji in
            guard self?.settings.reactionsEnabled == true else { return }
            chat.toggleReaction(emoji, on: messageId)
        }
    }

    var reactionsEnabled: Bool { self.settings.reactionsEnabled }

    var branchEntries: [TranscriptBranchEntry] {
        (self.context.chat?.branches ?? []).map { branch in
            TranscriptBranchEntry(leafEntryId: branch.leafEntryId,
                                  title: BranchMenuEntry.title(for: branch),
                                  isActive: branch.active)
        }
    }

    func stepBranch(_ offset: Int) {
        guard let chat = self.context.chat, let number = chat.activeBranchNumber,
              chat.branches.indices.contains(number - 1 + offset) else { return }
        let target = chat.branches[number - 1 + offset].leafEntryId
        Task { await chat.switchBranch(to: target) }
    }

    func switchBranch(to leafEntryId: String) {
        guard let chat = self.context.chat else { return }
        Task { await chat.switchBranch(to: leafEntryId) }
    }

    func retrySend(_ id: String) {
        self.context.chat?.retry(outboxId: id)
    }

    func sendNow(_ id: String) {
        self.context.chat?.sendNow(outboxId: id)
    }

    func deleteSend(_ id: String) {
        self.context.chat?.deleteQueued(outboxId: id)
    }

    func showOriginal(_ messageId: String) { self.showOriginal(messageId, missingNotice: nil, isReplyTarget: true) }

    private var olderLoop: Task<Void, Never>?
    private weak var olderLoopChat: ChatStore?
    /// The chat whose visible older row should resume after the current bounded paging pass.
    /// Weak because the context is the owner; a chat switch must not keep the old store alive.
    private weak var resumeOlderChat: ChatStore?

    /// Waits for the current paging pass to finish. Used by deterministic controller tests.
    func waitForOlderLoop() async {
        while let loop = self.olderLoop { await loop.value }
    }

    /// The loading-older row is on screen: pages in older history (the cache first) for as long as
    /// the row stays visible, so a page that adds no rows (duplicates, rows folding together) doesn't
    /// stall the list. Failures back off a second and give up after a few.
    func loadOlderIfShown(stillVisible: @escaping @MainActor () -> Bool) {
        guard stillVisible(), let chat = self.context.chat, chat.hasOlderItems else { return }
        guard self.olderLoop == nil else {
            // A list/context update can arrive while the previous chat's page is still unwinding.
            // A different chat gets its own pass after the old one; same-chat list updates do not
            // reset the bounded failure limit.
            if self.olderLoopChat !== chat { self.resumeOlderChat = chat }
            return
        }
        if self.resumeOlderChat === chat { self.resumeOlderChat = nil }
        self.olderLoopChat = chat
        self.olderLoop = Task { @MainActor [weak self] in
            var failures = 0
            for _ in 0..<40 {
                guard chat.hasOlderItems, !Task.isCancelled else { break }
                let loaded: Bool
                if let pageLoader = self?.olderPageLoader {
                    loaded = await pageLoader(chat)
                } else {
                    loaded = await chat.loadOlder()
                }
                if loaded {
                    failures = 0
                } else {
                    failures += 1
                    guard failures < 3 else { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                // Let the list apply the new rows before asking whether the row is still on screen.
                try? await Task.sleep(for: .milliseconds(120))
                guard stillVisible(), self?.context.chat === chat else { break }
            }
            guard let self else { return }
            self.olderLoop = nil
            self.olderLoopChat = nil
            let resumeChat = self.resumeOlderChat
            self.resumeOlderChat = nil
            if let resumeChat, resumeChat.hasOlderItems, stillVisible(), self.context.chat === resumeChat {
                self.loadOlderIfShown(stillVisible: stillVisible)
            }
        }
    }

    /// A connected edge restarts paging only when the loading row is still visible. If a bounded
    /// retry loop has not finished yet, remember one resume and launch it after that loop unwinds.
    func resumeOlderIfShown(stillVisible: @escaping @MainActor () -> Bool) {
        guard stillVisible(), let chat = self.context.chat, chat.hasOlderItems else { return }
        if self.olderLoop != nil {
            self.resumeOlderChat = chat
        } else {
            self.loadOlderIfShown(stillVisible: stillVisible)
        }
    }

    /// Scrolls to and flashes a message, paging in older history if needed. `missingNotice`
    /// replaces the chat's note when it can't be found.
    func showOriginal(_ messageId: String, missingNotice: String?, isReplyTarget: Bool = false) {
        guard let chat = self.context.chat, chat.locatingReplyId == nil else { return }
        Task { @MainActor [weak self] in
            let found = isReplyTarget ? await chat.locateReplyTarget(messageId) : await chat.locate(messageId)
            if !found, let missingNotice { chat.notice = missingNotice }
            guard found, let self, chat === self.context.chat,
                  let row = self.rowId(containing: messageId) else { return }
            self.flashToken += 1
            let token = self.flashToken
            self.setFlash(messageId)
            self.onReveal?(row)
            try? await Task.sleep(for: .seconds(1.6))
            guard self.flashToken == token else { return }
            self.setFlash(nil)
        }
    }
}

/// Scroll behavior shared by the AppKit and UIKit transcripts.
enum TranscriptLayout {
    /// Within this distance of the end, new content keeps the transcript scrolled to the bottom.
    static let stickToBottomDistance: CGFloat = 80
    static let rowSpacing: CGFloat = 2
    static let verticalInset: CGFloat = 12

    /// Rough height for a row that hasn't been laid out yet, so the scroll bar and off-screen
    /// positions are close before the row is laid out for real.
    @MainActor static func estimatedHeight(_ row: TranscriptRow, width: CGFloat,
                                hasReactions: (String) -> Bool = { _ in false }) -> CGFloat {
        let textWidth = max(width - TranscriptMetrics.contentX - TranscriptMetrics.sidePadding, 120)
        let charactersPerLine = max(textWidth / 7, 10)
        let scaffold: CGFloat = 12 + 22
        let footer: CGFloat = TranscriptMetrics.footerSpacing + 16
        let chips = TranscriptLayoutBuilder.chipHeight + 6
        switch row {
        case .loadingOlder:
            return 36
        case .entry(.marker):
            return 32
        case let .entry(.user(item)):
            let footprint = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: Double(charactersPerLine), hasReactions: hasReactions)
            #if DEBUG
            ColdTranscriptHeightEstimateProbe.recordWork(row.id, bytes: footprint.inspectedBytes, visits: footprint.metadataVisits)
            #endif
            return scaffold + CGFloat(footprint.lines) * 18 + (footprint.hasImages ? 240 : 0) + CGFloat(footprint.fileCount) * 36
                + (!footprint.hasRawText && item.outboxState == nil ? 0 : footer) + (item.replyToId != nil ? 50 : 0)
                + CGFloat(footprint.reactionCount) * chips + CGFloat(footprint.extraHeight)
        case let .entry(.assistant(turn)):
            let footprint = ColdTranscriptFootprint.estimate(.assistant(turn), charactersPerLine: Double(charactersPerLine), hasReactions: hasReactions)
            #if DEBUG
            ColdTranscriptHeightEstimateProbe.recordWork(row.id, bytes: footprint.inspectedBytes, visits: footprint.metadataVisits)
            #endif
            var height = scaffold
            if turn.isStreaming, ThinkingDisplay.current != .none {
                if !turn.thinking.isEmpty { height += 26 }
                height += CGFloat(turn.tools.count) * 34
            } else if ThinkingDisplay.current == .all, !turn.thinking.isEmpty || !turn.tools.isEmpty {
                height += 26
            }
            if footprint.textSourceCount > 0 { height += CGFloat(footprint.lines) * 18 + CGFloat(footprint.textSourceCount) * footer }
            if !turn.images.isEmpty { height += 240 }
            height += CGFloat(turn.files.count) * 36
            height += CGFloat(footprint.reactionCount) * chips + CGFloat(footprint.extraHeight)
            return height
        }
    }
}
