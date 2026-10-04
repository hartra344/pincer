import AVFoundation
import Foundation
import Testing
@testable import PincerKit

@MainActor
private final class RateRecordingSpeaker: ReadAloudLocalSpeaking {
    var rates: [Float] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        rates.append(rate)
        return true
    }
    func stop() {}
}

@Suite("Read Aloud stored rate bounds")
struct ReadAloudRateTests {
    @Test func finiteValuesClampBeforeFloatConversion() {
        for value in [Double.greatestFiniteMagnitude, 1, 0.7] {
            #expect(ReadAloudSettings.normalizedDeviceRate(value) == ReadAloudSettings.rateRange.upperBound)
        }
        for value in [-Double.greatestFiniteMagnitude, -1, 0, 0.3] {
            #expect(ReadAloudSettings.normalizedDeviceRate(value) == ReadAloudSettings.rateRange.lowerBound)
        }
        #expect(ReadAloudSettings.normalizedDeviceRate(0.5) == 0.5)
        #expect(ReadAloudSettings.normalizedDeviceRate(0.4) == Float(0.4))
    }
    @Test func invalidValuesUseExistingDefault() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(ReadAloudSettings.normalizedDeviceRate(value) == AVSpeechUtteranceDefaultSpeechRate)
        }
        #expect(ReadAloudSettings.normalizedDeviceRate(nil) == AVSpeechUtteranceDefaultSpeechRate)
    }
    @MainActor
    @Test(arguments: [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity, 0.3, 0.5, 0.7])
    func actualDevicePlaybackReceivesSafeRate(_ stored: Double) async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(stored, forKey: ReadAloudSettings.rateKey)
        let speaker = RateRecordingSpeaker()
        let controller = ReadAloudController(localSpeaker: speaker, defaults: scratch.defaults)
        defer { controller.stop() }
        controller.testDeviceVoice("Rate sample")
        #expect(await eventually { !speaker.rates.isEmpty })
        #expect(speaker.rates == [ReadAloudSettings.normalizedDeviceRate(stored)])
    }
}
