import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#endif

/// #335: the open chat is trimmed back to its window after Find closes, once the list follows the bottom.
@MainActor
@Suite("Transcript Find trim", .serialized)
struct TranscriptFindTrimTests {
    final class Recorder {
        var trims = 0
        var stillWanted: (@MainActor () -> Bool)?
    }

    func chat(_ scratch: ScratchDefaults) -> ChatStore {
        GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                     defaults: scratch.defaults, identity: UIFixtures.identity()).chat(for: "agent:trim:main")
    }

    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func trimsOnlyAfterFindClosesAndOnlyAtTheBottom() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let chat = self.chat(scratch)
        let recorder = Recorder()
        let trim = TranscriptFindTrim { _, stillWanted in
            recorder.trims += 1
            recorder.stillWanted = stillWanted
        }
        trim.findChanged(isPresented: true, chat: chat)
        await self.settle()
        #expect(recorder.trims == 0, "Find is open")

        // The reader was looking at a match: wait until they're back at the bottom.
        trim.bottomAnchorChanged(false, chat: chat)
        trim.findChanged(isPresented: false, chat: chat)
        await self.settle()
        #expect(recorder.trims == 0)
        #expect(trim.pending)

        trim.bottomAnchorChanged(true, chat: chat)
        await self.settle()
        #expect(recorder.trims == 1)
        #expect(!trim.pending)
        #expect(recorder.stillWanted?() == true)

        // Scrolling away or reopening Find while the save runs calls the trim off.
        trim.bottomAnchorChanged(false, chat: chat)
        #expect(recorder.stillWanted?() == false)
        trim.bottomAnchorChanged(true, chat: chat)
        trim.findChanged(isPresented: true, chat: chat)
        #expect(recorder.stillWanted?() == false)
        await self.settle()
        #expect(recorder.trims == 1, "no second trim without Find closing again")
    }

    @Test func closingFindAtTheBottomTrimsRightAway() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let chat = self.chat(scratch)
        let recorder = Recorder()
        let trim = TranscriptFindTrim { _, _ in recorder.trims += 1 }
        trim.findChanged(isPresented: true, chat: chat)
        trim.findChanged(isPresented: false, chat: chat)
        await self.settle()
        #expect(recorder.trims == 1)
    }

    #if os(macOS)
    /// Tearing the table down mid-test crashes AppKit; the test leaks its window instead.
    static var keepAlive: [(NSWindow, TranscriptList.Coordinator)] = []

    /// The list reports leaving and returning to the bottom, and a trim of thousands of rows above
    /// keeps it at the bottom (and doesn't fall back to diffing every row).
    @Test func listReportsTheBottomAnchorAndKeepsItThroughATrim() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:trim:main"
        let chat = gateway.chat(for: key)
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let rows = TranscriptPrefetchProbe.rows(count: 4_000)
        let coordinator = TranscriptList.Coordinator(context: context)
        var reports: [Bool] = []
        let bottom = TranscriptBottomState()
        bottom.onAnchorChange = { reports.append($0) }
        coordinator.attach(bottom)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.orderBack(nil)
        Self.keepAlive.append((window, coordinator))
        coordinator.update(rows: rows, context: context, insets: (0, 0))
        #expect(coordinator.isAnchoredAtBottom)

        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!coordinator.isAnchoredAtBottom)
        #expect(reports.last == false)

        let table = try #require(scroll.documentView as? NSTableView)
        clip.scroll(to: NSPoint(x: 0, y: table.frame.height))
        scroll.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.isAnchoredAtBottom)
        #expect(reports.last == true)

        let kept = Array(rows.suffix(600))
        let start = ContinuousClock.now
        coordinator.update(rows: kept, context: context, insets: (0, 0))
        print("TranscriptFindTrim: trimmed 4000 → 600 rows in \(ContinuousClock.now - start) (report-only)")
        #expect(table.numberOfRows == kept.count)
        #expect(coordinator.isAnchoredAtBottom)
        let maxY = table.frame.height + scroll.contentInsets.bottom - clip.bounds.height
        #expect(abs(clip.bounds.minY - maxY) <= 1, "still showing the newest rows")
    }
    #endif
}
