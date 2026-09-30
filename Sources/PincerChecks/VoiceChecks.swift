import Foundation
import PincerKit

/// Gateway text-to-speech (`GatewayVoiceModel`) against the demo or the mock: status, providers and
/// personas load, provider/persona round-trips, and `tts.speak` returns a decodable WAV.
@MainActor
private func voiceChecks(_ gateway: GatewayStore, label: String) async {
    let voice = gateway.voice
    check(GatewayVoiceModel.speakMethod.isEmpty == false
          && [GatewayVoiceModel.statusMethod, GatewayVoiceModel.providersMethod, GatewayVoiceModel.personasMethod,
              GatewayVoiceModel.enableMethod, GatewayVoiceModel.disableMethod, GatewayVoiceModel.setProviderMethod,
              GatewayVoiceModel.setPersonaMethod, GatewayVoiceModel.speakMethod].allSatisfy { gateway.hello?.methods.contains($0) == true },
          "\(label): hello advertises the tts methods")
    check(voice.supportsStatus && voice.canWrite && voice.canSpeak, "\(label): voice supported, writable, can speak")
    await voice.refresh()
    check(voice.loadError == nil, "\(label): voice refresh has no error (\(voice.loadError ?? "ok"))")
    check(voice.status?.provider == "openai" && voice.status?.enabled == false && voice.status?.auto == "off", "\(label): tts.status loads")
    check(voice.providers.map(\.id).contains("openai") && voice.providers.contains { $0.id == "openai" && $0.configured && $0.voices.contains("alloy") }
          && voice.providers.contains { !$0.configured }, "\(label): providers include a configured and an unconfigured one")
    check(Set(voice.personas.map(\.id)) == ["narrator", "concise"] && voice.activePersona == nil, "\(label): personas load, none active")

    do {
        try await voice.setProvider("openai")
        await voice.refresh()
        check(voice.status?.provider == "openai", "\(label): setProvider round-trips")
    } catch { check(false, "\(label): setProvider threw \(error)") }
    do {
        try await voice.setProvider("elevenlabs")
        check(false, "\(label): an unconfigured provider is refused")
    } catch {
        await voice.refresh()
        check(voice.status?.provider == "openai", "\(label): unconfigured provider refused, state kept")
    }
    do {
        try await voice.setProvider("nope")
        check(false, "\(label): unknown provider is rejected")
    } catch { check(voice.status?.provider == "openai", "\(label): unknown provider rejected, state kept") }

    do {
        try await voice.setPersona("narrator")
        await voice.refresh()
        check(voice.activePersona == "narrator", "\(label): setPersona round-trips")
        try await voice.setPersona(nil)
        await voice.refresh()
        check(voice.activePersona == nil, "\(label): persona cleared with off")
    } catch { check(false, "\(label): setPersona threw \(error)") }
    do {
        try await voice.setPersona("nope")
        check(false, "\(label): unknown persona is rejected")
    } catch { check(voice.activePersona == nil, "\(label): unknown persona rejected") }

    do {
        try await voice.setAutoSpeakChannels(true)
        await voice.refresh()
        check(voice.status?.enabled == true, "\(label): tts.enable")
        try await voice.setAutoSpeakChannels(false)
        await voice.refresh()
        check(voice.status?.enabled == false, "\(label): tts.disable")
    } catch { check(false, "\(label): enable/disable threw \(error)") }

    do {
        let clip = try await voice.speak("Hello from Pincer.")
        check(clip.mimeType == "audio/wav" && clip.fileExtension == "wav" && !clip.isHeaderless && clip.provider == "openai"
              && clip.fileTypeHint == "com.microsoft.waveform-audio", "\(label): tts.speak clip metadata")
        let bytes = [UInt8](clip.data)
        check(bytes.count > 44 && String(decoding: bytes[0 ..< 4], as: UTF8.self) == "RIFF" && String(decoding: bytes[8 ..< 12], as: UTF8.self) == "WAVE",
              "\(label): tts.speak returns a WAV (\(bytes.count) bytes)")
    } catch { check(false, "\(label): tts.speak threw \(error)") }
    do {
        _ = try await voice.speak("   ")
        check(false, "\(label): empty text is rejected")
    } catch { check(true, "\(label): empty text is rejected") }
}

