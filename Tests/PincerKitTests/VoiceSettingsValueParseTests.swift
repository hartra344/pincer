import Testing
@testable import PincerKit

struct VoiceSettingsValueParseTests {
    @Test func actualParserPreservesSupportedEndpointsAndDefaults() {
        for percent in [0.0, 0.5, 1.0] {
            for speed in [0.5, 1.0, 2.0] {
                let parsed = TTSVoiceSettings(json: ["stability": .number(percent), "similarityBoost": .number(percent),
                                                    "style": .number(percent), "speed": .number(speed), "useSpeakerBoost": false])
                #expect(parsed.stability == percent && parsed.similarityBoost == percent && parsed.style == percent)
                #expect(parsed.speed == speed && !parsed.useSpeakerBoost)
            }
        }
        #expect(TTSVoiceSettings(json: [:]) == .elevenLabsDefault)
    }
}
