import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI


private actor QuotedRendererGate {
    private var open = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var entered = false
    func wait() async {
        entered = true
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if open || Task.isCancelled { continuation.resume() }
                else { continuations[token] = continuation }
            }
        } onCancel: { Task { await self.cancel(token) } }
    }
    private func cancel(_ token: UUID) { continuations.removeValue(forKey: token)?.resume() }
    func release() {
        open = true
        let held = continuations.values
        continuations.removeAll()
        for continuation in held { continuation.resume() }
    }
}

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
        chat.quotePreviewPreparation = QuotePreviewPreparationService()
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
        var quoteCompletionInvalidated = false
        renderer.onInvalidate = { ids, _ in if ids == nil { quoteCompletionInvalidated = true } }
        let cold = renderer.layout(for: row, width: 600) // Render only the small quoting row.
        #expect(cold.decoration.quote?.targetId == "renderer-quoted-target")
        await chat.waitForQuotePreviewPreparation()
        let completionDeadline = ContinuousClock.now + .seconds(15)
        while !quoteCompletionInvalidated {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < completionDeadline, "Actual prepared quote completion did not invalidate the cached renderer")
            try await Task.sleep(for: .milliseconds(10))
        }
        let warm = renderer.layout(for: row, width: 600)
        #expect(warm.decoration.quote?.text?.hasPrefix("Renderer quote opening") == true)
        let normalizedBeforeBookmark = probe.snapshot().offMainCount
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
        #expect(probe.snapshot().offMainCount > 0 && probe.snapshot().offMainCount == normalizedBeforeBookmark,
                "The actual cold worker prepares text once; cache-warm bookmark refresh does not normalize again")
    }
    @Test(.timeLimit(.minutes(2))) func preparedQuoteInvalidatesFullCacheAndRejectsAnActualUnadoptedRenderJob() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(id: UUID(), name: "Quote readiness", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "agent:main:quote-readiness", agentId: "main", gateway: gateway, headless: true)
        let service = QuotePreviewPreparationService()
        chat.quotePreviewPreparation = service
        let gate = QuotedRendererGate()
        service.normalizationGate = { id in if id == "readiness-target" { await gate.wait() } }
        var target = ChatItem(id: "readiness-target", role: .assistant, blocks: [.text("Ready **quote** opening")])
        target.transcriptId = "readiness-target"
        var reply = ChatItem(id: "readiness-reply", role: .user, blocks: [.text("Unadopted render body " + UUID().uuidString)])
        reply.transcriptId = "readiness-reply"
        reply.replyToId = target.transcriptId
        chat.items = [target, reply]
        chat.rebuild(itemsChanged: true)
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["readiness-target"])
        chat.quotePreviewNormalizationProbe = probe
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Claw"), sessionKey: chat.sessionKey,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let controller = TranscriptListController(context: context, prefetchBudget: 0.004)
        let row = TranscriptRow.entry(.user(reply))
        _ = controller.accept([row], contextChanged: false)
        let driver = controller.premeasure
        do {
            // This is an actual worker result held before adoption, rather than a fabricated job.
            let job = try #require(driver.split([0], all: controller.rows, width: 700,
                                                renderer: controller.renderer).offload.first)
            let oldEpoch = driver.epoch.current
            let result = await TranscriptPremeasurer.shared.measureWithin(
                5, jobs: [job], env: controller.renderer.textEnvironment, epoch: driver.epoch)
            try #require(result.count == 1)
            let cold = controller.renderer.layout(for: row, width: 700)
            #expect(cold.decoration.quote?.targetId == "readiness-target" && cold.decoration.quote?.text == nil)
            let entryDeadline = ContinuousClock.now + .seconds(15)
            while !(await gate.entered) {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < entryDeadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            // Fill the actual bounded renderer once, with short unrelated metadata rows.
            let unrelatedCacheCount = TranscriptRenderer.layoutCacheLimit - 1
            let cacheItems = await Task.detached {
                (0..<unrelatedCacheCount).map { index in
                    var item = ChatItem(id: "quote-cache-\(index)", role: .user, blocks: [.text("Metadata row \(index)")])
                    item.transcriptId = "quote-cache-\(index)"
                    return item
                }
            }.value
            let cacheRows = cacheItems.map { TranscriptRow.entry(.user($0)) }
            for cachedRow in cacheRows { _ = controller.renderer.layout(for: cachedRow, width: 700) }
            try #require(controller.renderer.cachedLayoutCount == TranscriptRenderer.layoutCacheLimit)
            #expect(driver.epoch.current == oldEpoch, "Ordinary cache warmup does not cancel an unrelated in-flight job")
            await gate.release()
            await chat.waitForQuotePreviewPreparation()
            let publicationDeadline = ContinuousClock.now + .seconds(15)
            while driver.epoch.current == oldEpoch {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < publicationDeadline, "Actual quote readiness must reach the controller invalidation callback")
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(controller.renderer.cachedLayoutCount == 0, "Prepared readiness invalidates the real full metadata cache")
            #expect(driver.adopt(result, width: 700, epoch: oldEpoch).isEmpty,
                    "The result captured before quote readiness cannot install a stale quoting row")
            #expect(driver.stats.discardedStale > 0)
            let ready = controller.renderer.layout(for: row, width: 700)
            #expect(ready.decoration.quote?.targetId == "readiness-target" && ready.decoration.quote?.sender == .agent)
            #expect(ready.decoration.quote?.text == "Ready quote opening")
            #expect(probe.snapshot().mainCount == 0 && probe.snapshot().offMainCount == 1)
            let unrelatedRow = try #require(cacheRows.first)
            let warmUnrelated = controller.renderer.layout(for: unrelatedRow, width: 700)
            let revision = chat.quotePreviewRevision
            var coarseInvalidations = 0
            controller.renderer.onInvalidate = { ids, _ in if ids == nil { coarseInvalidations += 1 } }
            defer { controller.renderer.onInvalidate = nil }
            chat.items.append(ChatItem(id: "unrelated-append", role: .user, blocks: [.text("New unrelated message")]))
            chat.rebuild(itemsChanged: true)
            // Re-read actual decoration so the warm quote authority is checked after the append.
            #expect(controller.renderer.layout(for: row, width: 700).decoration.quote?.text == "Ready quote opening")
            await Task.yield()
            #expect(chat.quotePreviewRevision == revision && coarseInvalidations == 0)
            #expect(controller.renderer.layout(for: unrelatedRow, width: 700).serial == warmUnrelated.serial,
                    "An unrelated append preserves actual warm metadata layouts")
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }

    @Test(.timeLimit(.minutes(2))) func rejectedVisibleOwnerAutomaticallyRefreshesWhenOldOwnerWorkFinishes() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let profile = GatewayProfile(id: UUID(), name: "Quote admission", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let service = QuotePreviewPreparationService()
        let gate = QuotedRendererGate()
        service.normalizationGate = { id in if id == "old-owner-0" { await gate.wait() } }
        func pair(_ id: String, _ text: String) -> [ChatItem] {
            var target = ChatItem(id: id, role: .assistant, blocks: [.text(text)])
            target.transcriptId = id
            var reply = ChatItem(id: "reply-" + id, role: .user, blocks: [.text("Explain this")])
            reply.transcriptId = "reply-" + id
            reply.replyToId = id
            return [target, reply]
        }
        let oldPairs = (0..<33).map { pair("old-owner-\($0)", "Distinct old owner opening \($0)") }
        let old = ChatStore(sessionKey: "agent:main:old-quote-owner", agentId: "main", gateway: gateway, headless: true)
        old.quotePreviewPreparation = service
        old.items = oldPairs.flatMap { $0 }
        old.rebuild(itemsChanged: true)
        defer { old.stopQuotePreviewPublication() }
        let visiblePair = pair("visible-owner-target", "New visible meaningful quote")
        let visible = ChatStore(sessionKey: "agent:main:visible-quote-owner", agentId: "main", gateway: gateway, headless: true)
        visible.quotePreviewPreparation = service
        visible.items = visiblePair
        visible.rebuild(itemsChanged: true)
        defer { visible.stopQuotePreviewPublication() }
        let probe = QuotePreviewNormalizationProbe(messageIDs: ["visible-owner-target"])
        visible.quotePreviewNormalizationProbe = probe
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "main", name: "Claw"), sessionKey: visible.sessionKey,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: visible)
        let renderer = TranscriptRenderer(context: context)
        let row = TranscriptRow.entry(.user(visiblePair[1]))
        var refreshedText: String?
        var actualInvalidations = 0
        renderer.onInvalidate = { ids, _ in
            guard ids == nil || ids?.contains(row.id) == true else { return }
            actualInvalidations += 1
            // Real renderer observation drives this refresh, as a visible list does.
            refreshedText = renderer.layout(for: row, width: 600).decoration.quote?.text
        }
        defer { renderer.onInvalidate = nil }
        do {
            _ = old.quote(for: oldPairs[0][1])
            let enteredDeadline = ContinuousClock.now + .seconds(15)
            while !(await gate.entered) {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < enteredDeadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            for pair in oldPairs.dropFirst() { _ = old.quote(for: pair[1]) }
            try #require(service.activeCount == 1 && service.pendingCount == 32)
            let cold = renderer.layout(for: row, width: 600)
            #expect(cold.decoration.quote?.targetId == "visible-owner-target" && cold.decoration.quote?.sender == .agent)
            #expect(cold.decoration.quote?.text == nil && probe.snapshot().offMainCount == 0)
            await gate.release()
            // No new input, getter, or layout request here: only actual observation may retry.
            let readyDeadline = ContinuousClock.now + .seconds(15)
            while refreshedText == nil {
                try Task.checkCancellation()
                try #require(ContinuousClock.now < readyDeadline,
                             "A quote rejected behind old-owner work must refresh automatically once capacity returns")
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(refreshedText == "New visible meaningful quote" && actualInvalidations > 0)
            #expect(probe.snapshot().mainCount == 0 && probe.snapshot().offMainCount > 0)
            await service.drain()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }

}
