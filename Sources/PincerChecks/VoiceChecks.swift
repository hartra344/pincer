import Foundation
import PincerKit

@MainActor
private final class HeldReadAloudSpeaker: ReadAloudLocalSpeaking {
    private var completion: CheckedContinuation<Bool, Never>?

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        await withCheckedContinuation { self.completion = $0 }
    }

    func stop() {
        self.completion?.resume(returning: false)
        self.completion = nil
    }
}

@MainActor
private final class SilentReadAloudPlayer: ReadAloudClipPlaying {
    func play(_: TTSClip) async -> Bool { false }
    func stop() {}
}

/// The pill is present while Read Aloud has an active phase; stop returns the model to idle.
@MainActor
private func readAloudPresenceChecks() async {
    let suite = "PincerChecks-ReadAloud-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
    let speaker = HeldReadAloudSpeaker()
    let controller = ReadAloudController(clipPlayer: SilentReadAloudPlayer(), localSpeaker: speaker, defaults: defaults)
    controller.start(messageId: "demo-pill", text: "Read this reply.", gateway: nil)
    check(controller.phase == .preparing("demo-pill") && controller.isActive, "Read Aloud enters an active preparing phase")
    let speaking = await waitFor("Read Aloud demo speaker", timeout: 5) { controller.phase == .speaking("demo-pill") }
    check(speaking && controller.activeMessageId == "demo-pill", "the active reply remains identified while speaking")
    controller.stop()
    check(controller.phase == .idle && !controller.isActive, "stopping Read Aloud returns to idle")
}

/// Gateway text-to-speech (`GatewayVoiceModel`) against the demo or the mock: status, providers and
/// personas load, provider/persona round-trips, and `tts.speak` returns a decodable WAV.
@MainActor
private func voiceChecks(_ gateway: GatewayStore, label: String, seededAuto: TTSAutoMode = .off) async {
    let voice = gateway.voice
    check(GatewayVoiceModel.speakMethod.isEmpty == false
          && [GatewayVoiceModel.statusMethod, GatewayVoiceModel.providersMethod, GatewayVoiceModel.personasMethod,
              GatewayVoiceModel.enableMethod, GatewayVoiceModel.disableMethod, GatewayVoiceModel.setProviderMethod,
              GatewayVoiceModel.setPersonaMethod, GatewayVoiceModel.speakMethod].allSatisfy { gateway.hello?.methods.contains($0) == true },
          "\(label): hello advertises the tts methods")
    check(voice.supportsStatus && voice.canWrite && voice.canSpeak, "\(label): voice supported, writable, can speak")
    await voice.refresh()
    check(voice.loadError == nil, "\(label): voice refresh has no error (\(voice.loadError ?? "ok"))")
    check(voice.status?.provider == "openai" && voice.status?.enabled == (seededAuto != .off) && voice.status?.auto == seededAuto.rawValue, "\(label): tts.status loads")
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
        let long = (1 ... 80).map { "Sentence \($0) of a long demo reply." }.joined(separator: " ")
        let chunks = SpeechChunker.chunks(long)
        var ok = chunks.count > 2
        for chunk in chunks where try await voice.speak(chunk).isHeaderless { ok = false }
        check(ok, "\(label): long text speaks in \(chunks.count) chunks (#562)")
    } catch { check(false, "\(label): chunked tts.speak threw \(error)") }
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

