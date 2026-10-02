import CoreGraphics
import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #55/#283: the platform-free transcript list logic shared by the AppKit and UIKit lists.
@MainActor
@Suite("Transcript list controller")
struct TranscriptListControllerTests {
    @MainActor
    private final class OlderPageGate {
        private var didStart = false
        private var started: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Bool, Never>?

        func load() async -> Bool {
            self.didStart = true
            self.started?.resume()
            self.started = nil
            return await withCheckedContinuation { self.completion = $0 }
        }

        func waitUntilStarted() async {
            guard !self.didStart else { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func complete(_ result: Bool) {
            guard let completion = self.completion else { return }
            self.completion = nil
            completion.resume(returning: result)
        }
    }

    /// Rows 100 points tall with no spacing, in a 300-point viewport.
    final class FakeHost: TranscriptListHost {
        var rowCount: () -> Int = { 0 }
        var offset: CGFloat = 0
        var height: CGFloat = 300
        var layoutWidth: CGFloat = 400
        var isLayoutFrozen = false
        var isScrolling = false
        var settles: [IndexSet] = []
        var changedHeights: [IndexSet] = []
        var revealed: [String] = []

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

        func heightsChanged(_ rows: IndexSet) { self.changedHeights.append(rows) }
        func settle(changed: IndexSet) { self.settles.append(changed) }
        func reveal(_ id: String) { self.revealed.append(id) }
    }

    static func user(_ n: Int, text: String = "Hello", pending: Bool = false) -> TranscriptRow {
        var item = ChatItem(id: "u\(n)", role: .user, blocks: [.text("\(text) \(n)")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)), isPending: pending)
        item.transcriptId = item.id
        return .entry(.user(item))
    }

    static func rows(_ range: Range<Int>) -> [TranscriptRow] { range.map { self.user($0) } }

    func make(_ scratch: ScratchDefaults) -> (TranscriptListController, FakeHost, TranscriptContext) {
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:list:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let controller = TranscriptListController(context: context, prefetchBudget: 0.006)
        let host = FakeHost()
        host.rowCount = { [unowned controller] in controller.rows.count }
        controller.host = host
        return (controller, host, context)
    }

    // MARK: Pure helpers

    @Test func rowDiffUsesFastPathsForPrependAndTrim() {
        let old = ["a", "b", "c"]
        let prepend = TranscriptListController.rowDiff(old: old, new: ["x", "y", "a", "b", "c"])
        #expect(prepend.removals.isEmpty)
        #expect(prepend.insertions == IndexSet(integersIn: 0..<2))
        let trim = TranscriptListController.rowDiff(old: old, new: ["c"])
        #expect(trim.removals == IndexSet(integersIn: 0..<2))
        #expect(trim.insertions.isEmpty)
        let mixed = TranscriptListController.rowDiff(old: old, new: ["a", "c", "d"])
        #expect(mixed.removals == IndexSet(integer: 1))
        #expect(mixed.insertions == IndexSet(integer: 2))
    }

    @Test func duplicateIdsKeepTheFirst() {
        let rows = [Self.user(1, text: "first"), Self.user(2), Self.user(1, text: "second")]
        let unique = TranscriptListController.uniqued(rows)
        #expect(unique.map(\.id) == ["u-u1", "u-u2"])
        #expect(unique[0] == rows[0])
    }

    @Test func heightMovesOnlyPastHalfAPoint() {
        #expect(TranscriptListController.heightMoved(from: nil, to: 10))
        #expect(!TranscriptListController.heightMoved(from: 10, to: 10.4))
        #expect(TranscriptListController.heightMoved(from: 10, to: 10.6))
        #expect(TranscriptListController.isMovingUp(from: 100, to: 99))
        #expect(!TranscriptListController.isMovingUp(from: 100, to: 99.6))
    }