/// The #459 setup flow: pick ElevenLabs, save its key, pick Eleven v4 Turbo and a voice, Test succeeds and
/// reports ElevenLabs; a broken key or model is a clear error, not a silent fallback.
@MainActor
private func voiceSetupChecks(_ gateway: GatewayStore, label: String) async {
    let voice = gateway.voice
    voice.voiceLister = { key in
        guard let key, !key.isEmpty else { throw TTSSetupError.needsKey }
        return [ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel"), ElevenLabsVoice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam")]
    }
    await voice.refresh()
    check(gateway.hello?.methods.contains("secrets.store.set") == true && voice.canConfigure && voice.configureBlockedReason == nil,
          "\(label): setup is writable and the secrets store is advertised")
    check(voice.badge(for: "openai") == .ready && voice.badge(for: "elevenlabs") == .needsKey, "\(label): ElevenLabs starts as Needs key")
    check(voice.modelOptions(for: "elevenlabs").first?.id == "eleven_v4_turbo", "\(label): Eleven v4 Turbo is the first ElevenLabs model")
    if case let .automatic(provider, _, _) = voice.readAloudSummary { check(provider == "OpenAI", "\(label): Read Aloud is automatic on OpenAI") }
    else { check(false, "\(label): Read Aloud is automatic on OpenAI") }

    let first = await voice.test(sample: "Hello from Pincer.")
    check(first.outcome == .success && first.provider == "OpenAI", "\(label): test with OpenAI succeeds (\(first.summary))")

    do {
        _ = try await voice.saveKey("bad-key-123", provider: "elevenlabs")
        await voice.refresh()
        check(voice.badge(for: "elevenlabs") == .ready, "\(label): a saved key makes ElevenLabs configured")
        try await voice.setProvider("elevenlabs")
        check(voice.status?.provider == "elevenlabs", "\(label): ElevenLabs can be selected once it has a key")
        let broken = await voice.test(sample: "Hello from Pincer.")
        if case let .fellBack(to, reason) = broken.outcome {
            check(to == "OpenAI" && reason.message.contains("401") && reason.message.lowercased().contains("api key"),
                  "\(label): a broken key is reported with the provider's error, not a silent fallback (\(reason.message))")
        } else {
            check(false, "\(label): a broken key must be reported (\(broken.outcome))")
        }
        if case .error = voice.badge(for: "elevenlabs") { check(true, "\(label): the badge shows the error") }
        else { check(false, "\(label): the badge shows the error") }

        _ = try await voice.saveKey("xi-good-key-123", provider: "elevenlabs")
        _ = try await voice.saveModel("eleven_v4_turbo", provider: "elevenlabs")
        let voices = try await voice.listElevenLabsVoices(apiKey: nil)
        check(voices.map(\.name) == ["Rachel", "Adam"], "\(label): the account voices list with the pasted key")
        _ = try await voice.saveVoice("21m00Tcm4TlvDq8ikWAM", provider: "elevenlabs")
        _ = try await voice.saveVoiceSettings(TTSVoiceSettings(stability: 0.4, similarityBoost: 0.8, style: 0.1, useSpeakerBoost: true, speed: 1.2),
                                              provider: "elevenlabs")
        await voice.refresh()
        let setup = voice.setups["elevenlabs"]
        check(setup?.model == "eleven_v4_turbo" && setup?.voice == "21m00Tcm4TlvDq8ikWAM" && setup?.voiceSettings?.speed == 1.2,
              "\(label): model, voice and settings round-trip through config")
        if case .secretRef = setup?.keySource { check(true, "\(label): the key is a SecretRef, not inline") }
        else { check(false, "\(label): the key is a SecretRef, not inline (\(String(describing: setup?.keySource)))") }
        check(voice.effectiveConfig.contains { $0.label == "Model" && $0.value == "Eleven v4 Turbo" }, "\(label): effective config shows the model")

        let good = await voice.test(sample: "Hello from Pincer.")
        check(good.outcome == .success && good.clip?.provider == "elevenlabs", "\(label): Test succeeds and reports elevenlabs (\(good.summary))")
        check(good.summary.hasPrefix("ElevenLabs · Eleven v4 Turbo · Rachel · ") && good.summary.hasSuffix(" ms"), "\(label): the summary names provider, model and voice")
        check(voice.badge(for: "elevenlabs") == .ready, "\(label): the error badge clears after a good test")
        if case let .automatic(provider, model, _) = voice.readAloudSummary {
            check(provider == "ElevenLabs" && model == "Eleven v4 Turbo", "\(label): Read Aloud reports ElevenLabs (Eleven v4 Turbo)")
        } else { check(false, "\(label): Read Aloud summary is automatic") }

        _ = try await voice.saveModel("eleven_bogus", provider: "elevenlabs")
        let bogus = await voice.test(sample: "Hello from Pincer.")
        if case let .fellBack(_, reason) = bogus.outcome {
            check(reason.message.contains("eleven_bogus"), "\(label): a rejected model names the model (\(reason.message))")
        } else { check(false, "\(label): a rejected model is reported (\(bogus.outcome))") }
        _ = try await voice.saveModel("eleven_v4_turbo", provider: "elevenlabs")
        let again = await voice.test(sample: "Hello from Pincer.")
        check(again.outcome == .success, "\(label): fixing the model makes Test succeed again")

        try await voice.setProvider("openai")
    } catch { check(false, "\(label): voice setup threw \(error)") }

    let limited = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.write"] }, request: { _, _ in [:] })
    do { _ = try await limited.saveKey("k", provider: "elevenlabs"); check(false, "\(label): a write-only device can't save a key") }
    catch { check((error as? ConfigWriteError) == .adminRequired && limited.configureBlockedReason != nil, "\(label): a write-only device is told it needs Full Management") }
}

