import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Quoted transcript row preparation")
struct QuotedRowPreviewTests {
    @Test(.timeLimit(.minutes(2))) func actualRendererAndDecorationRefreshDoNotNormalizeTheLargeQuotedTargetOnMain() async throws {
        let items = await Task.detached {
            var target = ChatItem(id: "local-renderer-target", role: .assistant,
                                  blocks: [.text("Renderer **quote** opening\n\n")])
            target.transcriptId = "renderer-quoted-target"
            let chunk = String(repeating: "x", count: 262_144)
            target.blocks += (0..<8).map { .text("Part \($0) \(chunk)") }
            var reply = ChatItem(id: "local-renderer-reply", role: .user, blocks: [.text("Explain that result.")])
            reply.transcriptId = "renderer-reply"
            reply.replyToId = target.transcriptId
            return [target, reply]
        }.value
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(id: UUID(), name: "Quoted renderer", url: "ws://127.0.0.1:1", authMode: .none)
        // Register the exact store before any renderer/Gateway lookup can use shared defaults.
        let bookmarks = BookmarkStore.shared(gatewayId: profile.id, defaults: scratch.defaults)
        defer { BookmarkStore.forget(gatewayId: profile.id) }
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "agent:main:quoted-renderer", agentId: "main", gateway: gateway, headless: true)
        chat.items = items
        chat.rebuild(itemsChanged: true)
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["renderer-quoted-target"])
        chat.quotePreviewNormalizationProbe = probe
        defer { chat.quotePreviewNormalizationProbe = nil }
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Claw"), sessionKey: chat.sessionKey,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let renderer = TranscriptRenderer(context: context)
        let reply = try #require(items.last)
        let row = TranscriptRow.entry(.user(reply))
        let cold = renderer.layout(for: row, width: 600) // Render only the small quoting row.
        #expect(cold.decoration.quote?.targetId == "renderer-quoted-target")
        await chat.waitForQuotePreviewPreparation()
        let decoration = TranscriptLayoutBuilder(context: context, settings: .current(for: context)).decoration(for: row)
        let quote = try #require(decoration.quote)
        #expect(quote.sender == .agent && quote.targetId == "renderer-quoted-target")
        #expect(quote.text?.hasPrefix("Renderer quote opening") == true)
        #expect(cold.decoration.bookmarks.isEmpty)
        var invalidatedRows: Set<String> = []
        renderer.onInvalidate = { ids, _ in
            if let ids { invalidatedRows.formUnion(ids) }
        }
        defer { renderer.onInvalidate = nil }
        let added = bookmarks.toggle(reply, sessionKey: chat.sessionKey)
        #expect(added && bookmarks.isBookmarked(sessionKey: chat.sessionKey, messageId: "renderer-reply"))
        // Success follows the actual renderer observation/invalidation event. Time only bounds
        // a broken fixture; no short scheduling window or direct invalidation call is involved.
        let deadline = ContinuousClock.now + .seconds(15)
        while !invalidatedRows.contains(row.id) {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "Bookmark observation did not invalidate the actual cached quoting row")
            try await Task.sleep(for: .milliseconds(10))
        }
        let refreshed = renderer.layout(for: row, width: 600)
        #expect(refreshed.decoration.bookmarks == ["renderer-reply"], "Actual bookmark-triggered cached refresh applies the new star")
        #expect(refreshed.decoration.quote?.targetId == "renderer-quoted-target")
        #expect(refreshed.decoration.quote?.sender == .agent)
        #expect(refreshed.decoration.quote?.text?.hasPrefix("Renderer quote opening") == true)
        await bookmarks.waitForPreviewPreparation()
        #expect(probe.snapshot().mainCount == 0, "Actual renderer and bookmark-triggered cached-decoration refresh must not normalize full quoted text on Main")
    }
}
