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
