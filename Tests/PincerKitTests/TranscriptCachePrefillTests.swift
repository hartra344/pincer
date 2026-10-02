import Foundation
import Testing
@testable import PincerKit

/// A headless cache fill reads a transcript before saving Gateway history. The writer must know
/// the loaded layout before that save so the index can update only the changed tail.
@MainActor
@Suite("Transcript cache prefill", .serialized)
struct TranscriptCachePrefillTests {
    @Test func headlessRestorePrimesBeforeTailSave() async throws {
        let temp = TempDir()
        let scratch = ScratchDefaults()
        let gatewayID = UUID()
        let key = "agent:main:prefill-index"
        let profile = GatewayProfile(id: gatewayID, name: "Prefill", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = temp.url
        let chat = ChatStore(sessionKey: key, agentId: nil, gateway: gateway, headless: true)
        chat.windowLimit = TranscriptCache.maxItems
        let manifest = try #require(TranscriptCache.file(gatewayId: gatewayID, sessionKey: key, root: temp.url))
        let gatewayDirectory = try #require(TranscriptCache.directory(gatewayId: gatewayID, root: temp.url))
        let original = V8.items(6_000)

        defer {
            chat.stopCaching()
            gateway.stop()
            scratch.remove()
            temp.remove()
        }

        await V8.save(V8.snapshot(original), gatewayID, key, temp.url)
        await TranscriptCache.flush(gatewayId: gatewayID, root: temp.url)
        let index = MessageIndex.shared(gatewayId: gatewayID, root: temp.url)
        #expect(!(try await index.search("question 0")).isEmpty)

        // Simulate a new process: retain the manifest and index on disk, but forget the writer's
        // in-memory fingerprints. Hold the next prime after it enters the writer so the current
        // detached restore can return and the following prefill save deterministically races it.
        await TranscriptCache.Writer.shared.forget(under: gatewayDirectory)
        await TranscriptCache.Writer.shared.delayPrimeForTesting(manifest, by: .seconds(2))
        let primeStarted = await TranscriptCache.Writer.shared.watchNextPrimeStartForTesting(manifest)
        let observedPrime = Task {
            for await _ in primeStarted { break }
        }

        await chat.restoreFromCache()
        await observedPrime.value
        #expect(chat.items == original)

        var tail = ChatItem(id: "prefill-tail", role: .assistant, blocks: [.text("prefill tail sentinel")])
        tail.transcriptId = tail.id
        chat.items.append(tail)
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gatewayID, root: temp.url)

        let stats = index.lastIndexStats
        #expect(stats.path == .tail, "expected an incremental update, got \(stats)")
        #expect(stats.documentsBuilt <= 2, "built \(stats.documentsBuilt) documents for a one-item tail")
        #expect(!(try await index.search("question 0")).isEmpty, "older indexed messages remain searchable")
        #expect(!(try await index.search("prefill tail sentinel")).isEmpty, "the new tail is searchable")

        await TranscriptCache.Writer.shared.delayPrimeForTesting(manifest, by: nil)
        await TranscriptCache.removeAll(gatewayId: gatewayID, permanently: true, root: temp.url)
        await TranscriptCache.flush(gatewayId: gatewayID, root: temp.url)
        await TranscriptCache.shutdown(root: temp.url)
    }
}