/// #411 auto-speak modes, #474 Remove Key and #475 ElevenLabs key names, over a raw admin connection: `speakerVoiceId`
/// beats `voiceId`, a `model` key is flagged as ignored, and removing the key leaves ElevenLabs unconfigured.
@MainActor
private func voiceFollowUpChecks(profile: GatewayProfile, label: String) async {
    let connection = GatewayConnection(profile: profile)
    let ready = Scripted(false)
    await connection.setHandlers(onEvent: { _ in }, onState: { state, _ in
        if state.isConnected { Task { @MainActor in ready.value = true } }
    })
    await connection.start()
    defer { Task { await connection.stop() } }
    guard await waitFor("\(label) raw voice connection", timeout: 25, { ready.value }) else {
        check(false, "\(label): raw voice connection")
        return
    }
    let voice = GatewayVoiceModel(methods: { nil }, scopes: { ["operator.admin"] }, allowsWritesWithoutAdmin: true,
                                  request: { try await connection.request($0, $1) })
    func patch(_ node: JSONValue) async throws {
        var params: JSONValue = ["raw": .string(JSONValue.object(["tts": ["providers": ["elevenlabs": node]]]).compactString()),
                                 "note": "Pincer checks"]
        if let hash = try? await connection.request("config.get", [:])["hash"]?.text, case var .object(o) = params {
            o["baseHash"] = .string(hash)
            params = .object(o)
        }
        _ = try await connection.request("config.patch", params)
        await voice.refresh()
    }

    // Auto-speak: tts.enable / tts.disable replace it with Always / Off.
    await voice.refresh()
    do {
        try await voice.setAutoSpeakChannels(true)
        await voice.refresh()
        check(voice.autoMode == .always && voice.status?.enabled == true && !voice.setAutoSpeakNeedsConfirmation(false), "\(label): tts.enable reports auto Always")
        try await voice.setAutoSpeakChannels(false)
        await voice.refresh()
        check(voice.autoMode == .off && voice.status?.enabled == false, "\(label): tts.disable reports auto Off")
    } catch { check(false, "\(label): auto mode round-trip threw \(error)") }

    do {
        _ = try await voice.saveKey("xi-good-key-123", provider: "elevenlabs")
        await voice.refresh()
        check(voice.canRemoveKey("elevenlabs"), "\(label): a saved key can be removed")

        // A `model` key is never read: flagged, and modelId stays unset.
        try await patch(["model": "eleven_turbo_v2_5", "modelId": .null])
        check(voice.setups["elevenlabs"]?.ignoredModel == "eleven_turbo_v2_5" && voice.setups["elevenlabs"]?.model == nil,
              "\(label): an ElevenLabs `model` key is flagged as ignored")
        check(voice.effectiveConfig.isEmpty || voice.status?.provider != "elevenlabs" || voice.effectiveConfig.contains { $0.label == "Model" && $0.overrideNote != nil },
              "\(label): the effective config row explains the ignored model")

        // speakerVoiceId beats voiceId: a bad voiceId is harmless while speakerVoiceId is good, and fatal once it's gone.
        try await patch(["voiceId": "bogus-voice", "speakerVoiceId": "21m00Tcm4TlvDq8ikWAM"])
        check(voice.setups["elevenlabs"]?.voice == "21m00Tcm4TlvDq8ikWAM", "\(label): the voice shown is speakerVoiceId")
        _ = try await connection.request("tts.setProvider", ["provider": "elevenlabs"])
        await voice.refresh()
        let good = await voice.test(sample: "Hello from Pincer.")
        check(good.outcome == .success && good.clip?.provider == "elevenlabs", "\(label): speakerVoiceId wins over a bad voiceId (\(good.summary))")
        try await patch(["speakerVoiceId": .null])
        let bad = await voice.test(sample: "Hello from Pincer.")
        if case let .fellBack(_, reason) = bad.outcome {
            check(reason.message.contains("bogus-voice"), "\(label): without speakerVoiceId the voiceId is used (\(reason.message))")
        } else { check(false, "\(label): without speakerVoiceId the bad voiceId is used (\(bad.outcome))") }
        // `model` is never read (a bogus one still converts); `modelId` is (a bogus one is rejected).
        try await patch(["voiceId": "21m00Tcm4TlvDq8ikWAM", "model": "eleven_bogus"])
        let ignored = await voice.test(sample: "Hello from Pincer.")
        check(ignored.outcome == .success, "\(label): a bogus `model` key is ignored by the provider (\(ignored.summary))")
        try await patch(["model": .null, "modelId": "eleven_bogus"])
        let rejected = await voice.test(sample: "Hello from Pincer.")
        if case let .fellBack(_, reason) = rejected.outcome { check(reason.message.contains("eleven_bogus"), "\(label): a bogus `modelId` is rejected (\(reason.message))") }
        else { check(false, "\(label): a bogus `modelId` is rejected (\(rejected.outcome))") }
        try await patch(["voiceId": .null, "model": .null, "modelId": .null])

        // Prefs set with tts.setProvider beat a persona's provider (the RPCs can't clear them, so the persona label is a unit test).
        _ = try await connection.request("tts.setProvider", ["provider": "openai"])
        var personaPatch: JSONValue = ["raw": .string(JSONValue.object(["tts": ["personas": ["studio": ["label": "Studio", "provider": "elevenlabs", "providers": ["elevenlabs": [:]]]]]]).compactString()), "note": "Pincer checks"]
        if let hash = try? await connection.request("config.get", [:])["hash"]?.text, case var .object(o) = personaPatch { o["baseHash"] = .string(hash); personaPatch = .object(o) }
        _ = try await connection.request("config.patch", personaPatch)
        await voice.refresh()
        check(voice.personas.contains { $0.id == "studio" && $0.provider == "elevenlabs" }, "\(label): a config persona is listed")
        try await voice.setPersona("studio")
        await voice.refresh()
        check(voice.activePersona == "studio", "\(label): the persona activates")
        try await voice.setProvider("openai")
        check(voice.status?.provider == "openai", "\(label): prefs beat the persona's provider")
        try await voice.setPersona(nil)
        try await patch(["voiceId": .null, "model": .null])

        await voice.refresh()
        check(voice.status?.provider == "openai"
              && VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: voice.status?.provider, removingProvider: "openai")
              && !VoiceKeyRemovalPolicy.shouldExplainFallback(activeProvider: voice.status?.provider, removingProvider: "elevenlabs"),
              "\(label): removal warnings follow the actual active provider, not the provider being edited")

        // Remove Key: config cleared, the secret deleted, the provider unconfigured.
        _ = try await connection.request("tts.setProvider", ["provider": "openai"])
        let outcome = try await voice.removeKey(provider: "elevenlabs")
        _ = outcome
        check(voice.setups["elevenlabs"]?.keySource == TTSProviderSetup.KeySource.none && voice.badge(for: "elevenlabs") == .needsKey && !voice.canRemoveKey("elevenlabs"),
              "\(label): removeKey leaves ElevenLabs unconfigured")
        let secrets = try? await connection.request("secrets.store.list", [:])
        let names = (secrets?["entries"]?.array ?? []).compactMap { $0["name"]?.text ?? $0.text }
        check(!names.contains("ELEVENLABS_API_KEY"), "\(label): removeKey deleted the stored secret (\(names))")
        do { try await voice.setProvider("elevenlabs"); check(false, "\(label): a removed key can't be selected") }
        catch { check(true, "\(label): a removed key can't be selected") }
    } catch { check(false, "\(label): voice follow-ups threw \(error)") }
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
    let mainChat = gateway.chat(for: "agent:main:main")
    await mainChat.load()
    let demoReply = mainChat.items.first { $0.role == .assistant && !$0.isPending && !$0.isError }
    let demoPrompt = mainChat.items.first { $0.role == .user }
    check(demoReply.map { SpeechText.speakableText(for: $0) != nil } ?? false,
          "demo transcript's assistant prose remains eligible for Read Aloud")
    check(demoPrompt.map { SpeechText.speakableText(for: $0) == nil } ?? false,
          "demo transcript's user messages are not eligible for Read Aloud")
    if let demoReply {
        var readiness = SpeechEligibilityCache()
        let first = readiness.begin(messageID: demoReply.id)
        let prepared = SpeechText.prepare(demoReply)
        check(readiness.complete(first, with: prepared, sourceRevision: 1)
              && readiness.value(messageID: demoReply.id)?.isEligible == true,
              "demo assistant prose flows through the prepared eligibility cache")
        var edited = demoReply
        edited.blocks = [.text("```swift\nlet answer = 42\n```")]
        readiness.invalidate(messageID: demoReply.id)
        let revised = readiness.begin(messageID: demoReply.id)
        let editedPrepared = SpeechText.prepare(edited)
        check(readiness.complete(revised, with: editedPrepared, sourceRevision: 2)
              && readiness.value(messageID: demoReply.id)?.isEligible == false,
              "demo same-ID edits replace old Read Aloud eligibility")
    } else {
        check(false, "demo assistant fixture exists for prepared Read Aloud coverage")
    }
    await readAloudCommandReadinessCheck(gateway)
    await readAloudCallbackOptInCheck(mainChat)
    await readAloudPresenceChecks()
    await voiceChecks(gateway, label: "demo")
    await voiceSetupChecks(gateway, label: "demo")
    await voiceFallbackChecks()
    await voiceFollowUpChecks(profile: GatewayProfile.demo(), label: "demo")
}

