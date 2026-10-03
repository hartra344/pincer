import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runDemoQuotePreviewChecks() async {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("quoted-row Demo connection", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "quoted-row preview: connects to real built-in Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:main")
    await chat.load()
    let loaded = await waitFor("quoted-row seeded history") {
        chat.message(withId: "demo-main-gauge-ask") != nil && chat.message(withId: "demo-main-status") != nil
    }
    check(loaded, "quoted-row preview: real seeded target and replying message loaded")
    guard loaded, let reply = chat.message(withId: "demo-main-gauge-ask") else { return }
    let probe = QuotePreviewNormalizationProbe(messageIDs: ["demo-main-status"])
    chat.quotePreviewNormalizationProbe = probe
    defer { chat.quotePreviewNormalizationProbe = nil }
    let cold = chat.quote(for: reply)
    check(cold?.targetId == "demo-main-status" && cold?.sender == .agent, "quoted-row preview: seeded cold quote preserves immediate identity and sender")
    await chat.waitForQuotePreviewPreparation()
    let ready = chat.quote(for: reply)
    check(ready?.text?.contains("Disk status") == true, "quoted-row preview: seeded loaded quote has meaningful prepared text")
    let counts = probe.snapshot()
    check(counts.mainCount + counts.offMainCount > 0, "quoted-row preview: actual seeded normalization is instrumented")
    check(counts.mainCount == 0, "quoted-row preview: actual seeded loaded normalization stays off-main")
    chat.items.removeAll { $0.transcriptId == "demo-main-status" }
    chat.rebuild(itemsChanged: true)
    _ = chat.quote(for: reply)
    await chat.waitForQuotePreviewPreparation()
    let fallback = chat.quote(for: reply)
    check(fallback?.targetId == "demo-main-status" && fallback?.sender == .label("Claw")
          && fallback?.text?.hasPrefix("Disk status") == true, "quoted-row preview: genuine recorded fallback retains target, sender and opening when history is absent")
    check(probe.snapshot().mainCount == 0, "quoted-row preview: recorded fallback normalization stays off-main")
    #endif
}
