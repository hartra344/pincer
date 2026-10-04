import CoreGraphics
import Foundation
import PincerKit
import Synchronization
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The fonts message text is built with, copied out of `TranscriptStyle` so a background thread
/// never touches the main-actor style object. Fonts are immutable, so sharing them is safe.
struct TranscriptFonts: @unchecked Sendable {
    let body: PFont
    let bodySemibold: PFont
    let headline: PFont
    let code: PFont
    let title2: PFont
    let title3: PFont
    let listMarker: PFont

    @MainActor init(_ style: TranscriptStyle) {
        self.body = style.body
        self.bodySemibold = style.bodySemibold
        self.headline = style.headline
        self.code = style.code
        self.title2 = style.title2
        self.title3 = style.title3
        self.listMarker = style.listMarker
    }
}

/// Everything `TranscriptText.build` reads from main-actor state, captured once. Text runs carry
/// dynamic system colors that resolve when drawn, so segments and their heights don't depend on
/// the appearance; `dark` only keys the caches, because inline math bakes a resolved color.
struct TextBuildEnvironment: @unchecked Sendable {
    let fonts: TranscriptFonts
    let colors: (primary: PColor, secondary: PColor, error: PColor, fill: PColor)
    let styleGeneration: Int
    let dark: Bool
    /// Pixels per point inline math is drawn at; read on main because screens aren't thread safe.
    let mathScale: CGFloat

    @MainActor private static var memo: TextBuildEnvironment?

    @MainActor static func current(dark: Bool) -> TextBuildEnvironment {
        if let memo, memo.styleGeneration == TranscriptStyle.generation, memo.dark == dark, memo.mathScale == InlineMathText.scale { return memo }
        let made = TextBuildEnvironment(
            fonts: TranscriptFonts(TranscriptStyle.shared),
            colors: (TranscriptColors.label, TranscriptColors.secondary, TranscriptColors.red, TranscriptColors.fill),
            styleGeneration: TranscriptStyle.generation, dark: dark, mathScale: InlineMathText.scale)
        self.memo = made
        return made
    }

    func color(for tone: TranscriptText.Tone) -> PColor {
        switch tone {
        case .primary: self.colors.primary
        case .secondary: self.colors.secondary
        case .error: self.colors.error
        }
    }
}

/// One private TextKit 1 stack. The main thread owns one and the premeasure worker owns another;
/// a stack is never shared, and never attached to a view, so neither needs a lock. Configured like
/// the stacks row views draw with (`TranscriptTextKit.stack`), so heights match what is drawn.
final class TranscriptTextMeasurer {
    private let storage = NSTextStorage()
    private let container = NSTextContainer(size: .zero)

    nonisolated init() {
        let manager = NSLayoutManager()
        self.container.lineFragmentPadding = 0
        manager.addTextContainer(self.container)
        self.storage.addLayoutManager(manager)
    }

    /// Size of `string` wrapped to `width` (unwrapped when width is infinite), rounded up to points
    /// unless `exact`.
    nonisolated func size(_ string: NSAttributedString, width: CGFloat, exact: Bool = false) -> CGSize {
        guard string.length > 0, width > 0 else { return .zero }
        let manager = self.container.layoutManager!
        self.container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        self.storage.setAttributedString(string)
        manager.ensureLayout(for: self.container)
        let used = manager.usedRect(for: self.container)
        return exact ? CGSize(width: ceil(used.width), height: used.height) : CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// Width of `string` on one line, ignoring paragraph alignment.
    nonisolated func naturalWidth(_ string: NSAttributedString) -> CGFloat {
        guard string.length > 0 else { return 0 }
        let unaligned = NSMutableAttributedString(attributedString: string)
        unaligned.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: unaligned.length))
        return self.size(unaligned, width: .greatestFiniteMagnitude).width
    }
}

// MARK: - Off-main premeasure

/// How a table's columns share the width. Main lays tables out with it and the worker measures
/// their cells with it, so both land on the same column widths.
enum TranscriptTableMetrics {
    static let minimumColumn: CGFloat = 72
    static let maximumColumn: CGFloat = 320
    static let padding: CGFloat = 20

