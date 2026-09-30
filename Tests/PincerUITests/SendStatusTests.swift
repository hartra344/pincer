import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#endif

/// #482 / #212: what an unsent row says and offers while held, queued, sending or failed.
@MainActor
@Suite("Send status")
struct SendStatusTests {
    let size = 4_404_019
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(self.size), countStyle: .file) }

    func item(_ state: OutboxState, hold: OutboxHold? = nil) -> ChatItem {
        var item = ChatItem(role: .user, blocks: [.text("clip")], idempotencyKey: "k1", isPending: true)
        item.outboxState = state
        item.outboxHold = hold
        item.outboxUploadBytes = hold == nil ? nil : self.size
        return item
    }

    func status(_ state: OutboxState, hold: OutboxHold? = nil) throws -> TranscriptPart.SendStatus {
        try #require(TranscriptLayoutBuilder.sendStatus(self.item(state, hold: hold)))
    }

    @Test func heldExpensiveOffersSendNowThenDelete() throws {
        let status = try self.status(.queued, hold: .expensive)
        #expect(status.kind == .held && status.canSendNow && status.canDelete && !status.canRetry && !status.isFailed)
        #if os(macOS)
        #expect(status.text == "Waiting — Personal Hotspot")
        #else
        #expect(status.text == "Waiting for Wi‑Fi")
        #endif
        #expect(status.detail?.contains(self.sizeText) == true && status.detail?.contains("Send Now") == true, "\(status.detail ?? "")")
        #expect(status.spoken.contains(self.sizeText) && status.spoken.hasPrefix("Not sent yet."), Comment(rawValue: status.spoken))
    }

    @Test func constrainedReadsLowDataModeOnEveryPlatform() throws {
        let status = try self.status(.queued, hold: .constrained)
        #expect(status.kind == .held && status.canSendNow && status.canDelete)
        #expect(status.text == "Waiting — Low Data Mode")
        #expect(status.detail?.contains("Low Data Mode") == true && status.detail?.contains(self.sizeText) == true)
        #expect(status.spoken.contains("Low Data Mode") && status.spoken.contains(self.sizeText), Comment(rawValue: status.spoken))
    }

    @Test func plainQueuedHasNoSendNow() throws {
        let status = try self.status(.queued)
        #expect(status.kind == .queued && !status.canSendNow && status.canDelete && status.text == "Queued")
    }

    @Test func sendingShowsNoDelete() throws {
        let status = try self.status(.sending)
        #expect(status.kind == .sending && !status.canDelete && !status.canSendNow && !status.canRetry)
        #expect(status.text == "Sending…")
    }

    @Test func failedKeepsRetryAndDelete() throws {
        let retryable = try self.status(.failed(OutboxFailure(message: "Couldn’t send: timed out.", retryable: true)))
        #expect(retryable.kind == .failed && retryable.canRetry && retryable.canDelete && !retryable.canSendNow)
        let rejected = try self.status(.failed(OutboxFailure(message: "Couldn’t send: a.png is larger than this Gateway accepts (5 MB).", retryable: false)))
        #expect(rejected.kind == .failed && !rejected.canRetry && rejected.canDelete)
    }

    @Test func acceptedOrCommittedRowsHaveNoStatus() {
        var committed = self.item(.queued)
        committed.isPending = false
        #expect(TranscriptLayoutBuilder.sendStatus(committed) == nil)
    }

    #if os(macOS)
    /// Renders the held and sending rows to PNGs when PINCER_SEND_STATUS_PNG names a folder (not run in CI).
    @Test func rendersHeldAndSendingRowsWhenAsked() throws {
        guard let folder = ProcessInfo.processInfo.environment["PINCER_SEND_STATUS_PNG"] else { return }
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let renderer = TranscriptRenderer(context: context)
        let cases: [(String, TranscriptPart.SendStatus)] = [
            ("held-hotspot", try self.status(.queued, hold: .expensive)),
            ("held-low-data", try self.status(.queued, hold: .constrained)),
            ("sending", try self.status(.sending)),
        ]
        for (name, status) in cases {
            let view = TranscriptSendStatusView(frame: CGRect(x: 0, y: 0, width: 460, height: 22))
            view.configure(.sendStatus(status), row: TranscriptRowLayout(id: "r", width: 460), actions: renderer)
            view.layoutSubtreeIfNeeded()
            view.layoutContent()
            let backdrop = NSView(frame: view.frame)
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            backdrop.addSubview(view)
            let rep = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appending(path: "send-status-\(name).png"))
        }
    }
    #endif
}