    @Test func restoreTargetClampsToTheScrollRange() {
        let range: ClosedRange<CGFloat> = -12...1000
        #expect(TranscriptListController.restoreTarget(for: .bottom, range: range, rowTop: nil) == 1000)
        #expect(TranscriptListController.restoreTarget(for: .top, range: range, rowTop: nil) == -12)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 50), range: range, rowTop: 400) == 350)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 50), range: range, rowTop: 20) == -12)
        #expect(TranscriptListController.restoreTarget(for: .row("a", -50), range: range, rowTop: 990) == 1000)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 0), range: range, rowTop: nil) == nil)
    }

    @Test func revealPutsTheMatchAboveTheMiddle() {
        let anchor = TranscriptListController.revealAnchor(id: "a", insetTop: 20, visibleHeight: 500, matchY: 30, rowHeight: 200)
        #expect(anchor == .row("a", 20 + 200 - 30))
        // A match below the row (stale layout) is clamped to the row's height.
        let clamped = TranscriptListController.revealAnchor(id: "a", insetTop: 0, visibleHeight: 100, matchY: 500, rowHeight: 80)
        #expect(clamped == .row("a", 40 - 80))
    }

    @Test func anchorFollowsBottomTopOrTheMiddleRow() {
        let rows = Self.rows(0..<20)
        let rowAt: (CGFloat) -> Int? = { min(max(Int($0 / 100), 0), 19) }
        let rowTop: (Int) -> CGFloat? = { CGFloat($0) * 100 }
        func anchor(_ offset: CGFloat, rows: [TranscriptRow] = rows, stick: CGFloat = 80, allowTop: Bool = true) -> TranscriptAnchor {
            TranscriptListController.anchor(in: TranscriptViewport(offset: offset, height: 300, range: 0...1700),
                                            rows: rows, stickDistance: stick, allowTop: allowTop, rowAt: rowAt, rowTop: rowTop)
        }
        #expect(anchor(1650) == .bottom)
        #expect(anchor(1650, stick: 1) == .row("u-u18", 1800 - 1650))
        #expect(anchor(0) == .top)
        #expect(anchor(0, allowTop: false) == .row("u-u1", 100))
        #expect(anchor(420) == .row("u-u5", 500 - 420))
        // The loading row is never the anchor, nor .top.
        let loading = [TranscriptRow.loadingOlder] + rows.dropLast()
        #expect(anchor(0, rows: loading) == .row("u-u0", 100))
    }

    // MARK: Controller

    @Test func acceptClassifiesStreamingInitialAndChangedRows() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        var rows = Self.rows(0..<5)
        #expect(controller.accept(rows, contextChanged: false) == .initial)
        #expect(controller.anchor == .bottom)
        #expect(controller.accept(rows, contextChanged: false) == .unchanged)

        rows[4] = Self.user(4, text: "Edited")
        #expect(controller.accept(rows, contextChanged: false) == .tail(4))
        #expect(controller.rows[4] == rows[4])

        rows[1] = Self.user(1, text: "Changed")
        #expect(controller.accept(rows, contextChanged: false) == .rows(changed: IndexSet(integer: 1), oldIds: nil))

        let old = rows.map(\.id)
        rows.append(Self.user(5))
        #expect(controller.accept(rows, contextChanged: false) == .rows(changed: IndexSet(), oldIds: old))
        #expect(controller.index["u-u5"] == 5)
    }

    @Test func rebuiltEqualToolRowsDoNotInvalidateTheTranscript() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        func tool() -> ToolActivity {
            ToolActivity(id: "cache-tool", name: "exec", arguments: #"{"command":"echo"}"#,
                         result: "alpha", isError: false, isRunning: false)
        }
        func row(_ tool: ToolActivity) -> TranscriptRow {
            var turn = AssistantTurn(id: "cache-turn", timestamp: Date(timeIntervalSince1970: 1))
            turn.tools = [tool]
            return .entry(.assistant(turn))
        }
        let original = tool()
        var rebuilt = tool()
        #expect(original.presentationCacheRevision != rebuilt.presentationCacheRevision)
        #expect(row(original) == row(rebuilt))
        #expect(controller.accept([row(original)], contextChanged: false) == .initial)
        #expect(controller.accept([row(rebuilt)], contextChanged: false) == .unchanged)