/// A selected provider that isn't configured: the Gateway answers with another provider, and Pincer says why.
@MainActor
private func voiceFallbackChecks() async {
    let voice = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.admin"] }, request: { method, _ in
        switch method {
        case "tts.status":
            return ["provider": "elevenlabs", "providerStates": [["id": "elevenlabs", "label": "ElevenLabs", "configured": false],
                                                               ["id": "openai", "label": "OpenAI", "configured": true]]]
        case "tts.speak": return ["audioBase64": "AAEC", "provider": "openai", "mimeType": "audio/wav", "fileExtension": "wav"]
        default: return [:]
        }
    })
    await voice.refresh()
    let result = await voice.test(sample: "Hi")
    check(result.outcome == .fellBack(to: "OpenAI", reason: .notConfigured(provider: "ElevenLabs")), "fallback: unconfigured provider is reported (\(result.outcome))")
    check(voice.readAloudSummary == .gatewayFallback(selected: "ElevenLabs", reason: .notConfigured(provider: "ElevenLabs"), using: "OpenAI"),
          "fallback: Read Aloud summary names the selected provider, the reason and the one in use (\(voice.readAloudSummary))")
}

@MainActor
private func voiceConnect(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let up = await waitFor("\(label) connected", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
    check(up, "\(label): connected for voice")
    guard up else { gateway.stop(); return nil }
    return gateway
}

@MainActor
func runDemoVoice() async {
    guard let gateway = await voiceConnect(GatewayProfile.demo(), "demo") else { return }
    defer { gateway.stop() }
    await voiceChecks(gateway, label: "demo")
    await voiceSetupChecks(gateway, label: "demo")
    await voiceFallbackChecks()
}

@MainActor
func runLiveVoice(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock voice", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await voiceConnect(profile, "mock") else { return }
    defer { gateway.stop() }
    await voiceChecks(gateway, label: "mock")
    check(!gateway.voice.canConfigure && gateway.voice.configureBlockedReason?.contains("Full Management") == true,
          "mock: a device without operator.admin can't configure the voice")
    let adminProfile = GatewayProfile(name: "Mock voice admin", url: url, authMode: .token, access: .admin)
    adminProfile.secret = token
    guard let admin = await voiceConnect(adminProfile, "mock admin") else { return }
    defer { admin.stop() }
    await voiceSetupChecks(admin, label: "mock")
}
