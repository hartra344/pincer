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
    let source: String
    let tone: TranscriptText.Tone
    let styleGeneration: Int
    let dark: Bool

    var textKey: TranscriptText.Key { .init(source: self.source, tone: self.tone, dark: self.dark) }

    /// Rows with inline math never reach the worker, so their appearance never keys a premeasured body.
    init(source: String, tone: TranscriptText.Tone, styleGeneration: Int) {
        self.init(source: source, tone: tone, styleGeneration: styleGeneration, dark: false)
    }

    init(source: String, tone: TranscriptText.Tone, styleGeneration: Int, dark: Bool) {
        self.source = source
        self.tone = tone
        self.styleGeneration = styleGeneration
        self.dark = TranscriptText.Key.bakesAppearance(source) ? dark : false
    }
}

/// The message bodies of one row, to build and measure at one content width.
struct PremeasureJob: Sendable {
    let rowId: String
    let bodies: [PremeasureKey]
    let contentWidth: CGFloat
    let epoch: Int
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
    var bodies: [PremeasuredBody] = []
    /// Bodies the worker can't build (inline math), which stay on the main path.
    var rejected: [PremeasureKey] = []
    /// Skipped because the epoch moved on before the worker got to it.
    var discarded = false
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
                    : PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth, discarded: true))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(rows) } }
        }
    }

    /// Measures `jobs` on the worker while main waits at most `budget` seconds; returns the rows finished
    /// by then. The worker stops between jobs at the deadline, so nothing runs on after main gave up.
    nonisolated func measureWithin(_ budget: TimeInterval, jobs: [PremeasureJob], env: TextBuildEnvironment,
                                   epoch: TranscriptPremeasureEpoch) -> [PremeasuredRow]
    {
        struct Box { var rows: [PremeasuredRow] = []; var expired = false }
        let box = Mutex(Box())
        let done = DispatchSemaphore(value: 0)
        self.queue.async {
            for job in jobs {
                if box.withLock({ $0.expired }) { break }
                let row = epoch.current == job.epoch ? self.measure(job, env: env, epoch: epoch)
                    : PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth, discarded: true)
                box.withLock { if !$0.expired { $0.rows.append(row) } }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + budget)
        return box.withLock { $0.expired = true; return $0.rows }
    }

    /// The same builder and measurer main uses, so the sizes are what main would compute.
    private func measure(_ job: PremeasureJob, env: TextBuildEnvironment, epoch: TranscriptPremeasureEpoch) -> PremeasuredRow {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        var row = PremeasuredRow(rowId: job.rowId, epoch: job.epoch, contentWidth: job.contentWidth)
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

    let epoch = TranscriptPremeasureEpoch()
    private(set) var inFlight: Set<String> = []
    private var rejected: Set<PremeasureKey> = []
    /// Rows already adopted since the last cancel. One that is still cold is laid out on main rather
    /// than sent again, so a result that can't warm a row never loops.
    private var adoptedRows: Set<String> = []
    var stats = PremeasureStats()
    /// The list's width now, so results made for an older one are dropped.
    var currentWidth: () -> CGFloat = { 0 }
    #if DEBUG
    /// Row ids sent to the worker (bounded), for tests.
    private(set) var offloadedIds: Set<String> = []
    #endif

    /// What to do with cold rows when the worker already holds `maxInFlight`.
    enum Overflow {
        /// Leave them queued for the worker's next round (idle prefetch).
        case wait
        /// Lay them out on main like before (scroll margin, which is held to its own budget).
        case measureNow
    }

    var inFlightCount: Int { self.inFlight.count }

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
            guard !self.inFlight.contains(row.id) else { continue }
            guard let keys = renderer.premeasureBodies(for: row), !keys.contains(where: self.rejected.contains) else {
                now.append(index)
                continue
            }
            if renderer.hasLayout(for: row, width: width) || keys.allSatisfy({ TranscriptText.isWarm($0.textKey, contentWidth: contentWidth) }) {
                self.stats.warmHits += 1
                now.append(index)
                continue
            }
            if self.adoptedRows.contains(row.id) {
                now.append(index)
                continue
            }
            guard self.inFlight.count + jobs.count < Self.maxInFlight else {
                if overflow == .measureNow { now.append(index) }
                continue
            }
            jobs.append(PremeasureJob(rowId: row.id, bodies: keys, contentWidth: contentWidth, epoch: self.epoch.current))
        }
        return (now, jobs)
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
        let rows = TranscriptPremeasurer.shared.measureWithin(budget, jobs: jobs, env: renderer.textEnvironment, epoch: self.epoch)
        self.stats.offloaded += rows.count
        return self.adopt(rows, width: width, epoch: epoch).count
    }

    /// Sends `jobs` to the worker; `completion` runs on main after their results are adopted.
    func submit(_ jobs: [PremeasureJob], width: CGFloat, env: TextBuildEnvironment, completion: @escaping @MainActor () -> Void) {
        guard !jobs.isEmpty else { return }
        let epoch = self.epoch.current
        for job in jobs { self.inFlight.insert(job.rowId) }
        self.stats.offloaded += jobs.count
        #if DEBUG
        if self.offloadedIds.count > 10_000 { self.offloadedIds.removeAll() }
        self.offloadedIds.formUnion(jobs.map(\.rowId))
        #endif
        for start in stride(from: 0, to: jobs.count, by: Self.rowsPerJob) {
            let chunk = Array(jobs[start..<min(start + Self.rowsPerJob, jobs.count)])
            TranscriptPremeasurer.shared.submit(chunk, env: env, epoch: self.epoch) { [weak self] rows in
                guard let self else { return }
                let now = self.currentWidth()
                self.adopt(rows, width: now > 0 ? now : width, epoch: epoch)
                completion()
            }
        }
    }

    /// Takes worker results into the text caches. `width` is the list's width now; results made for
    /// another width, epoch or style are dropped. Returns the rows that are now warm.
    @discardableResult
    func adopt(_ results: [PremeasuredRow], width: CGFloat, epoch: Int) -> Set<String> {
        let current = epoch == self.epoch.current
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        var warm: Set<String> = []
        for result in results {
            if current { self.inFlight.remove(result.rowId) }
            guard current, !result.discarded, result.epoch == epoch, result.contentWidth == contentWidth else {
                self.stats.discardedStale += 1
                continue
            }
            self.adoptedRows.insert(result.rowId)
            if self.rejected.count > 256 { self.rejected.removeAll() }
            self.rejected.formUnion(result.rejected)
            var adopted = true
            for body in result.bodies where !TranscriptText.adopt(body) { adopted = false }
            if adopted {
                self.stats.adopted += 1
                warm.insert(result.rowId)
            } else {
                self.stats.discardedStale += 1
            }
        }
        return warm
    }

    /// Drops everything in flight: the width, style or rows it was made for are gone.
    func cancelAll() {
        self.epoch.bump()
        self.inFlight.removeAll()
        self.adoptedRows.removeAll()
        self.rejected.removeAll()
    }
}
