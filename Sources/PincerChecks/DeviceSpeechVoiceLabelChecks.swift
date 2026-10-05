import Foundation
@testable import PincerKit

@MainActor private func checkPreparedDeviceVoiceLabels() async {
    let catalog = DeviceSpeechCatalog { locale in
        let voices = [("us", "en-US", 2), ("gb", "en-GB", 3)].map { id, language, quality in
            DeviceSpeechVoice(id: id, name: "Sage", language: language, quality: quality,
                displayLabel: DeviceSpeechVoiceLabel.prepare(name: "Sage", language: language,
                    quality: quality, localeIdentifier: locale))
        }
        return DeviceSpeechCatalogSnapshot(localeIdentifier: locale, voices: voices, dictationSupport: nil)
    }
    catalog.refresh(localeIdentifier: "en-US")
    let ready = await waitFor("prepared device voice labels", timeout: 15) { catalog.snapshot != nil }
    check(ready, "actual worker catalog completes"); guard ready, let voices = catalog.snapshot?.voices else { return }
    check(voices.map(\.id) == ["us", "gb"], "prepared labels preserve voice identity and order")
    guard voices.count == 2 else { check(false, "both local OS metadata fixtures are retained"); return }
    check(voices[0].displayLabel != voices[1].displayLabel, "same-name voices have distinct region labels")
    check(voices[0].displayLabel.contains("United States") && voices[0].displayLabel.contains("Enhanced"),
          "US enhanced metadata is visible in the actual prepared label")
    check(voices[1].displayLabel.contains("United Kingdom") && voices[1].displayLabel.contains("Premium"),
          "GB premium metadata is visible in the actual prepared label")
}
@MainActor func runDeviceSpeechVoiceLabelChecks() async { await checkPreparedDeviceVoiceLabels() }
@MainActor func runDemoDeviceSpeechVoiceLabelChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let ready = await waitFor("device voice label Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && !gateway.sessions.isEmpty }
    check(ready, "actual Demo provides a connected session inventory"); guard ready else { return }
    // Device voices are local OS metadata, not Gateway fields. These deterministic fixtures do not
    // claim Apple voice discovery or speech playback in the Demo.
    await checkPreparedDeviceVoiceLabels()
}