@MainActor
private func readAloudCallbackOptInCheck(_ chat: ChatStore) async {
    check(chat.onFinalAssistantReply == nil, "demo: the opt-in boundary starts without a Read Aloud callback")
    let priorIDs = Set(chat.items.map(\.id))
    let firstOutcome = await chat.sendMessage("A demo reply received while Read Aloud is disabled.", requiresConnection: true)
    guard case .sent = firstOutcome else {
        check(false, "demo: a reply can be committed while Read Aloud has no callback")
        return
    }
    let disabledReplyArrived = await waitFor("demo reply with Read Aloud disabled", timeout: 10) {
        chat.items.contains { $0.role == .assistant && !$0.isPending && !$0.isError && !priorIDs.contains($0.id) }
    }
    check(disabledReplyArrived, "demo: the accepted reply remains in the transcript while Read Aloud is disabled")
    guard disabledReplyArrived else { return }

    var callbacks: [String] = []
    chat.onFinalAssistantReply = { callbacks.append($0.id) }
    defer { chat.onFinalAssistantReply = nil }
    check(callbacks.isEmpty, "demo: installing Read Aloud does not replay a disabled-period reply")

    let beforeNext = Set(chat.items.map(\.id))
    let nextOutcome = await chat.sendMessage("A fresh demo reply after enabling Read Aloud.", requiresConnection: true)
    guard case .sent = nextOutcome else {
        check(false, "demo: the enabled Read Aloud callback can send a fresh reply")
        return
    }
    let delivered = await waitFor("demo reply through the enabled Read Aloud callback", timeout: 10) {
        callbacks.count == 1 && chat.items.contains { $0.role == .assistant && !$0.isPending && !beforeNext.contains($0.id) }
    }
    let newestReply = chat.items.last { $0.role == .assistant && !$0.isPending && !beforeNext.contains($0.id) }
    check(delivered && callbacks == newestReply.map { [$0.id] },
          "demo: a fresh enabled run delivers its committed reply once")
}

