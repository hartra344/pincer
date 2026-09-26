import Testing
@testable import PincerKit

@Suite("Transcript search stepping")
struct TranscriptSearchStepTests {
    @Test func noMatches() {
        #expect(TranscriptSearch.step(from: nil, count: 0, forward: true) == nil)
        #expect(TranscriptSearch.step(from: 0, count: 0, forward: false) == nil)
    }

    @Test func firstStepStartsAtAnEnd() {
        #expect(TranscriptSearch.step(from: nil, count: 5, forward: true) == 0)
        #expect(TranscriptSearch.step(from: nil, count: 5, forward: false) == 4)
    }

    @Test func stepsOneAtATime() {
        #expect(TranscriptSearch.step(from: 1, count: 5, forward: true) == 2)
        #expect(TranscriptSearch.step(from: 3, count: 5, forward: false) == 2)
    }

    @Test func wrapsAround() {
        #expect(TranscriptSearch.step(from: 4, count: 5, forward: true) == 0)
        #expect(TranscriptSearch.step(from: 0, count: 5, forward: false) == 4)
        #expect(TranscriptSearch.step(from: 0, count: 1, forward: true) == 0)
        #expect(TranscriptSearch.step(from: 0, count: 1, forward: false) == 0)
    }

    @Test func staleIndexRestartsAtAnEnd() {
        // The matches shrank under the selection.
        #expect(TranscriptSearch.step(from: 7, count: 3, forward: true) == 0)
        #expect(TranscriptSearch.step(from: 7, count: 3, forward: false) == 2)
        #expect(TranscriptSearch.step(from: -1, count: 3, forward: true) == 0)
    }
}
