@preconcurrency import AVFAudio
import Foundation
import Observation
import PincerKit
import Speech

@MainActor
@Observable
final class AppleDeviceSpeechCatalog {
    static let shared = AppleDeviceSpeechCatalog()

    let state: DeviceSpeechCatalog
    private var observers: [NSObjectProtocol] = []

    private init() {
        self.state = DeviceSpeechCatalog(discover: AppleSpeechCatalogDiscovery.snapshot)
        self.observeSystemChanges()
    }

    init(state: DeviceSpeechCatalog, observeSystemChanges: Bool = false) {
        self.state = state
        if observeSystemChanges { self.observeSystemChanges() }
    }

    private func observeSystemChanges() {
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        })
        self.observers.append(center.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: true) }
        })
    }

    func refresh(force: Bool = false) {
        self.state.refresh(localeIdentifier: Locale.current.identifier, force: force)
    }
}

/// Speech frameworks return mutable Objective-C objects; read them on the catalog worker and pass
/// only bounded Sendable values back to the main actor.
private enum AppleSpeechCatalogDiscovery {
    static func snapshot(localeIdentifier: String) -> DeviceSpeechCatalogSnapshot {
        let language = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .map { DeviceSpeechVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                return $0.name > $1.name
            }

        let locale = Locale(identifier: localeIdentifier)
        let recognizer = SFSpeechRecognizer(locale: locale)
            ?? Locale.preferredLanguages.first.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
        let support = recognizer.map {
            DeviceDictationSupport(
                language: locale.localizedString(forIdentifier: $0.locale.identifier) ?? $0.locale.identifier,
                supported: $0.supportsOnDeviceRecognition)
        }
        return DeviceSpeechCatalogSnapshot(localeIdentifier: localeIdentifier, voices: voices, dictationSupport: support)
    }
}
