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
    chat.quotePreviewPreparation = QuotePreviewPreparationService()
    let seededTarget = chat.message(withId: "demo-main-status")
    let probe = QuotePreviewNormalizationProbe(messageIDs: ["demo-main-status"])
    chat.quotePreviewNormalizationProbe = probe
    defer { chat.quotePreviewNormalizationProbe = nil }
    let cold = chat.quote(for: reply)
    check(cold?.targetId == "demo-main-status" && cold?.sender == .agent, "quoted-row preview: seeded cold quote preserves immediate identity and sender")
    await chat.waitForQuotePreviewPreparation()
    let ready = chat.quote(for: reply)
    check(ready?.text?.contains("Disk status") == true, "quoted-row preview: seeded loaded quote has meaningful prepared text")
    let counts = probe.snapshot()
    check(counts.offMainCount > 0, "quoted-row preview: actual seeded normalization is instrumented")
    check((ready?.text?.count ?? 0) <= 280 && (ready?.text?.utf8.count ?? 0) <= 2048, "quoted-row preview: real seeded quote respects character and byte output bounds")
    check(counts.mainCount == 0, "quoted-row preview: actual seeded loaded normalization stays off-main")
    chat.items.removeAll { $0.transcriptId == "demo-main-status" }
    chat.rebuild(itemsChanged: true)
    _ = chat.quote(for: reply)
    await chat.waitForQuotePreviewPreparation()
    let fallback = chat.quote(for: reply)
    check(fallback?.targetId == "demo-main-status" && fallback?.sender == .label("Claw")
          && fallback?.text?.hasPrefix("Disk status") == true, "quoted-row preview: genuine recorded fallback retains target, sender and opening when history is absent")
    check(probe.snapshot().mainCount == 0 && probe.snapshot().offMainCount > counts.offMainCount,
          "quoted-row preview: actual recorded fallback worker runs off-main")
    if var target = seededTarget {
        target.blocks = await Task.detached {
            [.text("Updated **seeded** opening " + String(repeating: "x", count: 2 * 1024 * 1024))]
        }.value
        chat.items.insert(target, at: 0)
        chat.rebuild(itemsChanged: true)
        _ = chat.quote(for: reply)
        await chat.waitForQuotePreviewPreparation()
        let changed = chat.quote(for: reply)
        check(changed?.sender == .agent && changed?.targetId == "demo-main-status"
              && changed?.text?.hasPrefix("Updated seeded opening") == true,
              "quoted-row preview: loaded same-ID authority replaces the prior recorded fallback")
        check((changed?.text?.count ?? 0) <= 280 && (changed?.text?.utf8.count ?? 0) <= 2048,
              "quoted-row preview: actual large seeded-source edit has bounded output")
        target.blocks = await Task.detached { [.text(String(repeating: " ", count: 5000) + "Later meaningful content")] }.value
        if let index = chat.items.firstIndex(where: { $0.transcriptId == target.transcriptId }) { chat.items[index] = target }
        chat.rebuild(itemsChanged: true)
        _ = chat.quote(for: reply)
        await chat.waitForQuotePreviewPreparation()
        check(chat.quote(for: reply)?.text == nil,
              "quoted-row preview: unavailable loaded opening cannot reuse stale text or recorded fallback")
        check(probe.snapshot().mainCount == 0, "quoted-row preview: seeded authority edits stay off-main")
        chat.stopCaching()
        target.blocks = [.text("Fresh quote after stopped Demo history")]
        if let index = chat.items.firstIndex(where: { $0.transcriptId == target.transcriptId }) { chat.items[index] = target }
        chat.rebuild(itemsChanged: true)
        let stoppedRevision = chat.quotePreviewRevision
        _ = chat.quote(for: reply)
        await chat.waitForQuotePreviewPreparation()
        check(chat.quotePreviewPreparation.watcherCount == 0 && chat.quotePreviewPreparation.deniedOwnerCount == 0
              && chat.quotePreviewRevision == stoppedRevision,
              "quoted-row preview: actual stopped Demo history cannot reregister or publish a fresh quote")
    }
    #endif
}

@MainActor
func runQuotePreviewChecks() async {
    let activeInputBytesLimit = QuotePreviewPreparationService.activeInputBytesLimit
    let results = await Task.detached {
        let huge = String(repeating: "a", count: 2 * 1024 * 1024)
        guard let primary = ReplyPreviewSource(text: huge), let fallback = ReplyPreviewSource(text: "Recorded **fallback**") else { return [false, false, false, false] }
        let input = QuotePreviewInput(isLoaded: true, primary: primary, fallback: fallback)
        let empty = QuotePreviewInput(isLoaded: true, primary: ReplyPreviewSource(text: " \n\t"), fallback: fallback)
        let unavailable = QuotePreviewInput(isLoaded: true, primary: ReplyPreviewSource(text: String(repeating: " ", count: 5000) + "Meaningful tail"), fallback: fallback)
        return [primary.bytes.count == 4096 && input.retainedByteCount >= primary.bytes.capacity + fallback.bytes.capacity
                    && input.retainedByteCount <= activeInputBytesLimit,
                input.prepare().text == String(repeating: "a", count: 280),
                empty.prepare().text == "Recorded fallback", unavailable.prepare().text == nil]
    }.value
    check(results[0], "quoted-row preparation: actual bounded source and fallback allocations fit the admission byte budget")
    check(results[1], "quoted-row preparation: large source normalization produces only the bounded opening")
    check(results[2], "quoted-row preparation: proven empty text uses recorded fallback without a media sentinel")
    check(results[3], "quoted-row preparation: truncated whitespace is unavailable, never proven empty")
    let service = QuotePreviewPreparationService()
    check(service.activeCount == 0 && service.pendingCount == 0 && service.pendingByteCount == 0
          && service.deniedOwnerCount == 0 && service.deniedOwnerByteCount == 0,
          "quoted-row preparation: new isolated service starts without retained work")
    check(QuotePreviewPreparationService.pendingLimit == 32 && QuotePreviewPreparationService.cacheLimit == 128
          && QuotePreviewPreparationService.watcherLimit == 128
          && QuotePreviewPreparationService.deniedOwnerLimit == 128 && QuotePreviewPreparationService.deniedOwnerBytesLimit == 65_536,
          "quoted-row preparation: queue, cache and publication ownership have explicit independent count limits")
}