    /// Columns share `available` when each can keep a readable minimum; otherwise the table keeps its
    /// natural column widths (each column's widest cell plus padding) and scrolls sideways.
    static func columnWidths(naturals: [CGFloat], available: CGFloat) -> [CGFloat] {
        let ideals = naturals.map { min($0 + self.padding, self.maximumColumn) }
        let minimums = ideals.map { min($0, self.minimumColumn) }
        let idealTotal = ideals.reduce(0, +), minimumTotal = minimums.reduce(0, +)
        guard idealTotal > available, minimumTotal <= available else { return ideals }
        let slack = available - minimumTotal
        let flexible = idealTotal - minimumTotal
        return zip(ideals, minimums).map { ideal, minimum in
            floor(flexible > 0 ? minimum + (ideal - minimum) / flexible * slack : minimum)
        }
    }
}

/// One message body as the text cache keys it, plus the style it is built with.
struct PremeasureKey: Hashable, Sendable {
    let textKey: TranscriptText.Key
    let styleGeneration: Int
    var source: String { self.textKey.source }
    var tone: TranscriptText.Tone { self.textKey.tone }

    /// Rows with inline math never reach the worker, so their appearance never keys a premeasured body.
    nonisolated init(source: String, tone: TranscriptText.Tone, styleGeneration: Int) {
        self.init(source: source, tone: tone, styleGeneration: styleGeneration, dark: false)
    }

    nonisolated init(source: String, tone: TranscriptText.Tone, styleGeneration: Int, dark: Bool) {
        self.textKey = TranscriptText.Key(source: source, tone: tone, dark: dark)
        self.styleGeneration = styleGeneration
    }
}

/// The message bodies of one row, to build and measure at one content width.
struct PremeasureJob: Sendable {
    let rowId: String
    var bodies: [PremeasureKey]
    var sourceRow: TranscriptRow? = nil
    var sourceStyleGeneration: Int = 0
    var sourceDark = false
    var request: PremeasureRequest? = nil
    let contentWidth: CGFloat
    let epoch: Int
    var rowRevision: UInt64 = 0
    #if DEBUG
    var beforeSourcePreparation: (@Sendable (String) -> Void)? = nil
    #endif
}

/// A measured segment: `index` is its place in the body's segments.
struct SegmentHeight: Sendable {
    let index: Int
    let width: CGFloat
    let exact: Bool
    let height: CGFloat
    let usedWidth: CGFloat
}

/// A measured table cell: `natural` is its one-line width, and `height` its height at `width`.
struct CellMeasure: Sendable {
    let index: Int
    let row: Int
    let column: Int
    let natural: CGFloat
    let width: CGFloat
    let height: CGFloat
    let usedWidth: CGFloat
}

struct PremeasuredBody: @unchecked Sendable {
    let key: PremeasureKey
    let segments: [TranscriptText.Segment]
    let heights: [SegmentHeight]
    var cells: [CellMeasure] = []
}

/// What the worker hands back for one row. The attributed strings inside are built on the worker
/// and never touched by it again after hand-off, so main can share them like any cached segment.
struct PremeasuredRow: @unchecked Sendable {
    let rowId: String
    let epoch: Int
    let contentWidth: CGFloat
    var rowRevision: UInt64 = 0
    var bodies: [PremeasuredBody] = []
    /// Bodies the worker can't build (inline math), which stay on the main path.
    var rejected: [PremeasureKey] = []
    /// Skipped because the epoch moved on before the worker got to it.
    var discarded = false
    var sourceKeys: [PremeasureKey] = []
    var sourceBytes = 0
    var sourceIneligible = false
}

/// A cancellation token per list: bumping it tells the worker to drop everything queued for it.
final class TranscriptPremeasureEpoch: Sendable {
    private let value = Mutex<Int>(0)

    @discardableResult func bump() -> Int { self.value.withLock { $0 += 1; return $0 } }
    var current: Int { self.value.withLock { $0 } }
}

/// Builds and measures message text on a background queue, so the main thread finds the text and its
/// sizes already cached when it lays a row out. One serial utility queue serves every transcript.
final class TranscriptPremeasurer: @unchecked Sendable {
    static let shared = TranscriptPremeasurer()
    /// TextKit passes run off the main thread, for tests and probes.
    static let offMainLayouts = Mutex<Int>(0)

