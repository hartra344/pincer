import Foundation
@testable import PincerKit

@MainActor private final class RelayEngine: DictationEngine {
    let relay = DictationRecognitionDelivery()
    var active = false
    var isAvailable = true
    var callbacks: [@MainActor @Sendable (DictationRecognitionOutcome) -> Void] = []
    func authorize() async -> DictationIssue? { nil }
    func start(onPartial: @escaping @MainActor (String, Bool) -> Void, onError: @escaping @MainActor (DictationIssue) -> Void) throws {
        active = true
        callbacks.append(relay.begin(isActive: { [weak self] in self?.active == true }, onPartial: onPartial, onError: onError))
    }
    func stop() {}
    func cancel() { active = false }
}

@MainActor private func checkRecognitionOwnership(old: String, current: String) async {
    let engine = RelayEngine()
    let actual = DictationModel(engine: engine)
    defer { actual.cancel() }
    var draft = ""
    actual.toggle(draft: draft, caret: nil) { draft = $0 }
    let first = await waitFor("actual relay registration A", timeout: 15) { engine.callbacks.count == 1 }
    check(first, "actual model registers initial production relay callback"); guard first else { return }
    let oldCallback = engine.callbacks[0]
    actual.cancel()
    actual.toggle(draft: draft, caret: nil) { draft = $0 }
    let second = await waitFor("actual relay registration B", timeout: 15) { engine.callbacks.count == 2 }
    check(second, "actual model registers current production relay callback"); guard second else { return }
    let callback = engine.callbacks[1]
    callback(.text(current, isFinal: false))
    check(draft == current && actual.isListening, "current partial reaches actual draft")
    guard draft == current && actual.isListening else { return }
    oldCallback(.text(old, isFinal: false))
    check(draft == current, "model rejects obsolete partial generation")
    callback(.ignorable)
    check(draft == current && actual.phase == .idle, "current final retains current words after old callback delivery")
}
@MainActor func runDictationRecognitionDeliveryChecks() async {
    await checkRecognitionOwnership(old: "Obsolete words", current: "Current words")
}
@MainActor func runDemoDictationRecognitionDeliveryChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let ready = await waitFor("recognition Demo source", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(ready, "genuine Demo source connected"); guard ready else { return }
    let chat = gateway.chat(for: DemoBookmarks.tripSessionKey)
    await chat.load()
    let items = chat.items
    let texts = await Task.detached { items.filter { !$0.isPending }.map(\.plainText).filter { !$0.isEmpty } }.value
    let distinct = texts.first.map { first in texts.contains { $0 != first } } ?? false
    check(distinct, "actual Demo history supplies distinct nonempty text inputs")
    guard let old = texts.first, let current = texts.first(where: { $0 != old }) else {
        check(false, "actual Demo history supplies distinct nonempty text inputs"); return
    }
    // Source text is genuine; this exercises callback/model publication, not microphone or SDK registration.
    await checkRecognitionOwnership(old: old, current: current)
}
