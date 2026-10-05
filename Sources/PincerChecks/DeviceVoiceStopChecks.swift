#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class DeviceVoiceIntentSpeaker: ReadAloudLocalSpeaking {
    var samples: [String] = []
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { samples.append(text); return true }
    func stop() {}
}
@MainActor private func checkDeviceVoiceIntent(sample: String) async {
    for mode in [0, 1, 2] {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let speaker = DeviceVoiceIntentSpeaker()
        let controller = ReadAloudController(localSpeaker: speaker, defaults: defaults)
        defer { controller.stop() }
        controller.testDeviceVoice(sample)
        guard let first = controller.deviceVoiceTaskForTesting else { check(false, "actual voice test task admitted"); return }
        var latest: Task<Void, Never>?
        if mode == 1 { controller.stop() }
        if mode == 2 { controller.testDeviceVoice("Latest owned sample"); latest = controller.deviceVoiceTaskForTesting }
        await first.value
        if let latest { await latest.value }
        check(speaker.samples == (mode == 0 ? [sample] : mode == 1 ? [] : ["Latest owned sample"]), "actual queued voice test honors Stop and latest intent")
        check(!controller.isActive, "actual completed voice test is idle")
    }
}
@MainActor func runDeviceVoiceStopChecks() async { await checkDeviceVoiceIntent(sample: "Owned sample") }
@MainActor func runDemoDeviceVoiceStopChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("voice intent Demo bootstrap", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else { check(false, "actual Demo connected"); return }
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    guard let sample = chat.items.last(where: { $0.role == .assistant && !$0.plainText.isEmpty })?.plainText else { check(false, "actual Demo reply sample available"); return }
    check(true, "actual connected Demo reply supplies sample; injected speaker does not exercise audio hardware")
    await checkDeviceVoiceIntent(sample: sample)
}
#endif
