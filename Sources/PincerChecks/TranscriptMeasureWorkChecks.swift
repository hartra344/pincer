import Foundation
@testable import PincerKit
@testable import PincerUI

/// #1022: the transcript reports measuring work it still has queued, so callers (the panel-slide
/// probes) can wait for the work itself rather than for a quiet period a loaded runner can't promise.
@MainActor
func runTranscriptMeasureWorkChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let stub = makeStubTranscript(defaults: defaults, rowCount: 60)
    let (controller, host, rows) = (stub.controller, stub.host, stub.rows)
    _ = controller.accept(rows, contextChanged: false)
    check(!controller.hasPendingMeasureWork, "no measuring work before a prefetch is scheduled")
    controller.schedulePrefetch()
    check(controller.hasPendingMeasureWork, "a scheduled prefetch step counts as pending measuring work")
    let drained = await waitFor("transcript prefetch drains", timeout: 60) { !controller.hasPendingMeasureWork }
    let window = host.rowWindow(screens: CGFloat(TranscriptMeasureQueue.screensAhead), minimum: 200)
    let unmeasured = window.map { rows[$0.range].filter { controller.heights[$0.id]?.measured != true }.count }
    check(drained && unmeasured == 0, "the prefetch drains with every row in its window measured")
}

/// `TranscriptText.measureStats` is process-wide, so a test awaiting the premeasure worker saw another
/// suite's main-thread layout. A watched marker counts only the layouts of strings that contain it.
@MainActor
func runTranscriptMarkedLayoutChecks() {
    let marker = "markedlayout\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    TranscriptText.watchMainLayouts(containing: marker)
    defer { TranscriptText.stopWatchingMainLayouts(containing: marker) }
    let font = PFont.systemFont(ofSize: 13)
    let before = TranscriptText.measureStats.mainLayouts
    _ = TranscriptText.size(TranscriptText.plain("someone else's row", font: font, color: .black), width: 300)
    check(TranscriptText.measureStats.mainLayouts == before + 1 && TranscriptText.markedMainLayouts[marker] == 0,
          "an unmarked main layout counts process-wide but not against the watched marker")
    _ = TranscriptText.size(TranscriptText.plain("own row \(marker)", font: font, color: .black), width: 300)
    check(TranscriptText.markedMainLayouts[marker] == 1, "a main layout of the marked text counts against the marker")
    TranscriptText.stopWatchingMainLayouts(containing: marker)
    check(TranscriptText.markedMainLayouts[marker] == nil, "stopping the watch drops the marker")
}