@MainActor
private func readAloudCommandReadinessCheck(_ gateway: GatewayStore) async {
    let chat = gateway.chat(for: "agent:main:main")
    if !chat.hasLoaded { await chat.load() }
    let loaded = await waitFor("demo transcript for Read Aloud command", timeout: 8) { chat.hasLoaded || !chat.items.isEmpty }
    check(loaded, "demo: the selected chat has transcript content for the latest-reply command")
    guard loaded else { return }

    let snapshot = chat.items
    let reply = await Task.detached(priority: .utility) {
        SpeechText.latestSpeakableReply(in: snapshot)
    }.value
    let source = reply.flatMap { value in
        snapshot.first { ($0.transcriptId ?? $0.id) == value.messageId }
    }
    check(source?.role == .assistant && source?.isPending == false && source?.isError == false && reply?.text.isEmpty == false,
          "demo: the prepared latest reply comes from a committed assistant message")
}

@MainActor
func runLiveVoice(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock voice", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await voiceConnect(profile, "mock") else { return }
    defer { gateway.stop() }
    // MOCK_TTS_AUTO=inbound|tagged|always on the mock seeds the config default, which the client must report (prefs win once written).
    let seeded = ProcessInfo.processInfo.environment["MOCK_TTS_AUTO"].flatMap { TTSAutoMode(rawValue: $0.lowercased()) } ?? .off
    await gateway.voice.refresh()
    check(gateway.voice.autoMode == seeded && gateway.voice.status?.enabled == (seeded != .off), "mock: auto mode \(seeded.rawValue) is reported")
    check(gateway.voice.setAutoSpeakNeedsConfirmation(true) == seeded.isNotSettable, "mock: replacing \(seeded.rawValue) needs confirmation only for inbound/tagged")
    await voiceChecks(gateway, label: "mock", seededAuto: seeded)
    check(!gateway.voice.canConfigure && gateway.voice.configureBlockedReason?.contains("Full Management") == true,
          "mock: a device without operator.admin can't configure the voice")
    let adminProfile = GatewayProfile(name: "Mock voice admin", url: url, authMode: .token, access: .admin)
    adminProfile.secret = token
    guard let admin = await voiceConnect(adminProfile, "mock admin") else { return }
    defer { admin.stop() }
    await voiceSetupChecks(admin, label: "mock")
    await voiceFollowUpChecks(profile: adminProfile, label: "mock")
}
