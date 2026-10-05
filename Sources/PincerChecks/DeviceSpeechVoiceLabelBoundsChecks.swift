import Foundation
import PincerKit

@MainActor func runDeviceSpeechVoiceLabelBoundsChecks() async {
    let labels = await Task.detached {
        [1, 2, 3, 99].map { DeviceSpeechVoiceLabel.prepare(name: "Sage", language: "en-US", quality: $0, localeIdentifier: "en-US") }
    }.value
    check(labels == ["Sage — English (United States)", "Sage — English (United States) · Enhanced",
                     "Sage — English (United States) · Premium", "Sage — English (United States)"],
          "default, enhanced, premium and unknown quality labels retain exact supported metadata")
    let label = await Task.detached {
        DeviceSpeechVoiceLabel.prepare(name: String(repeating: "界", count: 256), language: "en-US", quality: 3, localeIdentifier: "en-US")
    }.value
    check(!label.isEmpty && label.utf8.count <= DeviceSpeechCatalogSnapshot.maximumDisplayLabelBytes,
          "prepared Unicode label obeys its byte budget")
}
