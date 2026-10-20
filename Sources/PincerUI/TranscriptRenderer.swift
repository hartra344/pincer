import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lays out rows for the AppKit and UIKit lists and tells them when a row's layout is stale:
/// its disclosure toggled, an image it shows loaded, a subagent run it links to appeared, or a
/// setting or the text size changed.
@MainActor
final class TranscriptRenderer: TranscriptRowActions {
    let messagePartExcerptCache: MessagePartExcerptCache
    struct Entry {
        let row: TranscriptRow
        var layout: TranscriptRowLayout
        var stamp: Int
        var invalidated = false
    }

    struct SpeechJob {
        let token: SpeechEligibilityCache.Token
        var rowID: String
        var layoutSerial: Int
        let chat: ChatStore
        var shouldStartPlayback: Bool
        var task: Task<Void, Never>?
    }

    struct PendingSpeechPreparation {
        var rowID: String
        var layoutSerial: Int
        var shouldStartPlayback: Bool
        let orderToken: UInt64
    }

    struct PendingSpeechOrderEntry {
        let messageID: String
        let token: UInt64
    }

    actor SpeechPreparationWorker {
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

    static let speechPreparationWorker = SpeechPreparationWorker()

    /// Layouts kept for rows; the least recently used go first. Heights of rows without one
    /// live in the list, so a dropped layout only costs a relayout when the row is next drawn.
    static let layoutCacheLimit = 800

    enum ImageState: Equatable { case loading, loaded, failed }

    private(set) var context: TranscriptContext
    let liveAvatar: TranscriptLiveAvatar? = TranscriptLiveAvatar()
    private(set) var highlight = TranscriptHighlight()
    var settings: TranscriptSettings
    var cache: [String: Entry] = [:]
    var speechCache = SpeechEligibilityCache()
    var speechJobs: [String: SpeechJob] = [:]
    var speechWorkerCount = 0
    // Retain only IDs and row coordinates while the worker is full; ChatStore remains the source
    // of item snapshots. Both this queue and active jobs are bounded independently.
    var pendingSpeechPreparations: [String: PendingSpeechPreparation] = [:]
    var pendingSpeechOrder: [PendingSpeechOrderEntry] = []
    var pendingSpeechHead = 0
    var nextPendingSpeechOrderToken: UInt64 = 0
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
    var imageRows: [String: Set<String>] = [:]
    var imageStates: [String: ImageState] = [:]
    var imageRefs: [String: ImageRef] = [:]
    var fileRows: [String: Set<String>] = [:]
    var filePreviews: [String: FileContentLoader.Preview?] = [:]
    var spawnRows: Set<String> = []
    var pageRows: Set<String> = []
    var pageTurns: [String: String] = [:]
    /// URLs a card asked to load, kept (bounded) so they load again once the Gateway connects.
    var requestedPages: [URL] = []
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var accessibilityObservation: NSObjectProtocol?
    #endif
    #if os(macOS)
    /// Dark Mode flips re-lay out rows, so rendered diagrams and math pick up the matching palette.
    private var appearanceObservation: NSKeyValueObservation?
    #endif
    /// The message flashing after a jump from its quote.
    var flash: String?
    var flashToken = 0
    var ack: String?
    /// Testable page source for exercising the older-row loop without touching the transcript cache.
    var olderPageLoader: (@MainActor (ChatStore) async -> Bool)?

    /// Rows whose layout changed (nil means all of them), and a row to hold still on screen while
    /// they change, when the change came from a click in that row.
    var serial = 0
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
        self.observePagePreviews()
        self.observeConnection()
        self.observeFiles()
        self.observeSessions()
        self.observeDecorations()
        self.observeQuoteReadiness()
        self.observeAck()
        let center = NotificationCenter.default
        // Not `queue: .main`: that makes every defaults write on another thread wait for main.
        self.observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            let changed: @Sendable () -> Void = { MainActor.assumeIsolated { _ = self?.settingsChanged() } }
            if Thread.isMainThread { changed() } else { DispatchQueue.main.async(execute: changed) }
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
                                    flash: self.flash, pageTurns: self.pageTurns,
                                    messagePartExcerptCache: self.messagePartExcerptCache)
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
        if layout.pages.isEmpty { self.pageRows.remove(row.id) } else { self.pageRows.insert(row.id) }
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
        self.pageRows.subtract(gone)
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
        self.pageRows.removeAll()
        self.pageTurns = [:]
    }

    func invalidate(_ ids: Set<String>, keepInPlace: String? = nil) {
        guard !ids.isEmpty else { return }
        self.markLayoutInvalidated(ids)
        self.onInvalidate?(ids, keepInPlace)
    }

    func markLayoutInvalidated(_ ids: Set<String>) {
        for id in ids {
            guard var entry = self.cache[id] else { continue }
            entry.invalidated = true
            self.cache[id] = entry
        }
    }

    func invalidateSpeechReadiness(for messageIDs: [String]) {
        for id in Set(messageIDs) {
            self.speechCache.invalidate(messageID: id)
            self.speechJobs[id]?.task?.cancel()
            self.speechJobs[id] = nil
            self.pendingSpeechPreparations[id] = nil
        }
        self.compactPendingSpeechOrderIfNeeded()
    }

    func invalidateAll() {
        self.reset()
        self.onInvalidate?(nil, nil)
    }

    var olderLoop: Task<Void, Never>?
    weak var olderLoopChat: ChatStore?
    /// The chat whose visible older row should resume after the current bounded paging pass.
    /// Weak because the context is the owner; a chat switch must not keep the old store alive.
    weak var resumeOlderChat: ChatStore?
}