    private let queue = DispatchQueue(label: "pincer.transcript.premeasure", qos: .utility)
    /// Only used on `queue`.
    private let measurer = TranscriptTextMeasurer()

    nonisolated func submit(_ jobs: [PremeasureJob], env: TextBuildEnvironment, epoch: TranscriptPremeasureEpoch,
                            completion: @escaping @MainActor @Sendable ([PremeasuredRow]) -> Void)
    {
        self.queue.async {
            var rows: [PremeasuredRow] = []
            for job in jobs {
                rows.append(epoch.current == job.epoch ? self.measure(job, env: env, epoch: epoch)
                    : PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth,
                                     rowRevision: job.rowRevision, discarded: true))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(rows) } }
        }
    }

    /// Measures `jobs` on the worker while main waits at most `budget` seconds; returns the rows finished
    /// by then. The worker stops between jobs at the deadline, so nothing runs on after main gave up.
    nonisolated func measureWithinPrepared(_ budget: TimeInterval, jobs: [PremeasureJob], env: TextBuildEnvironment,
                                   epoch: TranscriptPremeasureEpoch, finished: (@MainActor @Sendable () -> Void)? = nil) -> (rows: [PremeasuredRow], completed: Bool)
    {
        struct Box { var rows: [PremeasuredRow] = []; var expired = false }
        let box = Mutex(Box())
        let done = DispatchSemaphore(value: 0)
        self.queue.async {
            for job in jobs {
                if box.withLock({ $0.expired }) { break }
                let row = epoch.current == job.epoch ? self.measure(job, env: env, epoch: epoch)
                    : PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth,
                                     rowRevision: job.rowRevision, discarded: true)
                box.withLock { if !$0.expired { $0.rows.append(row) } }
            }
            done.signal()
            if let finished { DispatchQueue.main.async { MainActor.assumeIsolated { finished() } } }
        }
        let completed = done.wait(timeout: .now() + budget) == .success
        return (box.withLock { $0.expired = true; return $0.rows }, completed)
    }

    @MainActor func measureWithin(_ budget: TimeInterval, jobs: [PremeasureJob], env: TextBuildEnvironment,
                                  epoch: TranscriptPremeasureEpoch) -> [PremeasuredRow] {
        let admission = jobs.first?.request?.driver?.admission ?? TranscriptPremeasureAdmission.shared
        return admission.measureWithin(budget, jobs: jobs, env: env, epoch: epoch)
    }

    /// The same builder and measurer main uses, so the sizes are what main would compute.
    private func measure(_ job: PremeasureJob, env: TextBuildEnvironment, epoch: TranscriptPremeasureEpoch) -> PremeasuredRow {
        #if DEBUG
        PremeasureAdmissionProbe.record(job.rowId, operation: .measured)
        #endif
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        var row = PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth,
                                 rowRevision: job.rowRevision)
        var job = job
        #if DEBUG
        job.beforeSourcePreparation?(job.rowId)
        #endif
        if let sourceRow = job.sourceRow {
            guard let keys = PremeasureSource.bodies(for: sourceRow, styleGeneration: job.sourceStyleGeneration, dark: job.sourceDark) else {
                row.sourceIneligible = true
                return row
            }
            job.bodies = keys
        }
        row.sourceKeys = job.bodies
        for key in job.bodies {
            #if DEBUG
            PremeasureAdmissionProbe.record(job.rowId, operation: .sourceSize, source: key.source)
            #endif
            let bytes = key.source.utf8.count
            row.sourceBytes = bytes > Int.max - row.sourceBytes ? Int.max : row.sourceBytes + bytes
        }
        let hooks = TranscriptText.BuildHooks.worker(env: env)
        var layouts = 0
        for key in job.bodies {
            if epoch.current != job.epoch { row.discarded = true; row.bodies = []; break }
            guard let segments = TranscriptText.build(MarkdownBlock.parse(key.source), tone: key.tone, env: env, hooks: hooks) else {
                row.rejected.append(key)
                continue
            }
            var heights: [SegmentHeight] = []
            var cells: [CellMeasure] = []
            func add(_ index: Int, _ text: NSAttributedString, width: CGFloat) {
                guard text.length > 0 else { return }
                let size = self.measurer.size(text, width: width)
                layouts += 1
                heights.append(SegmentHeight(index: index, width: width, exact: false, height: size.height, usedWidth: size.width))
            }
            for (index, segment) in segments.enumerated() {
                switch segment {
                case let .text(text): add(index, text, width: job.contentWidth)
                case let .quote(text): add(index, text, width: TranscriptText.quoteWidth(for: job.contentWidth))
                case let .code(_, _, text): add(index, text, width: .greatestFiniteMagnitude)
                case let .table(table):
                    var naturals = Array(repeating: CGFloat(0), count: table.cells.first?.count ?? 0)
                    var natural: [[CGFloat]] = []
                    for cellRow in table.cells {
                        let widths = cellRow.map { self.measurer.naturalWidth($0) }
                        layouts += widths.count
                        for (column, width) in widths.enumerated() { naturals[column] = max(naturals[column], width) }
                        natural.append(widths)
                    }
                    let widths = TranscriptTableMetrics.columnWidths(naturals: naturals, available: job.contentWidth)
                    for (rowIndex, cellRow) in table.cells.enumerated() {
                        for (column, cell) in cellRow.enumerated() where cell.length > 0 {
                            let width = max(widths[column] - TranscriptTableMetrics.padding, 1)
                            let size = self.measurer.size(cell, width: width)
                            layouts += 1
                            cells.append(CellMeasure(index: index, row: rowIndex, column: column, natural: natural[rowIndex][column],
                                                     width: width, height: size.height, usedWidth: size.width))
                        }
                    }
                case .rule: break
                }
            }
            row.bodies.append(PremeasuredBody(key: key, segments: segments, heights: heights, cells: cells))
        }
        Self.offMainLayouts.withLock { $0 += layouts }
        return row
    }
}

