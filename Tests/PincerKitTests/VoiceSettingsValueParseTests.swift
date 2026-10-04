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
    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e308, -1e308, -0.1, 2.1])
    func invalidFieldsIndependentlyUseExistingDefaults(_ invalid: Double) {
        let source: JSONValue = ["stability": .number(invalid), "similarityBoost": .number(invalid),
                                 "style": .number(invalid), "speed": .number(invalid), "useSpeakerBoost": false]
        var expected = TTSVoiceSettings.elevenLabsDefault; expected.useSpeakerBoost = false
        #expect(TTSVoiceSettings(json: source) == expected)
        // A bad field does not discard another valid field or rewrite the source object.
        let mixed: JSONValue = ["stability": .number(invalid), "speed": 2]
        #expect(TTSVoiceSettings(json: mixed).speed == 2)
        #expect(source["speed"]?.double?.isNaN == invalid.isNaN)
    }
    @Test func speedRejectsValuesOutsideItsDistinctRange() {
        for invalid in [0.0, 0.49, 2.01] {
            #expect(TTSVoiceSettings(json: ["speed": .number(invalid)]).speed == 1)
        }
        #expect(TTSVoiceSettings(json: ["stability": "wrong", "useSpeakerBoost": "wrong"]) == .elevenLabsDefault)
    }
}
