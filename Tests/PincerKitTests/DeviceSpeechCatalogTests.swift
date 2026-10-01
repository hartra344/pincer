import Foundation
import Testing
@testable import PincerKit

private final class CatalogThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var discoveredOnMain: Bool? { self.lock.withLock { self.value } }

    func record(_ isMain: Bool) { self.lock.withLock { self.value = isMain } }
}

@MainActor
@Suite("Device speech catalog")
struct DeviceSpeechCatalogTests {
    @Test func refreshDoesNotRunDiscoveryOnTheMainThread() async {
        let probe = CatalogThreadProbe()
        let catalog = DeviceSpeechCatalog { locale in
            probe.record(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.05)
            return DeviceSpeechCatalogSnapshot(
                localeIdentifier: locale,
                voices: [DeviceSpeechVoice(id: "system.voice", name: "System Voice", language: locale, quality: 2)],
                dictationSupport: DeviceDictationSupport(language: "English", supported: true))
        }

        catalog.refresh(localeIdentifier: "en-US")
        let loaded = await eventually(timeout: .seconds(2)) { catalog.snapshot?.localeIdentifier == "en-US" }
        #expect(loaded)
        #expect(probe.discoveredOnMain == false,
                "voice enumeration and speech recognizer construction must stay off the scrolling thread")
    }

    @Test func snapshotBoundsTheRetainedVoiceCatalog() {
        let voices = (0 ..< 300).map {
            DeviceSpeechVoice(id: "voice-\($0)", name: "Voice \($0)", language: "en-US", quality: $0 % 3)
        }
        let snapshot = DeviceSpeechCatalogSnapshot(localeIdentifier: "en-US", voices: voices, dictationSupport: nil)

        #expect(snapshot.voices.count == DeviceSpeechCatalogSnapshot.maximumVoiceCount)
        #expect(snapshot.voices.reduce(0) { $0 + $1.id.utf8.count + $1.name.utf8.count + $1.language.utf8.count }
                <= DeviceSpeechCatalogSnapshot.maximumSnapshotBytes)
    }
}
