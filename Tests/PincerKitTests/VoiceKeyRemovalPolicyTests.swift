import Testing
@testable import PincerKit

@Suite("Voice key removal explanation (#504)")
struct VoiceKeyRemovalPolicyTests {
    @Test func fallbackIsExplainedOnlyForTheActiveProvider() {
        #expect(VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: "elevenlabs", removingProvider: "elevenlabs"))
        #expect(!VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: "openai", removingProvider: "elevenlabs"))
        #expect(!VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: nil, removingProvider: "elevenlabs"))
    }
}