        let oldIds = controller.rows.map(\.id)
        #expect(controller.accept([row(rebuilt), Self.user(1)], contextChanged: false)
                == .rows(changed: IndexSet(), oldIds: oldIds))
        rebuilt.result = "bravo"
        #expect(controller.accept([row(rebuilt), Self.user(1)], contextChanged: false)
                == .rows(changed: IndexSet(integer: 0), oldIds: nil))
    }

    @Test func pendingSendJumpsToTheBottom() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        var rows = Self.rows(0..<10)
        _ = controller.accept(rows, contextChanged: false)
        controller.anchor = .row("u-u3", 10)
        rows.append(Self.user(10))
        _ = controller.accept(rows, contextChanged: false)
        #expect(controller.anchor == .row("u-u3", 10), "a new reply doesn't move the reader")
        rows.append(Self.user(11, pending: true))
        _ = controller.accept(rows, contextChanged: false)
        #expect(controller.anchor == .bottom)
    }

    @Test func trimForgetsTheHeightsOfRowsThatLeft() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        let rows = Self.rows(0..<50)
        _ = controller.accept(rows, contextChanged: false)
        for row in rows.indices { _ = controller.height(at: row, width: 400) }
        #expect(controller.heights.count == 50)
        _ = controller.accept(Array(rows.suffix(10)), contextChanged: false)
        #expect(controller.heights.count == 10)
        #expect(controller.heights["u-u0"] == nil)
    }

    @Test func contextChangeStartsOver() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, context) = self.make(scratch)
        let rows = Self.rows(0..<5)
        _ = controller.accept(rows, contextChanged: false)
        _ = controller.height(at: 0, width: 400)
        #expect(controller.accept(rows, contextChanged: true) == .initial)
        #expect(controller.heights.isEmpty)
        #expect(!controller.beginUpdate(context: context, rowCount: 5))
    }

    @Test func measureSkipsCurrentRowsAndStopsAtTheDeadlineAfterOne() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        _ = controller.accept(Self.rows(0..<6), contextChanged: false)
        let first = controller.measure([0, 1], width: 400, deadline: nil)
        #expect(first.changed == IndexSet([0, 1]))
        #expect(controller.heights["u-u0"]?.isCurrent(at: 400) == true)
        #expect(controller.prefetchStats.rowsMeasured == 2)
        let again = controller.measure([0, 1], width: 400, deadline: nil)
        #expect(again.changed.isEmpty)
        #expect(controller.prefetchStats.rowsMeasured == 2, "rows current at this width aren't laid out again")
        let late = controller.measure([2, 3, 4], width: 400, deadline: .distantPast)
        #expect(late.stopped)
        #expect(controller.prefetchStats.rowsMeasured == 3, "at least one row is measured past the deadline")
    }

    @Test func invalidateMarksRowsAndSettles() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, _) = self.make(scratch)
        _ = controller.accept(Self.rows(0..<6), contextChanged: false)
        _ = controller.measure(Array(0..<6), width: 400, deadline: nil)
        controller.invalidate(["u-u2", "gone"], keepInPlace: nil)
        #expect(host.settles == [IndexSet(integer: 2)])
        #expect(controller.heights["u-u2"]?.measured == false)
        #expect(controller.queue.contains(2))
        controller.invalidate(["gone"], keepInPlace: nil)
        #expect(host.settles.count == 1, "nothing to settle when no row changed")
        controller.invalidate(nil, keepInPlace: nil)
        #expect(host.settles.last == IndexSet(integersIn: 0..<6))
    }

    /// The anchor report is queued with `DispatchQueue.main.async`; anything queued after it runs later.
    private static func mainQueueHop() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func bottomAnchorChangesAreReportedOnALaterTurn() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        var reports: [Bool] = []
        let bottom = TranscriptBottomState()
        bottom.onAnchorChange = { reports.append($0) }
        controller.attach(bottom) {}
        controller.anchor = .row("u-u1", 0)
        controller.anchor = .row("u-u2", 0)
        #expect(reports.isEmpty)
        await Self.mainQueueHop()
        #expect(reports == [false])
        controller.anchor = .bottom
        await Self.mainQueueHop()
        #expect(reports == [false, true])
        #expect(controller.isAnchoredAtBottom)
        #expect(bottom.isAnchoredAtBottom)
    }

    @Test func restoreTargetReanchorsWhenTheRowIsGone() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, _) = self.make(scratch)
        _ = controller.accept(Self.rows(0..<20), contextChanged: false)
        host.offset = 400
        #expect(controller.restoreTarget(.row("u-u10", 100)) == 900)
        controller.anchor = .row("missing", 0)
        #expect(controller.restoreTarget(controller.anchor) == nil)
        #expect(controller.anchor == .row("u-u5", 100))
    }

    @Test func pendingRevealWaitsForItsRow() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, _) = self.make(scratch)
        _ = controller.accept(Self.rows(0..<5), contextChanged: false)
        controller.renderer.onReveal?("u-u7")
        #expect(host.revealed.isEmpty)
        controller.revealPending()
        #expect(host.revealed.isEmpty)
        _ = controller.accept(Self.rows(0..<8), contextChanged: false)
        controller.revealPending()
        #expect(host.revealed == ["u-u7"])
        let prepared = controller.prepareReveal("u-u7")
        #expect(prepared?.row == 7)
        #expect(controller.heights["u-u7"]?.isCurrent(at: 400) == true)
    }

    /// One list update as the views run it: raw input through `beginUpdate` and `accept`, then the older-row check.
    func update(_ controller: TranscriptListController, _ context: TranscriptContext, _ rows: [TranscriptRow]) {
        let changed = controller.beginUpdate(context: context, rowCount: rows.count)
        _ = controller.accept(rows, contextChanged: changed)
        controller.loadOlderIfShown()
    }

    @Test func reconnectDuringBoundedFailuresResumesPagingWhileTheOlderRowStaysVisible() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, context) = self.make(scratch)
        let chat = context.chat!
        chat.hasMoreHistory = true
        controller.gatewayConnectionChanged(isConnected: false)
        _ = controller.accept([.loadingOlder] + Self.rows(0..<3), contextChanged: false)
        host.offset = 0
        let firstPage = OlderPageGate()
        var pageLoads = 0
        controller.renderer.olderPageLoader = { _ in
            pageLoads += 1
            if pageLoads == 1 { return await firstPage.load() }
            guard pageLoads < 4 else {
                chat.hasMoreHistory = false
                chat.olderInCache = false
                return true
            }
            return false
        }
        controller.loadOlderIfShown()
        await firstPage.waitUntilStarted()
        controller.gatewayConnectionChanged(isConnected: true)
        firstPage.complete(false)
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == 4, "reconnect during the bounded retry pass launches one follow-up page")
    }

    @Test func reconnectPendingOnOldChatDoesNotStartPagingAfterSwitch() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, context) = self.make(scratch)
        let oldChat = context.chat!
        oldChat.hasMoreHistory = true
        controller.gatewayConnectionChanged(isConnected: false)
        _ = controller.accept([.loadingOlder] + Self.rows(0..<3), contextChanged: false)
        host.offset = 0
        let firstPage = OlderPageGate()
        var pageLoads: [String] = []
        controller.renderer.olderPageLoader = { chat in
            pageLoads.append(chat.sessionKey)
            if chat === oldChat { return await firstPage.load() }
            chat.hasMoreHistory = false
            chat.olderInCache = false
            return true
        }
        controller.loadOlderIfShown()
        await firstPage.waitUntilStarted()
        controller.gatewayConnectionChanged(isConnected: true)

        let newKey = "agent:list:other"
        let newChat = context.gateway.chat(for: newKey)
        newChat.hasMoreHistory = true
        let newContext = TranscriptContext(gateway: context.gateway, disclosure: TranscriptDisclosure(),
                                           agent: context.agent, sessionKey: newKey,
                                           previewImage: { _ in }, saveFile: { _, _ in }, chat: newChat)
        let contextChanged = controller.beginUpdate(context: newContext, rowCount: 3)
        _ = controller.accept([.loadingOlder] + Self.rows(10..<13), contextChanged: contextChanged)
        host.offset = 0
        controller.loadOlderIfShown()

        oldChat.hasMoreHistory = false
        firstPage.complete(false)
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == [oldChat.sessionKey, newKey],
                "the old pass yields to the new visible chat instead of replaying its old page")
        #expect(controller.context.chat === newChat)
    }

    @Test func reconnectAfterExhaustedPagingResumesWhileTheOlderRowStaysVisible() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, context) = self.make(scratch)
        let chat = context.chat!
        chat.hasMoreHistory = true
        controller.gatewayConnectionChanged(isConnected: false)
        _ = controller.accept([.loadingOlder] + Self.rows(0..<3), contextChanged: false)
        host.offset = 0
        var pageLoads = 0
        controller.renderer.olderPageLoader = { _ in
            pageLoads += 1
            return false
        }
        controller.gatewayConnectionChanged(isConnected: true)
        controller.loadOlderIfShown()
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == 3, "paging reaches the existing bounded failure limit")

        controller.gatewayConnectionChanged(isConnected: false)
        controller.renderer.olderPageLoader = { _ in
            pageLoads += 1
            chat.hasMoreHistory = false
            chat.olderInCache = false
            return true
        }
        controller.gatewayConnectionChanged(isConnected: true)
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == 4, "a later reconnect resumes without scrolling away and back")
    }

    /// #467: a duplicated row id made the raw count differ from the list's on every update, re-arming the trigger.
    @Test func duplicateIdsDoNotReArmTheOlderRowTrigger() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host, context) = self.make(scratch)
        let chat = context.chat!
        let rows: [TranscriptRow] = [.loadingOlder] + Self.rows(0..<3) + [Self.user(2)]
        let gate = OlderPageGate()
        var pageLoads = 0
        controller.renderer.olderPageLoader = { _ in
            pageLoads += 1
            if pageLoads == 1 { return await gate.load() }
            return false
        }
        chat.hasMoreHistory = true
        self.update(controller, context, rows)
        await gate.waitUntilStarted()

        // Keep the retry loop in flight while identical raw input, including the duplicate, is
        // accepted repeatedly. Ordinary updates must not queue a second failure budget.
        for _ in 0..<3 {
            self.update(controller, context, rows)
            controller.renderer.loadOlderIfShown { true }
        }
        #expect(pageLoads == 1, "updates while a page is pending must not start another page")

        gate.complete(false)
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == 3, "same-chat updates don't restart the bounded failure loop")
        chat.hasMoreHistory = false
        #expect(!chat.hasOlderItems)

        // A still-visible loading row can page again if more history is genuinely available.
        // Duplicate ids must not make the unchanged row look newly visible after completion.
        chat.olderInCache = true
        for _ in 0..<3 { self.update(controller, context, rows) }
        await controller.renderer.waitForOlderLoop()
        #expect(pageLoads == 3, "repeated duplicate ids don't re-arm the older-row trigger")
        #expect(chat.olderInCache, "no redundant page should consume the cached older flag")
        withExtendedLifetime(host) {}
    }

    /// #468: the closure handed to a later `attach` for the same state replaces the earlier one.
    @Test func attachingTheSameStateAdoptsANewScrollToBottom() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = self.make(scratch)
        let bottom = TranscriptBottomState()
        var calls: [String] = []
        controller.attach(bottom) { calls.append("old") }
        controller.attach(bottom) { calls.append("new") }
        bottom.perform?()
        #expect(calls == ["new"])
        controller.attach(nil) { calls.append("detached") }
        #expect(controller.bottom == nil)
    }
}
