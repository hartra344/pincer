import Foundation
import Darwin
import CryptoKit
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// Opt-in (`swift run PincerChecks --memory-probe`): footprint after opening 20 chats of 5,000 items, each
/// selected in turn like a user would, with the transcript cache on (a temporary root, set in main.swift).
/// Prints numbers once; nothing here is a budget. The two shim functions are the only residency-API uses.
@MainActor
enum ChatResidencyShim {
    static func hydratedCount(_ gateway: GatewayStore) -> String { "\(gateway.chats.values.filter(\.isHydrated).count)" }
    static func enforce(_ gateway: GatewayStore) { gateway.enforceChatBudget() }
    static func pinned(_ gateway: GatewayStore) -> Int { gateway.pinnedChatKeys().count }
    static func loadsInFlight(_ gateway: GatewayStore) -> Int { gateway.chats.values.filter(\.loadInFlight).count }
    static func passRunning(_ gateway: GatewayStore) -> Bool { gateway.enforcingChatBudget }
    static func hydrated(_ gateway: GatewayStore) -> Int { gateway.chats.values.filter(\.isHydrated).count }
}

@MainActor
func runMemoryProbe() async {
    let chatCount = 20
    let perChat = 5_000
    let scratchDefaults = UserDefaults(suiteName: "pincer.memoryprobe.\(UUID().uuidString)")!
    let gateway = GatewayStore(profile: GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: scratchDefaults, identity: DeviceIdentity(privateKey: .init()))
    let before = memoryUsage()
    let start = ContinuousClock.now
    var peak = before.footprint
    for n in 0..<chatCount {
        let key = "agent:main:dashboard:probe\(n)"
        let chat = gateway.chat(for: key)
        chat.items = Synthetic.items(chat: n, count: perChat)
        chat.hasLoaded = true
        gateway.selectedKey = key
        ChatResidencyShim.enforce(gateway)
        try? await Task.sleep(for: .milliseconds(300))
        peak = max(peak, memoryUsage().footprint)
    }
    let settleStart = ContinuousClock.now
    var last = -1
    var stable = 0
    while ContinuousClock.now - settleStart < .seconds(30) {
        try? await Task.sleep(for: .milliseconds(250))
        let count = ChatResidencyShim.hydrated(gateway)
        stable = (count == last && !ChatResidencyShim.passRunning(gateway)) ? stable + 1 : 0
        last = count
        if stable >= 2 { break }
    }
    let settle = ContinuousClock.now - settleStart
    let after = memoryUsage()
    malloc_zone_pressure_relief(nil, 0)
    let relieved = memoryUsage()
    print("  · opened \(chatCount) chats × \(perChat) items in \((settleStart - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    print("  · budget settled in \(settle.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))))")
    print("  · footprint \(mb(Int64(before.footprint))) → \(mb(Int64(after.footprint))) (peak \(mb(Int64(peak)))), resident \(mb(Int64(before.resident))) → \(mb(Int64(after.resident)))")
    print("  · after malloc_zone_pressure_relief: footprint \(mb(Int64(relieved.footprint))), resident \(mb(Int64(relieved.resident)))")
    print("  · chats known: \(gateway.chats.count), hydrated: \(ChatResidencyShim.hydratedCount(gateway))")
    print("  · pinned: \(ChatResidencyShim.pinned(gateway)), loads in flight: \(ChatResidencyShim.loadsInFlight(gateway))")
    var trail: [Int] = []
    for _ in 0..<6 {
        ChatResidencyShim.enforce(gateway)
        try? await Task.sleep(for: .milliseconds(700))
        trail.append(ChatResidencyShim.hydrated(gateway))
    }
    print("  · hydrated after repeated explicit enforceChatBudget(): \(trail)")
    for chat in gateway.chats.values { chat.stopCaching() }
}

