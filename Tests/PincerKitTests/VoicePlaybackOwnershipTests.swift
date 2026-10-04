import Foundation
import Testing
@testable import PincerKit

struct VoicePlaybackOwnershipTests {
    @Test func currentCompletionAndExplicitStop() {
        var ownership = VoicePlaybackOwnership()
        let current = ownership.begin()
        #expect(ownership.owns(current))
        ownership.invalidate()
        #expect(!ownership.owns(current))
        ownership.invalidate()
        let restarted = ownership.begin()
        #expect(ownership.owns(restarted))
        #expect(!ownership.owns(current))
    }

    @Test func queuedCompletionCannotStopReplacementOrSameVoiceABA() {
        var ownership = VoicePlaybackOwnership()
        let firstA = ownership.begin()
        let b = ownership.begin()
        #expect(!ownership.owns(firstA))
        #expect(ownership.owns(b))
        let newA = ownership.begin()
        #expect(!ownership.owns(firstA))
        #expect(!ownership.owns(b))
        #expect(ownership.owns(newA))
    }

    @Test func testClipAndPreviewUseTheSameOwnershipBoundary() {
        var ownership = VoicePlaybackOwnership()
        let preview = ownership.begin()
        let testClip = ownership.begin()
        #expect(!ownership.owns(preview))
        #expect(ownership.owns(testClip))
        let nextPreview = ownership.begin()
        #expect(!ownership.owns(testClip))
        #expect(ownership.owns(nextPreview))
        ownership.invalidate()
        #expect(!ownership.owns(nextPreview))
    }
}
