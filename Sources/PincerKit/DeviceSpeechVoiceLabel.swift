import Foundation

/// Prepared on the existing platform discovery worker; neutral name-only policy.
package enum DeviceSpeechVoiceLabel {
    package static func prepare(name: String, language: String, quality: Int, localeIdentifier: String) -> String {
        name
    }
}