/// Opt-in (`swift run PincerChecks --memory-probe-20k`): one 20,000-item chat saved to the cache, then
/// opened (restore + select), then left (deselected, which trims a windowed chat), then searched with Find and
/// closed again while still open (#335). Numbers only.
@MainActor
func runMemoryProbe20k() async {
    let count = 20_000
    let key = "agent:main:dashboard:big"
    let scratchDefaults = UserDefaults(suiteName: "pincer.memoryprobe20k.\(UUID().uuidString)")!
    let gateway = GatewayStore(profile: GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: scratchDefaults, identity: DeviceIdentity(privateKey: .init()))
    await saveSyntheticChat(count: count, gatewayId: gateway.id, key: key)
    await TranscriptCache.flush(gatewayId: gateway.id)
    malloc_zone_pressure_relief(nil, 0)
    let baseline = memoryUsage()
    let baselineHeap = heapInUse()

    let chat = gateway.chat(for: key)
    await chat.restoreFromCache()
    chat.hasLoaded = true
    gateway.selectedKey = key
    try? await Task.sleep(for: .milliseconds(500))
    let opened = memoryUsage()
    let openedHeap = heapInUse()
    let openedCount = chat.items.count
    malloc_zone_pressure_relief(nil, 0)
    let openedRelieved = memoryUsage()

    gateway.selectedKey = "agent:main:dashboard:other"
    await chat.trimToWindow()
    try? await Task.sleep(for: .milliseconds(500))
    let left = memoryUsage()
    let leftHeap = heapInUse()
    let leftCount = chat.items.count
    malloc_zone_pressure_relief(nil, 0)
    let leftRelieved = memoryUsage()

    // Find in chat pages the whole cached history in; leaving the chat trims it back.
    gateway.selectedKey = key
    await chat.loadAllCached()
    try? await Task.sleep(for: .milliseconds(500))
    let searched = memoryUsage()
    let searchedHeap = heapInUse()
    let searchedCount = chat.items.count
    // Find closes with the list at the bottom: the open chat trims back to its window (#335).
    await chat.trimOpenChatToWindow(stillWanted: { true })
    try? await Task.sleep(for: .milliseconds(500))
    malloc_zone_pressure_relief(nil, 0)
    let closed = memoryUsage()
    let closedHeap = heapInUse()
    let closedCount = chat.items.count
    gateway.selectedKey = "agent:main:dashboard:other"
    await chat.trimToWindow()
    try? await Task.sleep(for: .milliseconds(500))
    malloc_zone_pressure_relief(nil, 0)
    let trimmedAgain = memoryUsage()
    let trimmedAgainHeap = heapInUse()
    let trimmedCount = chat.items.count

    print("  · \(count)-item chat, cache only: footprint \(mb(Int64(baseline.footprint))), live heap \(baselineHeap)")
    print("  · opened: \(openedCount) items in memory, footprint \(mb(Int64(opened.footprint))), live heap \(openedHeap) (after pressure relief \(mb(Int64(openedRelieved.footprint))))")
    print("  · left:   \(leftCount) items in memory, footprint \(mb(Int64(left.footprint))), live heap \(leftHeap) (after pressure relief \(mb(Int64(leftRelieved.footprint))))")
    print("  · find (loadAllCached): \(searchedCount) items in memory, footprint \(mb(Int64(searched.footprint))), live heap \(searchedHeap)")
    print("  · find closed, still open (trim at bottom): \(closedCount) items in memory, footprint \(mb(Int64(closed.footprint))), live heap \(closedHeap) (after pressure relief)")
    print("  · left again (trim): \(trimmedCount) items in memory, footprint \(mb(Int64(trimmedAgain.footprint))), live heap \(trimmedAgainHeap) (after pressure relief)")
    chat.stopCaching()
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key)
}

/// Kept out of the probe body so the 20k source items are freed before the baseline is taken.
private func saveSyntheticChat(count: Int, gatewayId: UUID, key: String) async {
    let snapshot = TranscriptCache.Snapshot(items: Synthetic.items(chat: 0, count: count), complete: true, activityMs: 5)
    await TranscriptCache.save(snapshot, gatewayId: gatewayId, sessionKey: key)
}

/// Bytes live in malloc: falls when items are freed, unlike the footprint, which keeps pages the allocator holds on to.
private func heapInUse() -> String {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return mb(Int64(stats.size_in_use))
}

private final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    func note(_ value: UInt64) {
        self.lock.lock()
        self.peak = max(self.peak, value)
        self.lock.unlock()
    }
    var value: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.peak
    }
}

/// Runs `body` while a background task records the highest footprint seen.
@MainActor
private func samplingPeakFootprint(_ body: () async -> Void) async -> UInt64 {
    let box = PeakBox()
    box.note(memoryUsage().footprint)
    let sampler = Task.detached {
        while !Task.isCancelled {
            box.note(memoryUsage().footprint)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    await body()
    box.note(memoryUsage().footprint)
    sampler.cancel()
    return box.value
}

/// Opt-in (`swift run PincerChecks --memory-probe-20k-fill`, its own process so earlier allocations don't hide the peak):
/// the background full fill of a 20,000-item chat, which holds the whole history in a headless store while it
/// saves. Footprint is sampled every 10 ms during the fill.
@MainActor
func runMemoryProbe20kFill() async {
    let count = 20_000
    let key = "agent:main:dashboard:big"
    let scratchDefaults = UserDefaults(suiteName: "pincer.memoryprobe20kfill.\(UUID().uuidString)")!
    let gateway = GatewayStore(profile: GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: scratchDefaults, identity: DeviceIdentity(privateKey: .init()))
    await saveSyntheticChat(count: count, gatewayId: gateway.id, key: key)
    await TranscriptCache.flush(gatewayId: gateway.id)
    malloc_zone_pressure_relief(nil, 0)
    let before = memoryUsage()
    let beforeHeap = heapInUse()
    let peak = await samplingPeakFootprint {
        let filler = ChatStore(sessionKey: key, agentId: nil, gateway: gateway, headless: true)
        filler.windowLimit = TranscriptCache.maxItems
        await filler.restoreFromCache()
        filler.hasLoaded = true
        filler.savedState = nil
        await filler.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id)
    }
    try? await Task.sleep(for: .milliseconds(300))
    malloc_zone_pressure_relief(nil, 0)
    let after = memoryUsage()
    print("  · headless full fill of \(count) items: footprint \(mb(Int64(before.footprint))) → peak \(mb(Int64(peak))) → \(mb(Int64(after.footprint))) after (live heap \(beforeHeap) → \(heapInUse()))")
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key)
}
