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
}

@MainActor
func runLiveVoice(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock voice", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await voiceConnect(profile, "mock") else { return }
    defer { gateway.stop() }
    await voiceChecks(gateway, label: "mock")
}
