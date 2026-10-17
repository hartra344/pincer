import Foundation
@testable import PincerKit
@testable import PincerUI

/// Rows 100 points tall in a 300-point viewport, enough for the controller's prefetch to run.
@MainActor
private final class MeasureWorkHost: TranscriptListHost {
    var rowCount: () -> Int = { 0 }
    var offset: CGFloat = 0
    var height: CGFloat = 300
    var layoutWidth: CGFloat = 400
    var isLayoutFrozen = false
    var isScrolling = false

    var viewport: TranscriptViewport? {
        TranscriptViewport(offset: self.offset, height: self.height,
                           range: 0...max(0, CGFloat(self.rowCount()) * 100 - self.height))
    }

    func rowTop(_ row: Int) -> CGFloat? { row < self.rowCount() ? CGFloat(row) * 100 : nil }
    func row(atContentY y: CGFloat) -> Int? {
        let count = self.rowCount()
        return count == 0 ? nil : min(max(Int(y / 100), 0), count - 1)
    }

    var visibleRows: ClosedRange<Int>? {
        guard let first = self.row(atContentY: self.offset), let last = self.row(atContentY: self.offset + self.height) else { return nil }
        return first...last
    }

    func rowWindow(screens: CGFloat, minimum: CGFloat) -> (range: ClosedRange<Int>, center: Int)? {
        let pad = max(self.height * screens, minimum)
        guard let first = self.row(atContentY: self.offset - pad), let last = self.row(atContentY: self.offset + self.height + pad),
              let center = self.row(atContentY: self.offset + self.height / 2) else { return nil }
        return (first...last, center)
    }

    func heightsChanged(_ rows: IndexSet) {}
    func settle(changed: IndexSet) {}
    func reveal(_ id: String) {}
}

/// #1022: the transcript reports measuring work it still has queued, so callers (the panel-slide
/// probes) can wait for the work itself rather than for a quiet period a loaded runner can't promise.
@MainActor
func runTranscriptMeasureWorkChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let key = "agent:list:main"
    let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                    agent: AgentSummary(id: "check", name: "Check"), sessionKey: key,
                                    previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
    let controller = TranscriptListController(context: context, prefetchBudget: 0.006,
                                              premeasureAdmission: TranscriptPremeasureAdmission())
    let host = MeasureWorkHost()
    host.rowCount = { [unowned controller] in controller.rows.count }
    controller.host = host
    let rows: [TranscriptRow] = (0..<60).map { n in
        var item = ChatItem(id: "u\(n)", role: .user, blocks: [.text("Hello \(n)")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        item.transcriptId = item.id
        return .entry(.user(item))
    }
    _ = controller.accept(rows, contextChanged: false)
    check(!controller.hasPendingMeasureWork, "no measuring work before a prefetch is scheduled")
    controller.schedulePrefetch()
    check(controller.hasPendingMeasureWork, "a scheduled prefetch step counts as pending measuring work")
    let drained = await waitFor("transcript prefetch drains", timeout: 60) { !controller.hasPendingMeasureWork }
    let window = host.rowWindow(screens: CGFloat(TranscriptMeasureQueue.screensAhead), minimum: 200)
    let unmeasured = window.map { rows[$0.range].filter { controller.heights[$0.id]?.measured != true }.count }
    check(drained && unmeasured == 0, "the prefetch drains with every row in its window measured")
}
