import Foundation
import Synchronization
import Testing
@testable import PincerKit

@MainActor
@Suite("Message part accessibility excerpts")
struct MessagePartExcerptCacheTests {
    @Test func sourceRetainsOnlyTheBoundedPrefixAndDistinguishesChangedOpenings() {
        let prefix = "ALPHA opening " + String(repeating: "middle ", count: 40)
        let first = MessagePartExcerptSource(prefix + "FIRST-TAIL")
        let sameOpening = MessagePartExcerptSource(prefix + "SECOND-TAIL")
        let changedOpening = MessagePartExcerptSource("BETA opening " + String(repeating: "middle ", count: 40))

        #expect(first.retainedByteCount <= MessagePartExcerptSource.snapshotByteLimit)
        #expect(first.retainedByteCount == MessagePartExcerptSource.snapshotByteLimit)
        #expect(first == sameOpening)
        #expect(first != changedOpening)
        #expect(!first.normalizedExcerpt().contains("FIRST-TAIL"))
    }

    @Test func cacheCoalescesDuplicateKeysAndNormalizesOffMain() async {
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let backgroundFlags = Mutex<[Bool]>([])
        let cache = MessagePartExcerptCache(entryLimit: 8, byteLimit: 4_096) { source in
            let wasMain = Thread.isMainThread
            calls.withLock { $0 += 1 }
            backgroundFlags.withLock { $0.append(wasMain) }
            started.withLock { $0 = true }
            release.wait()
            return source.normalizedExcerpt()
        }
        defer { release.signal() }
        let source = MessagePartExcerptSource("A useful opening paragraph.")

        #expect(cache.excerpt(for: source) == nil)
        #expect(cache.excerpt(for: source) == nil)
        #expect(await eventually { started.withLock { $0 } })
        #expect(cache.activeCount == 1 && cache.pendingCount == 0)
        #expect(cache.inFlightKeyCount == 1 && calls.withLock { $0 } == 1)
        release.signal()

        let ready = await eventually { cache.excerpt(for: source) != nil }
        #expect(ready)
        #expect(cache.excerpt(for: source)?.hasPrefix("A useful opening") == true)
        #expect(backgroundFlags.withLock { $0 } == [false])
    }

    @Test func changedOpeningUsesItsOwnCachedExcerpt() async {
        let cache = MessagePartExcerptCache(entryLimit: 4, byteLimit: 2_048)
        let prior = MessagePartExcerptSource("Prior opening: the older reply text.")
        let updated = MessagePartExcerptSource("Updated opening: the new reply text.")

        _ = cache.excerpt(for: prior)
        #expect(await eventually { cache.excerpt(for: prior) != nil })
        _ = cache.excerpt(for: updated)
        #expect(await eventually { cache.excerpt(for: updated) != nil })
        #expect(cache.excerpt(for: prior)?.hasPrefix("Prior opening") == true)
        #expect(cache.excerpt(for: updated)?.hasPrefix("Updated opening") == true)
    }

    @Test func evictedExcerptCanBeRequestedAgainFromItsBoundedSnapshot() async {
        let calls = Mutex<[MessagePartExcerptSource: Int]>([:])
        let cache = MessagePartExcerptCache(entryLimit: 1, byteLimit: 512) { source in
            calls.withLock { $0[source, default: 0] += 1 }
            return source.normalizedExcerpt()
        }
        let first = MessagePartExcerptSource("First opening remains available after eviction.")
        let second = MessagePartExcerptSource("Second opening evicts the first cached value.")

        _ = cache.excerpt(for: first)
        #expect(await eventually { cache.excerpt(for: first) != nil })
        _ = cache.excerpt(for: second)
        #expect(await eventually { cache.excerpt(for: second) != nil })
        #expect(cache.cachedCount == 1)

        _ = cache.excerpt(for: first)
        #expect(await eventually { cache.excerpt(for: first) != nil })
        #expect(calls.withLock { $0[first] } == 2)
        #expect(cache.cachedCount == 1)
        #expect(cache.cachedByteCount <= 512)
    }

    @Test func cacheBoundsEntriesBytesAndPendingPreparation() async {
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let cache = MessagePartExcerptCache(entryLimit: 2, byteLimit: 512) { source in
            let first = started.withLock { value in
                let first = !value
                value = true
                return first
            }
            if first { release.wait() }
            return source.normalizedExcerpt()
        }
        defer { release.signal() }

        let sources = (0..<34).map { MessagePartExcerptSource("Part \($0): distinct opening words") }
        _ = cache.excerpt(for: sources[0])
        #expect(await eventually { started.withLock { $0 } })
        for source in sources.dropFirst().prefix(32) { _ = cache.excerpt(for: source) }
        #expect(cache.activeCount == 1)
        #expect(cache.pendingCount == 32)
        #expect(cache.pendingByteCount <= MessagePartExcerptSource.snapshotByteLimit * 32)
        #expect(cache.inFlightKeyCount == 33)
        _ = cache.excerpt(for: sources[33])
        #expect(cache.pendingCount == 32 && cache.inFlightKeyCount == 33)

        release.signal()
        let drained = await eventually(timeout: .seconds(5)) { cache.activeCount == 0 && cache.pendingCount == 0 }
        #expect(drained)
        #expect(cache.cachedCount > 0)
        #expect(cache.cachedCount <= 2)
        #expect(cache.cachedByteCount <= 512)
    }
}
