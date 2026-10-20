import CoreGraphics
import Foundation
@testable import PincerKit
@testable import PincerUI

/// Rows 100 points tall in a 300-point viewport. With `windowed` off it reports no visible window,
/// for checks that drive measuring explicitly.
@MainActor
final class StubTranscriptHost: TranscriptListHost {
    var rowCount: () -> Int = { 0 }
    var offset: CGFloat = 0
    var height: CGFloat = 300
    var layoutWidth: CGFloat = 400
    var isLayoutFrozen = false
    var isScrolling = false
    let windowed: Bool

    init(windowed: Bool = true) { self.windowed = windowed }

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
        guard self.windowed, let first = self.row(atContentY: self.offset),
              let last = self.row(atContentY: self.offset + self.height) else { return nil }
        return first...last
    }

    func rowWindow(screens: CGFloat, minimum: CGFloat) -> (range: ClosedRange<Int>, center: Int)? {
        guard self.windowed else { return nil }
        let pad = max(self.height * screens, minimum)
        guard let first = self.row(atContentY: self.offset - pad), let last = self.row(atContentY: self.offset + self.height + pad),
              let center = self.row(atContentY: self.offset + self.height / 2) else { return nil }
        return (first...last, center)
    }

    func heightsChanged(_ rows: IndexSet) {}
    func settle(changed: IndexSet) {}
    func reveal(_ id: String) {}
}

/// A transcript controller wired to a `StubTranscriptHost` and `count` plain user rows (not yet accepted).
@MainActor
struct StubTranscript {
    let controller: TranscriptListController
    let host: StubTranscriptHost
    let rows: [TranscriptRow]
}

@MainActor
func makeStubTranscript(defaults: UserDefaults, rowCount count: Int, windowed: Bool = true) -> StubTranscript {
    let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let key = "agent:list:main"
    let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                    agent: AgentSummary(id: "check", name: "Check"), sessionKey: key,
                                    previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
    let controller = TranscriptListController(context: context, prefetchBudget: 0.006,
                                              premeasureAdmission: TranscriptPremeasureAdmission())
    let host = StubTranscriptHost(windowed: windowed)
    host.rowCount = { [unowned controller] in controller.rows.count }
    controller.host = host
    let rows: [TranscriptRow] = (0..<count).map { n in
        var item = ChatItem(id: "u\(n)", role: .user, blocks: [.text("Hello \(n)")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        item.transcriptId = item.id
        return .entry(.user(item))
    }
    return StubTranscript(controller: controller, host: host, rows: rows)
}
