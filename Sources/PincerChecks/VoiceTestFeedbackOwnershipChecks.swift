import Foundation
@testable import PincerKit

@MainActor
private func checkVoiceFeedbackOwnership(_ request: @escaping GatewayVoiceModel.Request, methods: Set<String>?) async {
    var release: CheckedContinuation<Void, Never>?
    let model = GatewayVoiceModel(methods: { methods }, request: { method, params in
        let response = try await request(method, params)
        if method == "tts.speak" {
            await withCheckedContinuation { release = $0 }
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Held old synthesis failed", details: nil)
        }
        return response
    })
    await model.refresh()
    let provider = model.status?.provider
    check(provider?.isEmpty == false, "actual voice status supplies selected provider")
    let held = Task { await model.test(sample: "Feedback fixture") }
    defer { held.cancel(); release?.resume(); release = nil }
    guard await waitFor("held voice feedback", { release != nil }) else { check(false, "actual synthesis entered"); return }
    model.handleReconnect()
    let continuation = release; release = nil; continuation?.resume()
    let outcome = await held.value
    check(outcome.outcome == .failed("Held old synthesis failed"), "obsolete test still returns its actual outcome")
    check(model.lastTestError.isEmpty && model.voiceTestOwners.isEmpty, "reconnect rejects obsolete badge and releases active ownership")
}

@MainActor func runVoiceTestFeedbackOwnershipChecks() async {
    await checkVoiceFeedbackOwnership({ method, _ in
        switch method {
        case "tts.status": return ["provider": "openai", "providerStates": [["id": "openai", "configured": true]]]
        case "tts.speak": return ["audioBase64": "AAEC", "provider": "openai", "mimeType": "audio/wav", "fileExtension": "wav"]
        default: return [:]
        }
    }, methods: ["tts.status", "tts.speak"])
}
@MainActor func runDemoVoiceTestFeedbackOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("voice feedback Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "voice feedback connects to genuine Demo"); return
    }
    // Real Demo status/audio response; only the held post-response transport error is simulated.
    await checkVoiceFeedbackOwnership({ try await gateway.connection.request($0, $1) }, methods: gateway.hello?.methods)
}
