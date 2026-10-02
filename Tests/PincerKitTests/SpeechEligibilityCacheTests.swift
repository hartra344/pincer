import Testing
@testable import PincerKit

@Suite("Read Aloud eligibility cache")
struct SpeechEligibilityCacheTests {
    @Test func staleWorkCannotRestoreDeletedOrReplacedReadiness() {
        var cache = SpeechEligibilityCache(countLimit: 4, textByteLimit: 64)
        let deleted = cache.begin(messageID: "message")
        cache.invalidate(messageID: "message")
        #expect(cache.value(messageID: "message") == nil)

        let restored = cache.begin(messageID: "message")
        #expect(!cache.complete(deleted, with: .init(isEligible: true, speechText: "old text", utf8ByteCount: 8), sourceRevision: 1))
        #expect(cache.value(messageID: "message") == nil)
        #expect(cache.complete(restored, with: .init(isEligible: true, speechText: "new text", utf8ByteCount: 8), sourceRevision: 2))
        #expect(cache.value(messageID: "message")?.isEligible == true)
        #expect(cache.value(messageID: "message")?.speechText == "new text")
        #expect(cache.value(messageID: "message")?.sourceRevision == 2)
    }

    @Test func oversizedSpeechKeepsEligibilityWithoutRetainingTheText() {
        var cache = SpeechEligibilityCache(countLimit: 2, textByteLimit: 4)
        let token = cache.begin(messageID: "long-reply")
        let prepared = SpeechEligibilityCache.Prepared(isEligible: true, speechText: "long reply", utf8ByteCount: 10)

        #expect(cache.complete(token, with: prepared, sourceRevision: 9))
        #expect(cache.value(messageID: "long-reply")?.isEligible == true)
        #expect(cache.value(messageID: "long-reply")?.speechText == nil)
        #expect(cache.retainedTextBytes == 0)
    }

    @Test func cacheBoundsEntriesAndRetainedText() {
        var cache = SpeechEligibilityCache(countLimit: 2, textByteLimit: 4)
        let first = cache.begin(messageID: "first")
        #expect(cache.complete(first, with: .init(isEligible: true, speechText: "abcd", utf8ByteCount: 4), sourceRevision: 1))
        let second = cache.begin(messageID: "second")
        #expect(cache.complete(second, with: .init(isEligible: true, speechText: "efgh", utf8ByteCount: 4), sourceRevision: 1))
        let third = cache.begin(messageID: "third")
        #expect(cache.complete(third, with: .init(isEligible: false, speechText: nil, utf8ByteCount: 0), sourceRevision: 1))

        #expect(cache.count <= 2)
        #expect(cache.retainedTextBytes <= 4)
        #expect(cache.value(messageID: "first") == nil)
        #expect(cache.value(messageID: "third")?.isEligible == false)
    }
}
