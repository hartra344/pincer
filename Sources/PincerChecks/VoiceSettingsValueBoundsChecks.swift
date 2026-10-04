import Foundation
@testable import PincerKit

@MainActor
func runVoiceSettingsValueBoundsChecks() {
    for value in [Double.nan, .infinity, -.infinity, 1e308, -1e308, -1.0, 3.0] {
        let parsed = TTSVoiceSettings(json: ["stability": .number(value), "similarityBoost": .number(value),
                                           "style": .number(value), "speed": .number(value)])
        check(parsed == .elevenLabsDefault, "invalid voice scalar fields independently use runtime defaults")
    }
    let endpoints = TTSVoiceSettings(json: ["stability": 0, "similarityBoost": 1, "style": 1, "speed": 2, "useSpeakerBoost": false])
    check(endpoints.stability == 0 && endpoints.similarityBoost == 1 && endpoints.style == 1
          && endpoints.speed == 2 && !endpoints.useSpeakerBoost, "voice scalar inclusive endpoints retain their values")
}

@MainActor
func runDemoVoiceSettingsValueBoundsChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("voice value bounds Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "voice value bounds connect to genuine Demo"); return
    }
    // Exercise real config.get parsing with a read-response fixture; never mutate Demo config.
    var reads = 0, writes = 0
    let model = GatewayVoiceModel(methods: { gateway.hello?.methods },
                                  scopes: { gateway.hello?.scopes ?? [] },
                                  allowsWritesWithoutAdmin: true, request: { method, params in
        if method == "config.patch" { writes += 1 }
        let result = try await gateway.connection.request(method, params)
        guard method == "config.get" else { return result }
        reads += 1
        let fixture: JSONValue = ["tts": ["providers": ["elevenlabs": ["voiceSettings":
            ["stability": .number(1e308), "similarityBoost": 0.25, "style": .number(-1e308), "speed": 2]]]]]
        // ConfigSnapshot prefers resolved over config. Patch the actual preferred read field.
        let field = ["resolved", "sourceConfig", "parsed", "config"].first { result[$0] != nil } ?? "config"
        let patch = JSONValue.object([field: (result[field] ?? [:]).applyingMergePatch(fixture)])
        return result.applyingMergePatch(patch)
    })
    await model.refresh()
    let parsed = model.setups["elevenlabs"]?.voiceSettings
    check(reads > 0 && parsed != nil, "actual connected config.get reaches voice settings parser (reads=\(reads), setup=\(parsed != nil), advertised=\(gateway.hello?.methods.contains("config.get") == true))")
    check(parsed?.stability == 0.5 && parsed?.style == 0 && parsed?.similarityBoost == 0.25 && parsed?.speed == 2,
          "actual model defaults invalid fields while preserving valid neighbors")
    check(writes == 0, "voice normalization never writes configuration on read")
}
