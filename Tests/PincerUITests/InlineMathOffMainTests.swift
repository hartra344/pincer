import CoreGraphics
import Foundation
import Synchronization
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
private final class InlineMathBatchCompletion {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func finish(_ completed: Bool) {
        guard self.result == nil else { return }
        self.result = completed
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: completed)
    }
    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if let result = self.result { waiter.resume(returning: result) }
                else if Task.isCancelled { self.finish(false); waiter.resume(returning: false) }
                else { self.waiter = waiter }
            }
        } onCancel: { Task { @MainActor in self.finish(false) } }
    }
}

@MainActor
@Suite("InlineMathOffMain", .serialized)
struct InlineMathOffMainTests {
    static let source = "Energy scales as $x^2 + \\frac{a}{b}$ and \\(y_i\\) in a sentence long enough to wrap a couple of times at narrow widths."

    private func workerRow(_ source: String, width: CGFloat, dark: Bool) async -> PremeasuredRow {
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: TranscriptStyle.generation, dark: dark)
        let job = PremeasureJob(rowId: "m", bodies: [key], contentWidth: width, epoch: 0)
        let env = TextBuildEnvironment.current(dark: dark)
        return await withCheckedContinuation { continuation in
            TranscriptPremeasurer.shared.submit([job], env: env, epoch: TranscriptPremeasureEpoch()) { continuation.resume(returning: $0[0]) }
        }
    }

    private static func assistant(_ id: String, text: String, at n: Int) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        return .entry(.assistant(turn))
    }

    private func attachments(_ segments: [TranscriptText.Segment]) -> [InlineMathAttachment] {
        var found: [InlineMathAttachment] = []
        for case let .text(string) in segments {
            string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
                if let attachment = value as? InlineMathAttachment { found.append(attachment) }
            }
        }
        return found
    }

    @Test func workerBuildsAndMeasuresMathOffMainWithoutACell() async {
        let layoutsBefore = TranscriptPremeasurer.offMainLayouts.withLock { $0 }
        let row = await workerRow(Self.source, width: 420, dark: false)
        let body = try! #require(row.bodies.first)
        #expect(row.rejected.isEmpty && !row.discarded)
        #expect(self.attachments(body.segments).count == 2)
        #expect(!body.heights.isEmpty)
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > layoutsBefore)
        // The attachments own their bounds: the measured line holds the formulas, and no cell was made.
        let formulas = self.attachments(body.segments)
        #if os(macOS)
        #expect(formulas.allSatisfy { $0.attachmentCell == nil })
        #endif
        let inkWidth = formulas.reduce(0) { $0 + $1.bounds.width }
        let main = TranscriptText.markdown(Self.source, tone: .primary, dark: false)
        if case let .text(string) = main[0] {
            let wide = TranscriptText.size(string, width: 10_000).width
            #expect(wide >= inkWidth && inkWidth > 0)
        }
    }

    @Test func attachmentsAreBuiltFromAnyThread() async {
        let font = PFont.systemFont(ofSize: 15)
        let color = PColor.black
        let id = await Task.detached {
            InlineMathText.attachment("x^2", font: PFont.systemFont(ofSize: 15), color: PColor.black, dark: false, scale: 2).map(ObjectIdentifier.init)
        }.value
        #expect(id != nil)
        // The main thread reuses the object the other thread drew.
        let again = InlineMathText.attachment("x^2", font: font, color: color, dark: false, scale: 2)
        #expect(again is InlineMathAttachment)
        #expect(again.map(ObjectIdentifier.init) == id)
        #expect(InlineMathText.attachment("x^2", font: font, color: color, dark: false, scale: 3).map(ObjectIdentifier.init) != id)
    }

    #if os(macOS)
    @Test func formulasStillDrawWithoutACell() throws {
        let main = TranscriptText.markdown("$x^2 + y$ " + UUID().uuidString, tone: .primary, dark: false)
        let formula = NSMutableAttributedString(string: "\u{FFFC}")
        let attachment = try #require(self.attachments(main).first)
        formula.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 1))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 60, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        formula.draw(with: NSRect(x: 0, y: 0, width: 100, height: 30), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { inked += 1 } }
        #expect(inked > 20, "the formula drew \(inked) inked pixels")
    }
    #endif

    @Test func workerSizesMatchMainSizesForMathRows() async {
        for width in [320, 480, 700] as [CGFloat] {
            let row = await workerRow(Self.source, width: width, dark: false)
            let body = try! #require(row.bodies.first)
            let main = TranscriptText.markdown(Self.source, tone: .primary, dark: false)
            #expect(body.segments.count == main.count)
            #expect(!body.heights.isEmpty)
            for height in body.heights {
                guard case let .text(text) = main[height.index] else { continue }
                let size = TranscriptText.size(text, width: height.width, exact: height.exact)
                #expect(size.height == height.height && size.width == height.usedWidth, "worker \(height.height) vs main \(size.height) at \(width)")
            }
        }
    }

    @Test func adoptedMathRowsAreWarm() async {
        let source = Self.source + " unique-" + UUID().uuidString
        let width: CGFloat = 640
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: TranscriptStyle.generation, dark: false)
        let row = await workerRow(source, width: contentWidth, dark: false)
        let driver = TranscriptPremeasureDriver()
        #expect(driver.adopt([row], width: width, epoch: driver.epoch.current) == ["m"])
        #expect(TranscriptText.isWarm(key.textKey, contentWidth: contentWidth))
    }

    /// The darkest and lightest opaque pixel of a drawn formula, which carry its ink color.
    private func ink(_ attachment: InlineMathAttachment) -> (r: Int, g: Int, b: Int)? {
        #if os(macOS)
        guard let image = attachment.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = attachment.image?.cgImage else { return nil }
        #endif
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best: (r: Int, g: Int, b: Int, a: Int)?
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 0 {
            if best == nil || Int(data[i + 3]) > best!.a {
                best = (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
            }
        }
        guard let best, best.a > 0 else { return nil }
        // Un-premultiply.
        return (best.r * 255 / best.a, best.g * 255 / best.a, best.b * 255 / best.a)
    }

    @Test func inlineMathColorsDifferBetweenLightAndDark() async throws {
        let source = "Colors $x^2 + y$ differ " + UUID().uuidString
        let light = await workerRow(source, width: 400, dark: false)
        let dark = await workerRow(source, width: 400, dark: true)
        let lightBody = try #require(light.bodies.first), darkBody = try #require(dark.bodies.first)
        let lightAttachment = try #require(self.attachments(lightBody.segments).first)
        let darkAttachment = try #require(self.attachments(darkBody.segments).first)
        #expect(lightAttachment !== darkAttachment)
        let lightInk = try #require(self.ink(lightAttachment)), darkInk = try #require(self.ink(darkAttachment))
        // Label text is dark on light and light on dark.
        #expect(lightInk.r < 128 && lightInk.g < 128 && lightInk.b < 128, "light ink \(lightInk)")
        #expect(darkInk.r > 128 && darkInk.g > 128 && darkInk.b > 128, "dark ink \(darkInk)")
        // The main-thread path agrees with the worker's.
        let main = TranscriptText.markdown(source, tone: .primary, dark: true)
        let mainAttachment = try #require(self.attachments(main).first)
        let mainInk = try #require(self.ink(mainAttachment))
        #expect(mainInk == darkInk)
    }

    @Test(.timeLimit(.minutes(2))) func prewarmWarmsTheWindowAtTheFinalWidth() async {
        let clock = ContinuousClock()
        let fixtureStarted = clock.now
        var phase = "cache-lease"
        let acquiredCacheLease = await TranscriptSharedCacheLease.shared.acquire()
        if !acquiredCacheLease {
            print("Inline prewarm phase=\(phase) elapsed=\(fixtureStarted.duration(to: clock.now)) cacheWaiters=\(TranscriptSharedCacheLease.shared.waitingCount)")
        }
        #expect(acquiredCacheLease, "the actual cache fixture must acquire its cancellable isolation lease")
        guard acquiredCacheLease else { return }
        defer { TranscriptSharedCacheLease.shared.release() }
        phase = "fixture"
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let body = String(repeating: "filler words that wrap ", count: 12)
        let salt = UUID().uuidString
        var rows: [TranscriptRow] = []
        for i in 0..<12 {
            let text = (i % 2 == 0 ? "Math $x_\(i)^2$ " : "Plain ") + body + salt
            rows.append(Self.assistant("pw\(i)-\(salt)", text: text, at: i))
        }
        let width: CGFloat = 612
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        let driver = TranscriptPremeasureDriver(admission: TranscriptPremeasureAdmission())
        #if DEBUG
        let workerPhases = Mutex([Int](repeating: 0, count: 4))
        driver.admission.observeWorkerPhase = { phase in
            workerPhases.withLock { if $0[phase] < 32 { $0[phase] += 1 } }
        }
        defer { driver.admission.observeWorkerPhase = nil }
        #endif
        defer { driver.cancelAll() }
        driver.currentRow = { id in rows.first { $0.id == id } }
        let cold = rows.compactMap { renderer.premeasureBodies(for: $0) }
        #expect(cold.count == rows.count)
        #expect(cold.allSatisfy { keys in !keys.allSatisfy { TranscriptText.isWarm($0.textKey, contentWidth: contentWidth) } })
        // A zero-budget pass is optional; actual asynchronous adoption must warm the whole window.
        // Isolate admission from other suites while retaining the real serialized measurement worker.
        phase = "prewarm"
        let warmed = driver.prewarm(Array(rows.indices), all: rows, width: width, renderer: renderer, budget: 0)
        #expect((0...rows.count).contains(warmed))
        phase = "split"
        let remaining = driver.split(Array(rows.indices), all: rows, width: width, renderer: renderer).offload
        if !remaining.isEmpty {
            let completed = InlineMathBatchCompletion()
            var callbacks = 0
            var firstCallback: Duration?
            var lastCallback: Duration?
            phase = "submit"
            driver.submit(remaining, width: width, env: renderer.textEnvironment) {
                callbacks += 1
                let elapsed = fixtureStarted.duration(to: clock.now)
                if firstCallback == nil { firstCallback = elapsed }
                lastCallback = elapsed
                phase = "callback"
                // A discarded/rejected terminal batch must also wake the test, then fail the
                // exact adoption assertion instead of hanging behind its success predicate.
                if driver.inFlightCount == 0 { completed.finish(true) }
            }
            phase = "await-batch"
            let finished = await completed.wait()
            if !finished || driver.stats.adopted != rows.count {
                print("Inline prewarm phase=\(phase) elapsed=\(fixtureStarted.duration(to: clock.now)) finished=\(finished) submitted=\(remaining.count) callbacks=\(callbacks) firstCallback=\(String(describing: firstCallback)) lastCallback=\(String(describing: lastCallback)) cacheWaiters=\(TranscriptSharedCacheLease.shared.waitingCount) inFlight=\(driver.inFlightCount) offloaded=\(driver.stats.offloaded) adopted=\(driver.stats.adopted) discarded=\(driver.stats.discardedStale) active=\(driver.admission.active) pending=\(driver.admission.pendingCount)")
            }
            #if DEBUG
            let phaseCounts = workerPhases.withLock { $0 }
            #expect(phaseCounts == Array(repeating: remaining.count, count: 4),
                    "each real submitted row must enter and exit the worker and reach its Main callback")
            #expect(finished, "actual batch completion; submitted=\(phaseCounts[0]) workerEntered=\(phaseCounts[1]) workerExited=\(phaseCounts[2]) mainCallbacks=\(phaseCounts[3]) inFlight=\(driver.inFlightCount) adopted=\(driver.stats.adopted) pending=\(driver.admission.pendingCount)")
            #else
            #expect(finished, "the real batch completion event must arrive before test cancellation")
            #endif
            #expect(driver.inFlightCount == 0 && driver.stats.adopted == rows.count,
                    "every actual row must finish adoption before checking the warmed window")
        }
        #expect(cold.allSatisfy { keys in keys.allSatisfy { TranscriptText.isWarm($0.textKey, contentWidth: contentWidth) } })
        // Global eviction tokens conservatively invalidate earlier row memos even when this
        // exact window remains warm. Render the finished window, as the real controller does,
        // and prove its already-adopted sizes avoid any additional Main TextKit measurement.
        let mainLayoutsBefore = TranscriptText.measureStats.mainLayouts
        for row in rows {
            let layout = renderer.layout(for: row, width: width)
            #expect(layout.height.isFinite && layout.height > 0)
            #expect(layout.width.isFinite && layout.width == width)
            #expect(renderer.hasLayout(for: row, width: width))
        }
        #expect(TranscriptText.measureStats.mainLayouts == mainLayoutsBefore)
        // The actual rendered-window cache then makes a second pass send nothing.
        #expect(driver.prewarm(Array(rows.indices), all: rows, width: width, renderer: renderer) == 0)
        // A zero budget returns at once, even with work left.
        let more = (0..<8).map { Self.assistant("pz\($0)-\(salt)", text: "Cold \($0) " + body + salt, at: $0) }
        let started = Date()
        _ = driver.prewarm(Array(more.indices), all: more, width: width, renderer: renderer, budget: 0)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
