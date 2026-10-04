import AVFoundation
import Foundation
import Synchronization
import PincerKit

private final class DiscoveryThreadProbe: @unchecked Sendable {
    private let value = Mutex<Bool?>(nil)
    var discoveredOnMain: Bool? { self.value.withLock { $0 } }
    func record(_ isMain: Bool) { self.value.withLock { $0 = isMain } }
}

@MainActor
private final class CatalogSilentPlayer: ReadAloudClipPlaying {
    func play(_: TTSClip) async -> Bool { false }
    func stop() {}
}

@MainActor
func runDeviceSpeechCatalogChecks() async {
    await checkReadAloudRateBounds()
    let probe = DiscoveryThreadProbe()
    let catalog = DeviceSpeechCatalog { locale in
        probe.record(Thread.isMainThread)
        Thread.sleep(forTimeInterval: 0.02)
        return DeviceSpeechCatalogSnapshot(
            localeIdentifier: locale,
            voices: [DeviceSpeechVoice(id: "demo.voice", name: "Demo Voice", language: locale, quality: 2)],
            dictationSupport: DeviceDictationSupport(language: "English", supported: true))
    }
    catalog.refresh(localeIdentifier: "en-US")
    let loaded = await waitFor("device speech snapshot", timeout: 2) { catalog.snapshot != nil }
    check(loaded, "device speech settings receive a value snapshot")
    check(probe.discoveredOnMain == false, "speech discovery stays off the UI thread")
    if let snapshot = catalog.snapshot {
        check(snapshot.voices.map(\.id) == ["demo.voice"]
              && ReadAloudSettings.displayedDeviceVoice(stored: "demo.voice", available: snapshot.voices.map(\.id)) == "demo.voice",
              "the selected device voice resolves from the completed snapshot")
        check(snapshot.dictationSupport == DeviceDictationSupport(language: "English", supported: true),
              "dictation settings share the current locale support result")
    } else {
        check(false, "the completed device speech snapshot is present")
    }

    let controller = ReadAloudController(clipPlayer: CatalogSilentPlayer(), defaults: .standard)
    check(!controller.hasCreatedSystemSpeaker, "reading Read Aloud state does not construct the audio synthesizer")
    controller.stop()
    check(!controller.hasCreatedSystemSpeaker, "stopping an idle controller keeps the synthesizer deferred")
}

@MainActor
func runDemoDeviceSpeechCatalogChecks() async {
    await checkDemoReadAloudRatePlayback()
    let catalog = DeviceSpeechCatalog { locale in
        DeviceSpeechCatalogSnapshot(
            localeIdentifier: locale,
            voices: [DeviceSpeechVoice(id: "demo.sage", name: "Sage", language: locale, quality: 2)],
            dictationSupport: DeviceDictationSupport(language: "English", supported: true))
    }
    catalog.refresh(localeIdentifier: "en-US")
    let loaded = await waitFor("demo device speech snapshot", timeout: 2) { catalog.snapshot != nil }
    check(loaded, "the demo device speech snapshot arrives asynchronously")
    check(catalog.snapshot?.voices.first?.name == "Sage"
          && ReadAloudSettings.displayedDeviceVoice(stored: "demo.sage", available: catalog.snapshot?.voices.map(\.id) ?? []) == "demo.sage",
          "the demo's saved device voice appears when the platform catalog is ready")
    check(catalog.snapshot?.dictationSupport?.supported == true,
          "the demo dictation section uses the same locale support snapshot")
}


@MainActor
private final class CatalogRateSpeaker: ReadAloudLocalSpeaking {
    var rates: [Float] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        self.rates.append(rate)
        return true
    }
    func stop() {}
}

@MainActor
private func checkReadAloudRateBounds() async {
    check(ReadAloudSettings.normalizedDeviceRate(Double.greatestFiniteMagnitude) == ReadAloudSettings.rateRange.upperBound
          && ReadAloudSettings.normalizedDeviceRate(-Double.greatestFiniteMagnitude) == ReadAloudSettings.rateRange.lowerBound,
          "Read Aloud finite speeds clamp before Float conversion")
    check([Double.nan, .infinity, -.infinity].allSatisfy {
        ReadAloudSettings.normalizedDeviceRate($0) == AVSpeechUtteranceDefaultSpeechRate
    }, "invalid stored Read Aloud speeds use the existing default")
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Double.greatestFiniteMagnitude, forKey: ReadAloudSettings.rateKey)
    let speaker = CatalogRateSpeaker()
    let controller = ReadAloudController(localSpeaker: speaker, defaults: defaults)
    defer { controller.stop() }
    controller.testDeviceVoice("Rate sample")
    let spoke = await waitFor("bounded device rate", timeout: 2) { !speaker.rates.isEmpty }
    check(spoke && speaker.rates == [ReadAloudSettings.rateRange.upperBound],
          "actual device playback receives the bounded stored speed")
}

@MainActor
private func checkDemoReadAloudRatePlayback() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:trip"
    guard await waitFor("Read Aloud rate Demo", timeout: 25, {
        gateway.state.isConnected && gateway.sessions[key] != nil
    }) else { check(false, "actual Read Aloud rate Demo connects"); return }
    let chat = gateway.chat(for: key)
    await chat.load()
    let items = chat.items
    guard let reply = await Task.detached(operation: { SpeechText.latestSpeakableReply(in: items) }).value else {
        check(false, "actual seeded Demo has a readable reply"); return
    }
    defaults.set(Double.greatestFiniteMagnitude, forKey: ReadAloudSettings.rateKey)
    let speaker = CatalogRateSpeaker()
    let controller = ReadAloudController(localSpeaker: speaker, defaults: defaults)
    defer { controller.stop() }
    controller.testDeviceVoice(reply.text)
    let spoke = await waitFor("Demo bounded device rate", timeout: 2) { !speaker.rates.isEmpty }
    check(spoke && speaker.rates == [ReadAloudSettings.rateRange.upperBound],
          "actual seeded Demo reply reaches device playback with a safe stored speed")
}
