import Foundation
import Testing
@testable import PincerKit

struct DeviceSpeechVoiceLabelBoundsTests {
    @Test func qualityAndFallbackMetadataArePreparedExactly() async {
        let labels = await Task.detached {
            [1, 2, 3, 99].map { DeviceSpeechVoiceLabel.prepare(name: "Sage", language: "en-US", quality: $0, localeIdentifier: "en-US") }
        }.value
        #expect(labels == ["Sage — English (United States)", "Sage — English (United States) · Enhanced",
                           "Sage — English (United States) · Premium", "Sage — English (United States)"])
        let fallback = await Task.detached {
            DeviceSpeechVoiceLabel.prepare(name: "Sage", language: "", quality: 1, localeIdentifier: "en-US")
        }.value
        #expect(fallback == "Sage")
    }
    @Test func newMetadataHasPerVoiceAndAggregateByteBounds() async {
        let snapshot = await Task.detached {
            let voices = (0..<256).map { index in
                DeviceSpeechVoice(id: String(repeating: "i", count: 250) + String(index),
                    name: String(repeating: "n", count: 256), language: String(repeating: "l", count: 96), quality: 3,
                    displayLabel: String(repeating: "x", count: 512))
            }
            return DeviceSpeechCatalogSnapshot(localeIdentifier: "en-US", voices: voices, dictationSupport: nil)
        }.value
        #expect(!snapshot.voices.isEmpty && snapshot.voices.count < 256)
        let cost = snapshot.localeIdentifier.utf8.count + snapshot.voices.reduce(0) {
            $0 + $1.id.utf8.count + $1.name.utf8.count + $1.language.utf8.count + $1.displayLabel.utf8.count
        }
        #expect(cost <= DeviceSpeechCatalogSnapshot.maximumSnapshotBytes)
        let label = await Task.detached {
            DeviceSpeechVoiceLabel.prepare(name: String(repeating: "界", count: 256), language: "en-US", quality: 3, localeIdentifier: "en-US")
        }.value
        #expect(!label.isEmpty && label.utf8.count <= DeviceSpeechCatalogSnapshot.maximumDisplayLabelBytes)
        let invalid = DeviceSpeechVoice(id: "invalid", name: "Sage", language: "en-US", quality: 1,
                                       displayLabel: String(repeating: "x", count: 513))
        #expect(DeviceSpeechCatalogSnapshot(localeIdentifier: "en-US", voices: [invalid], dictationSupport: nil).voices.isEmpty)
    }
}