struct PremeasureStats {
    /// Rows sent to the worker.
    var offloaded = 0
    /// Rows whose text and sizes were taken into the main-thread caches.
    var adopted = 0
    /// Rows whose result arrived after the width, style or list moved on.
    var discardedStale = 0
    /// Rows a prefetch or scroll pass found already measured, so main only stacks them.
    var warmHits = 0
}

/// What a list needs to offload row measuring, the same for AppKit and UIKit: which of a batch of
/// rows to lay out now and which to prepare on the worker, and taking the worker's results back.
/// Results only warm the text caches; heights still go through the list's own measure path, so
/// anchoring and height corrections are untouched. Rows are tracked by id, so paging older
/// messages in or out never shifts what is in flight.
@MainActor
final class TranscriptPremeasureDriver {
    /// Rows waiting on the worker at once, and rows per hand-off.
    static let maxInFlight = 64
    static let rowsPerJob = 16
    /// Row bodies retain their source strings, so both the number of rows and total source bytes
    /// stay bounded even when a transcript contains a few unusually large messages.
    static let memoRowLimit = TranscriptPremeasureBudget.rowLimit
    static let memoSourceByteLimit = TranscriptPremeasureBudget.sourceByteLimit

    private enum Eligibility {
        case uncomputed
        case ineligible
        case eligible([PremeasureKey])
        /// Keep only metadata when exact worker sources exceed the retained memo budget.
        case oversized
        case rejected
    }

    private struct RowMemo {
        var revision: UInt64
        var styleGeneration: Int
        var dark: Bool
        var eligibility: Eligibility
        var warmWidth: CGFloat?
        var warmCacheRevision: TranscriptText.WarmCacheRevision?
        var mainFallback: Bool
        var cost: Int
    }

    let admission: TranscriptPremeasureAdmission
    init(admission: TranscriptPremeasureAdmission = .shared) { self.admission = admission }

    private var admissionObservation: PremeasureCapacityObservation?
    private var admissionCompletion: (@MainActor () -> Void)?
    private var admissionEpoch = 0
    private var admissionCallbackScheduled = false

