import Foundation
import Testing
@testable import PincerKit

/// A headless cache fill reads a transcript before saving Gateway history. The writer must know
/// the loaded layout before that save so the index can update only the changed tail.
@MainActor
@Suite("Transcript cache prefill", .serialized)
struct TranscriptCachePrefillTests {
    func cleanup(chat: ChatStore, gateway: GatewayStore, scratch: ScratchDefaults, temp: TempDir,
                 gatewayID: UUID, key: String, manifest: URL) async {
        chat.stopCaching()
        gateway.stop()
        await TranscriptCache.Writer.shared.delayPrimeForTesting(manifest, by: nil)
        await TranscriptCache.Writer.shared.resetPrimeStartCountForTesting(manifest)
        await TranscriptCache.remove(gatewayId: gatewayID, sessionKey: key, root: temp.url)
        await TranscriptCache.flush(gatewayId: gatewayID, root: temp.url)
        await TranscriptCache.shutdown(root: temp.url)
        scratch.remove()
        temp.remove()
    }

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

        do {
            let seedWrite = await TranscriptCache.saveReturningStats(
                V8.snapshot(original), gatewayId: gatewayID, sessionKey: key, root: temp.url)
            try #require(seedWrite.filesWritten > 0,
                         "the seed manifest must be writable (\(seedWrite.filesWritten) files, \(seedWrite.bytesWritten) bytes)")
            await TranscriptCache.flush(gatewayId: gatewayID, root: temp.url)
            let seededManifest = try V8.manifest(manifest)
            try #require(seededManifest["version"] as? Int == TranscriptCache.Snapshot.currentVersion,
                         "the seed must be a readable current-format manifest")
            let index = MessageIndex.shared(gatewayId: gatewayID, root: temp.url)
            let initialHits = try await index.search("question 0")
            try #require(!initialHits.isEmpty, "the seed must have a usable search index")

            // Simulate a new process: retain the manifest and index on disk, but forget the writer's
            // in-memory fingerprints. Hold the next prime after it enters the writer so the current
            // detached restore can return and the following prefill save deterministically races it.
            await TranscriptCache.Writer.shared.forget(under: gatewayDirectory)
            await TranscriptCache.Writer.shared.delayPrimeForTesting(manifest, by: .seconds(2))
            let previousPrimeStarts = await TranscriptCache.Writer.shared.primeStartCountForTesting(manifest)

            await chat.restoreFromCache()
            try #require(chat.cacheOutcome == .loaded, "the cached transcript must restore successfully before measuring the race")
            try #require(chat.items == original, "the headless restore must contain the full retained transcript")
            var primeStarted = false
            for _ in 0..<100 {
                if await TranscriptCache.Writer.shared.primeStartCountForTesting(manifest) > previousPrimeStarts {
                    primeStarted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(primeStarted, "the load must enqueue a writer prime")

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
        } catch {
            await self.cleanup(chat: chat, gateway: gateway, scratch: scratch, temp: temp,
                               gatewayID: gatewayID, key: key, manifest: manifest)
            throw error
        }
        await self.cleanup(chat: chat, gateway: gateway, scratch: scratch, temp: temp,
                           gatewayID: gatewayID, key: key, manifest: manifest)
    }
}
