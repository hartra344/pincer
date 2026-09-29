import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit

/// #420: the scroll-to-bottom button above the composer. Exercises the real AppKit transcript
/// list end to end: `ScrollToBottomModel.report` publishing asynchronously, `scrollToBottom()`'s
/// jump-then-animate landing, and that stick-to-bottom anchoring still works afterwards.
///
/// Run: `swift test --filter ScrollToBottom`
@MainActor
@Suite("ScrollToBottomTests", .serialized)
struct ScrollToBottomTests {
    /// Tearing the table down mid-test crashes AppKit; the probe leaks its windows instead.
    static var keepAlive: [(NSWindow, TranscriptList.Coordinator)] = []

    /// Spins the run loop in short slices so DispatchQueue.main.async work (the model's publish)
    /// and NSAnimationContext callbacks land, for at least `seconds`.
    static func spin(_ seconds: Double) async {
        let start = ProbeMeter.wall()
        while ProbeMeter.wall() - start < seconds {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static func makeHost(rows: [TranscriptRow]) async -> (host: PanelSlideProbe.Host, context: TranscriptContext) {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:probe:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let coordinator = TranscriptList.Coordinator(context: context)
        let scroll = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.orderBack(nil)
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 0.5)
        coordinator.update(rows: rows, context: context, insets: (0, 0))
        _ = await TranscriptPrefetchProbe.spinUntilIdle(cap: 20)
        Self.keepAlive.append((window, coordinator))
        let host = PanelSlideProbe.Host(coordinator: coordinator, scroll: scroll, window: window,
                                        table: scroll.documentView as! NSTableView)
        return (host, context)
    }

    /// The maximum scroll offset: the clip is at the bottom when its bounds.minY equals this.
    static func bottomOffset(_ host: PanelSlideProbe.Host) -> CGFloat {
        let last = host.table.numberOfRows - 1
        let contentHeight = host.table.rect(ofRow: last).maxY
        return contentHeight + host.scroll.contentInsets.bottom - host.clip.bounds.height
    }

    static func scroll(_ host: PanelSlideProbe.Host, to y: CGFloat) {
        host.clip.scroll(to: NSPoint(x: 0, y: y))
        host.scroll.reflectScrolledClipView(host.clip)
    }

    static func newUserRow(id: String) -> TranscriptRow {
        var item = ChatItem(id: id, role: .user, blocks: [.text("New message \(id)")], timestamp: Date())
        item.transcriptId = item.id
        return .entry(.user(item))
    }

    @Test func buttonVisibilityAndScrollToBottom() async {
        let rows = TranscriptPrefetchProbe.rows(count: 400)
        let (host, context) = await Self.makeHost(rows: rows)
        let model = ScrollToBottomModel()
        host.coordinator.attach(model)
        // Force a fresh report now that the model is attached.
        host.coordinator.update(rows: rows, context: context, insets: (0, 0))
        await Self.spin(0.3)
        #expect(model.isVisible == false, "starts at the bottom; the button stays hidden")

        // Scroll far up: well past both the stick distance and half the viewport.
        Self.scroll(host, to: host.table.rect(ofRow: 20).minY)
        await Self.spin(0.3)
        #expect(model.isVisible == true, "far from the end; the button shows")

        model.scrollToBottom()
        await Self.spin(1.5)
        let bottom = Self.bottomOffset(host)
        #expect(abs(host.clip.bounds.minY - bottom) <= 1, "scrollToBottom() lands exactly at the end")
        #expect(model.isVisible == false, "back at the bottom; the button hides")

        // Appending while stuck at the bottom keeps the reader stuck at the (new) bottom.
        host.coordinator.update(rows: rows + [Self.newUserRow(id: "new-\(rows.count)")], context: context, insets: (0, 0))
        await Self.spin(0.3)
        let bottomAfterAppend = Self.bottomOffset(host)
        #expect(abs(host.clip.bounds.minY - bottomAfterAppend) <= 1, "stayed stuck to the (new) bottom")
        #expect(model.isVisible == false, "still at the bottom; the button stays hidden")
    }

    @Test func newMessagesWhileScrolledUp() async {
        let rows = TranscriptPrefetchProbe.rows(count: 400)
        let (host, context) = await Self.makeHost(rows: rows)
        let model = ScrollToBottomModel()
        host.coordinator.attach(model)
        host.coordinator.update(rows: rows, context: context, insets: (0, 0))
        await Self.spin(0.3)

        Self.scroll(host, to: host.table.rect(ofRow: 20).minY)
        await Self.spin(0.3)
        #expect(model.isVisible == true)
        #expect(model.hasNewMessages == false, "no new message has arrived yet")

        host.coordinator.update(rows: rows + [Self.newUserRow(id: "new-\(rows.count)")], context: context, insets: (0, 0))
        await Self.spin(0.3)
        #expect(model.isVisible == true, "still far from the end after the append")
        #expect(model.hasNewMessages == true, "a new last row arrived while scrolled up")
    }
}
#endif
