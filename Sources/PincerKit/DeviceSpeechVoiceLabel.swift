import Foundation

/// Prepared on the existing platform discovery worker, never in the picker body.
package enum DeviceSpeechVoiceLabel {
    package static func prepare(name: String, language: String, quality: Int, localeIdentifier: String) -> String {
        self.prepare(name: name, language: language, quality: quality, locale: Locale(identifier: localeIdentifier))
    }

    package static func prepare(name: String, language: String, quality: Int, locale: Locale) -> String {
        let languageName = locale.localizedString(forIdentifier: language) ?? language
        var label = name
        if !languageName.isEmpty { label += " — \(languageName)" }
        switch quality {
        case 2: label += " · \(L("Enhanced"))"
        case 3: label += " · \(L("Premium"))"
        default: break
        }
        var result = ""
        var bytes = 0
        for scalar in label.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= DeviceSpeechCatalogSnapshot.maximumDisplayLabelBytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += size
        }
        return result
    }
}
