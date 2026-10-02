import PincerKit

@MainActor
func runVoiceKeyRemovalChecks() {
    check(VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: "elevenlabs", removingProvider: "elevenlabs"),
          "removing the active voice key explains fallback")
    check(!VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: "openai", removingProvider: "elevenlabs"),
          "removing an inactive voice key does not imply replies change")
    check(!VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: nil, removingProvider: "elevenlabs"),
          "unknown voice status does not claim a fallback")
}