    func observeAdmissionCapacity(completion: @escaping @MainActor () -> Void) {
        self.admissionCompletion = completion
        self.admissionEpoch = self.epoch.current
        guard self.admissionObservation == nil else { return }
        self.admissionObservation = PremeasureCapacityObservation(service: self.admission) { [weak self] in
            self?.admissionCapacityReleased()
        }
    }
    func stopObservingAdmissionCapacity() {
        self.admissionObservation = nil
        self.admissionCompletion = nil
    }
    private func admissionCapacityReleased() {
        self.admissionObservation = nil
        guard self.admissionCompletion != nil, !self.admissionCallbackScheduled else { return }
        self.admissionCallbackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.admissionCallbackScheduled = false
            let completion = self.admissionCompletion
            self.admissionCompletion = nil
            self.admissionObservation = nil
            guard self.admissionEpoch == self.epoch.current else { return }
            completion?()
        }
    }

    let epoch = TranscriptPremeasureEpoch()
    private(set) var inFlight: [String: UInt64] = [:]
    private var rowMemos = BoundedLRUCache<String, RowMemo>(countLimit: TranscriptPremeasureBudget.rowLimit,
                                                            costLimit: TranscriptPremeasureBudget.sourceByteLimit)
    private var nextRowRevision: UInt64 = 0
    var stats = PremeasureStats()
    /// The list's width now, so results made for an older one are dropped.
    var currentWidth: () -> CGFloat = { 0 }
    var currentRow: (String) -> TranscriptRow? = { _ in nil }
    #if DEBUG
    /// Row ids sent to the worker (bounded), for tests.
    private(set) var offloadedIds: Set<String> = []
    /// Row ids whose worker results this driver accepted (bounded), for host-owned tests.
    private(set) var adoptedIds: Set<String> = []
    #endif

    /// What to do with cold rows when the worker already holds `maxInFlight`.
    enum Overflow {
        /// Leave them queued for the worker's next round (idle prefetch).
        case wait
        /// Lay them out on main like before (scroll margin, which is held to its own budget).
        case measureNow
    }

    var inFlightCount: Int { self.inFlight.count }
    #if DEBUG
    var memoRowCount: Int { self.rowMemos.count }
    var memoSourceCost: Int { self.rowMemos.totalCost }
    #endif

    /// Rows changed in place by `TranscriptListController.accept`. Advancing only these revisions
    /// keeps unchanged neighbours' memo entries hot while rejecting a late result for old text.
    func invalidateRows(_ ids: Set<String>) {
        for id in ids {
            guard self.rowMemos.value(for: id) != nil || self.inFlight[id] != nil else { continue }
            let revision = self.freshRowRevision()
            let memo = RowMemo(revision: revision, styleGeneration: -1, dark: false,
                               eligibility: .uncomputed, warmWidth: nil, warmCacheRevision: nil,
                               mainFallback: false, cost: 1)
            self.rowMemos.insert(memo, for: id, cost: memo.cost)
        }
    }

    /// The rows of `batch` (indexes into `all`, nearest first) to lay out now; cold ones are sent to the
    /// worker, and `onReady` runs on main once their results are adopted. Rows on the worker are in
    /// neither, and stay queued until then.
    func plan(_ batch: [Int], all: [TranscriptRow], width: CGFloat, renderer: TranscriptRenderer,
              overflow: Overflow, onReady: @escaping @MainActor () -> Void) -> [Int]
    {
        let split = self.split(batch, all: all, width: width, renderer: renderer, overflow: overflow)
        self.submit(split.offload, width: width, env: renderer.textEnvironment, completion: onReady)
        return split.measureNow
    }

    /// Sorts `rows` (indexes into `all`, nearest first) into those to lay out now and jobs for the
    /// worker. Rows on the worker are in neither and wait for its result.
    func split(_ rows: [Int], all: [TranscriptRow], width: CGFloat, renderer: TranscriptRenderer,
               overflow: Overflow = .wait) -> (measureNow: [Int], offload: [PremeasureJob])
    {
        var now: [Int] = []
        var jobs: [PremeasureJob] = []
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        for index in rows {
            let row = all[index]
            guard self.inFlight[row.id] == nil else { continue }
            var memo = self.memo(for: row, renderer: renderer)
            switch memo.eligibility {
            case .ineligible, .rejected:
                now.append(index)
                continue
            default: break
            }
            if memo.warmWidth != nil, memo.warmCacheRevision != TranscriptText.warmCacheRevision {
                memo.warmWidth = nil
                memo.warmCacheRevision = nil
                self.store(memo, for: row.id)
            }
            if memo.warmWidth == contentWidth || renderer.hasLayout(for: row, width: width) {
                self.stats.warmHits += 1
                now.append(index)
                continue
            }
            if memo.mainFallback { now.append(index); continue }
            guard !renderer.premeasureIsHighlighted(row.id), Self.supportsSource(row) else {
                now.append(index)
                continue
            }
            guard self.inFlight.count + jobs.count < Self.maxInFlight else { continue }
            self.store(memo, for: row.id)
            let request = PremeasureRequest(driver: self, rowID: row.id, revision: memo.revision)
            jobs.append(PremeasureJob(rowId: row.id, bodies: [], request: request,
                                      contentWidth: contentWidth, epoch: self.epoch.current,
                                      rowRevision: memo.revision))
        }
        return (now, jobs)
    }

    private func memo(for row: TranscriptRow, renderer: TranscriptRenderer) -> RowMemo {
        let styleGeneration = renderer.premeasureStyleGeneration
        let dark = renderer.premeasureDark
        if let memo = self.rowMemos.value(for: row.id), memo.styleGeneration == styleGeneration, memo.dark == dark {
            return memo
        }
        return RowMemo(revision: self.freshRowRevision(), styleGeneration: styleGeneration, dark: dark,
                       eligibility: .uncomputed, warmWidth: nil, warmCacheRevision: nil,
                       mainFallback: false, cost: 1)
    }

    private static func supportsSource(_ row: TranscriptRow) -> Bool {
        switch row {
        case .entry(.user): return true
        case let .entry(.assistant(turn)): return !turn.isStreaming
        default: return false
        }
    }

    func capture(_ job: PremeasureJob, env: TextBuildEnvironment) -> PremeasureJob? {
        guard job.epoch == self.epoch.current,
              let memo = self.rowMemos.value(for: job.rowId), memo.revision == job.rowRevision,
              let row = self.currentRow(job.rowId), Self.supportsSource(row) else { return nil }
        var captured = job
        captured.request = nil
        captured.sourceStyleGeneration = env.styleGeneration
        captured.sourceDark = env.dark
        if case let .eligible(keys) = memo.eligibility { captured.bodies = keys }
        else { captured.sourceRow = row }
        return captured
    }

    private func store(_ memo: RowMemo, for id: String) {
        self.rowMemos.insert(memo, for: id, cost: memo.cost)
    }

    private func freshRowRevision() -> UInt64 {
        self.nextRowRevision &+= 1
        return self.nextRowRevision
    }

    /// Once a width change goes quiet, measures the cold rows among `indexes` (the window around the
    /// viewport, nearest first) at the final `width` on the worker, waiting at most `budget`, so the
    /// thaw relayout finds them warm. Returns how many rows were warmed. Call after `cancelAll()`.
    @discardableResult
    func prewarm(_ indexes: [Int], all: [TranscriptRow], width: CGFloat, renderer: TranscriptRenderer,
                 budget: TimeInterval = TranscriptWidthFreeze.prewarmBudget) -> Int
    {
        let jobs = self.split(indexes, all: all, width: width, renderer: renderer, overflow: .measureNow).offload
        guard !jobs.isEmpty else { return 0 }
        let epoch = self.epoch.current
        let deadline = Date().addingTimeInterval(budget)
        var warmed = 0
        for job in jobs {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let rows = self.admission.measureWithin(remaining, jobs: [job], env: renderer.textEnvironment, epoch: self.epoch)
            guard !rows.isEmpty else { break }
            self.stats.offloaded += rows.count
            warmed += self.adopt(rows, width: width, epoch: epoch).count
            // Adopt each result before acquiring the next source: no multi-row result backlog.
        }
        return warmed
    }

    /// Sends `jobs` to the worker; `completion` runs on main after their results are adopted.
    func submit(_ jobs: [PremeasureJob], width: CGFloat, env: TextBuildEnvironment, completion: @escaping @MainActor () -> Void) {
        guard !jobs.isEmpty else { return }
        let epoch = self.epoch.current
        for job in jobs { self.inFlight[job.rowId] = job.rowRevision }
        #if DEBUG
        if self.offloadedIds.count > 10_000 { self.offloadedIds.removeAll() }
        self.offloadedIds.formUnion(jobs.map(\.rowId))
        #endif
        var denied = false
        for job in jobs {
            let accepted = self.admission.submit(job, env: env, epoch: self.epoch) { [weak self] rows in
                guard let self else { return }
                let now = self.currentWidth()
                self.adopt(rows, width: now > 0 ? now : width, epoch: epoch)
                completion()
            }
            if accepted { self.stats.offloaded += 1 }
            if !accepted {
                self.inFlight[job.rowId] = nil
                denied = true
            }
        }
        if denied { self.admission.retry(self, completion: completion) }
        else { self.stopObservingAdmissionCapacity() }
    }

    /// Takes worker results into the text caches. `width` is the list's width now; results made for
    /// another width, epoch or style are dropped. Returns the rows that are now warm.
    @discardableResult
    func adopt(_ results: [PremeasuredRow], width: CGFloat, epoch: Int) -> Set<String> {
        let current = epoch == self.epoch.current
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        var warm: Set<String> = []
        for result in results {
            let scheduledRevision = current ? self.inFlight[result.rowId] : nil
            let scheduledByDriver = scheduledRevision != nil
            if scheduledRevision == result.rowRevision { self.inFlight[result.rowId] = nil }
            guard current, !result.discarded, result.epoch == epoch, result.contentWidth == contentWidth else {
                self.stats.discardedStale += 1
                continue
            }
            let priorMemo = self.rowMemos.value(for: result.rowId)
            let memoMatches = priorMemo.map { $0.revision == result.rowRevision } ?? false
            let mayAdopt = scheduledByDriver
                ? scheduledRevision == result.rowRevision && memoMatches
                : priorMemo.map { $0.revision == result.rowRevision } ?? (result.rowRevision == 0)
            guard mayAdopt else {
                self.stats.discardedStale += 1
                continue
            }
            if var memo = priorMemo, !result.sourceKeys.isEmpty || result.sourceIneligible {
                if result.sourceIneligible { memo.eligibility = .ineligible }
                else if result.sourceBytes > Self.memoSourceByteLimit { memo.eligibility = .oversized; memo.cost = 1 }
                else { memo.eligibility = .eligible(result.sourceKeys); memo.cost = max(1, result.sourceBytes) }
                self.store(memo, for: result.rowId)
            }
            var adopted = true
            for body in result.bodies where !TranscriptText.adopt(body) { adopted = false }
            if var memo = self.rowMemos.value(for: result.rowId) {
                if !result.rejected.isEmpty {
                    memo.eligibility = .rejected
                    memo.warmWidth = nil
                    memo.warmCacheRevision = nil
                } else if adopted, case let .eligible(keys) = memo.eligibility, keys.count == result.bodies.count {
                    memo.warmWidth = contentWidth
                    memo.warmCacheRevision = TranscriptText.warmCacheRevision
                } else if adopted, case .oversized = memo.eligibility {
                    memo.warmWidth = contentWidth
                    memo.warmCacheRevision = TranscriptText.warmCacheRevision
                } else {
                    memo.mainFallback = true
                }
                self.store(memo, for: result.rowId)
            }
            if adopted {
                self.stats.adopted += 1
                warm.insert(result.rowId)
                #if DEBUG
                if self.adoptedIds.count >= 10_000 { self.adoptedIds.removeAll() }
                self.adoptedIds.insert(result.rowId)
                #endif
            } else {
                self.stats.discardedStale += 1
            }
        }
        return warm
    }

    /// Drops everything in flight: the width, style or rows it was made for are gone.
    func cancelAll() {
        self.epoch.bump()
        self.admission.remove(self)
        self.inFlight.removeAll()
        self.rowMemos.removeAll()
    }
}
