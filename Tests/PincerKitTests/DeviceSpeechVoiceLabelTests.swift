import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct DeviceSpeechVoiceLabelTests {
    @Test func duplicateNamesExposeRegionAndQuality() async {
        let labels = await Task.detached {
            [DeviceSpeechVoiceLabel.prepare(name: "Sage", language: "en-US", quality: 2, localeIdentifier: "en-US"),
             DeviceSpeechVoiceLabel.prepare(name: "Sage", language: "en-GB", quality: 3, localeIdentifier: "en-US")]
        }.value
        #expect(labels[0] != labels[1])
        #expect(labels[0].contains("United States") && labels[0].contains("Enhanced"))
        #expect(labels[1].contains("United Kingdom") && labels[1].contains("Premium"))
        #expect(labels.allSatisfy { $0.contains("Sage") })
    }
    @Test func legacyConstructionRetainsNameAndIdentity() {
        let voice = DeviceSpeechVoice(id: "voice", name: "Sage", language: "en-US", quality: 1)
        #expect(voice.displayLabel == "Sage" && voice.id == "voice")
    }
}
