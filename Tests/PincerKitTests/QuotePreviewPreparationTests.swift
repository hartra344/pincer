import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Quoted row preview preparation")
struct QuotePreviewPreparationTests {
    @MainActor
    private final class Fixture {
        let suite = "pincer.quote-preparation.\(UUID().uuidString)"
        let defaults: UserDefaults
        let gateway: GatewayStore
        let chat: ChatStore
        init(items: [ChatItem]) {
            let defaults = UserDefaults(suiteName: self.suite)!
            self.defaults = defaults
            self.gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Quote fixture", url: "ws://127.0.0.1:1", authMode: .none),
                                        defaults: defaults, identity: Fixtures.identity())
            self.gateway.cacheRoot = nil
            self.chat = ChatStore(sessionKey: "agent:main:quoted-preview", agentId: "main", gateway: self.gateway, headless: true)
            self.chat.items = items
            self.chat.rebuild(itemsChanged: true)
        }
        func stop() {
            self.chat.quotePreviewNormalizationProbe = nil
            self.gateway.stop()
            self.defaults.removePersistentDomain(forName: self.suite)
        }
    }

    private static func items(loaded: Bool, large: Bool) async -> [ChatItem] {
        await Task.detached {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var target = ChatItem(id: "local-target", role: .assistant,
                                  blocks: [.text("Meaningful **Disk** status\n\n")], timestamp: date)
            target.transcriptId = loaded ? "quoted-loaded-target" : "quoted-unloaded-target"
            if large {
                let chunk = String(repeating: "x", count: 262_144)
                target.blocks += (0..<8).map { .text("Block \($0) \(chunk)") }
            }
            var reply = ChatItem(id: "local-reply", role: .user, blocks: [.text("Can you explain that quote?")], timestamp: date.addingTimeInterval(1))
            reply.transcriptId = "quoted-reply"
            reply.replyToId = target.transcriptId
            reply.replyToPreview = ReplyPreview(text: large ? "Meaningful fallback status " + String(repeating: "y", count: 2 * 1024 * 1024) : "Meaningful fallback status", senderLabel: "Maya")
            return loaded ? [target, reply] : [reply]
        }.value
    }

    @Test(.timeLimit(.minutes(2)), arguments: [true, false])
    func actualQuoteDoesNotJoinOrNormalizeLargeLoadedOrFallbackTextOnMain(_ loaded: Bool) async throws {
        let items = await Self.items(loaded: loaded, large: true)
        let fixture = Fixture(items: items)
        defer { fixture.stop() }
        let reply = try #require(items.last)
        let targetID = try #require(reply.replyToId)
        let probe = QuotePreviewNormalizationProbe(messageIDs: [targetID])
        fixture.chat.quotePreviewNormalizationProbe = probe
        let cold = try #require(fixture.chat.quote(for: reply)) // Actual interaction schedules preparation.
        #expect(cold.targetId == targetID)
        #expect(cold.sender == (loaded ? .agent : .label("Maya")))
        await fixture.chat.waitForQuotePreviewPreparation()
        let ready = try #require(fixture.chat.quote(for: reply))
        let text = try #require(ready.text)
        #expect(text.hasPrefix(loaded ? "Meaningful Disk status" : "Meaningful fallback status"))
        #expect(!text.isEmpty)
        #expect(probe.snapshot().mainCount == 0, "Actual quote joining/directive extraction/normalization must run off-main")
    }

    @Test(.timeLimit(.minutes(2))) func actualShortQuoteIsInstrumentedAndPreservesIdentitySenderAndOpening() async throws {
        let items = await Self.items(loaded: true, large: false)
        let fixture = Fixture(items: items)
        defer { fixture.stop() }
        let reply = try #require(items.last)
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["quoted-loaded-target"])
        fixture.chat.quotePreviewNormalizationProbe = probe
        _ = fixture.chat.quote(for: reply)
        await fixture.chat.waitForQuotePreviewPreparation()
        let quote = try #require(fixture.chat.quote(for: reply))
        #expect(quote.targetId == "quoted-loaded-target" && quote.sender == .agent)
        #expect(quote.text == "Meaningful Disk status")
        #expect(items.first?.role == .assistant && reply.role == .user)
        #expect(items.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        let counts = probe.snapshot()
        #expect(counts.mainCount + counts.offMainCount > 0, "Actual short quote proves the normalization probe is armed")
    }
}
