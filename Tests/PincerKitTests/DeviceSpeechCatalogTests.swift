import Foundation
import Testing
@testable import PincerKit

private final class CatalogThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var discoveredOnMain: Bool? { self.lock.withLock { self.value } }

    func record(_ isMain: Bool) { self.lock.withLock { self.value = isMain } }
}

private final class CatalogRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0

    var callCount: Int { self.lock.withLock { self.calls } }

    func waitForSecondCall() -> Bool { self.entered.wait(timeout: .now() + 2) == .success }
    func open() { self.release.signal() }

    func discover(_ locale: String) -> DeviceSpeechCatalogSnapshot {
        let call = self.lock.withLock { () -> Int in
            self.calls += 1
            return self.calls
        }
        if locale == "en-US", call == 2 {
            self.entered.signal()
            self.release.wait()
        }
        return DeviceSpeechCatalogSnapshot(localeIdentifier: locale, voices: [], dictationSupport: nil)
    }
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

    @Test func forcedRefreshKeepsOneWorkerAndOnlyTheLatestPendingLocale() async {
        let gate = CatalogRefreshGate()
        let catalog = DeviceSpeechCatalog(discover: gate.discover)
        catalog.refresh(localeIdentifier: "en-US")
        let initiallyLoaded = await eventually(timeout: .seconds(2)) { catalog.snapshot?.localeIdentifier == "en-US" }
        #expect(initiallyLoaded)

        catalog.refresh(localeIdentifier: "en-US", force: true)
        let entered = await Task.detached { gate.waitForSecondCall() }.value
        #expect(entered, "the forced refresh is held by the deterministic discovery gate")
        catalog.refresh(localeIdentifier: "fr-FR")
        catalog.refresh(localeIdentifier: "de-DE")
        #expect(catalog.isRefreshing)
        #expect(catalog.snapshot?.localeIdentifier == "en-US", "the last usable snapshot stays available while refreshing")

        gate.open()
        let latestLoaded = await eventually(timeout: .seconds(2)) {
            catalog.snapshot?.localeIdentifier == "de-DE" && !catalog.isRefreshing
        }
        #expect(latestLoaded, "the newest queued locale wins")
        #expect(gate.callCount == 3, "the intermediate locale is coalesced instead of starting another worker")
    }
}
