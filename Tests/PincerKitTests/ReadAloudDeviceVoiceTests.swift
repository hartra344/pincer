import Testing
@testable import PincerKit

@Suite("Read Aloud device voice picker (#457)")
struct ReadAloudDeviceVoiceTests {
    private let available = ["com.apple.voice.a", "com.apple.voice.b"]

    @Test("A stored voice missing from the list displays as the default, not a blank tag")
    func unknownStoredVoiceShowsDefault() {
        #expect(ReadAloudSettings.displayedDeviceVoice(stored: "com.apple.voice.gone", available: available) == "")
    }

    @Test("A stored voice in the list is displayed as itself")
    func knownStoredVoiceIsKept() {
        #expect(ReadAloudSettings.displayedDeviceVoice(stored: "com.apple.voice.b", available: available) == "com.apple.voice.b")
    }

    @Test("The default (empty) selection stays empty")
    func emptyStaysEmpty() {
        #expect(ReadAloudSettings.displayedDeviceVoice(stored: "", available: available) == "")
    }
}
