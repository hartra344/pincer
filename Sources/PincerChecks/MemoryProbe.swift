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
/// opened (restore + select), then left (deselected, which trims a windowed chat). Numbers only.
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

    let chat = gateway.chat(for: key)
    await chat.restoreFromCache()
    chat.hasLoaded = true
    gateway.selectedKey = key
    try? await Task.sleep(for: .milliseconds(500))
    let opened = memoryUsage()
    let openedCount = chat.items.count
    malloc_zone_pressure_relief(nil, 0)
    let openedRelieved = memoryUsage()

    gateway.selectedKey = "agent:main:dashboard:other"
    await chat.trimToWindow()
    try? await Task.sleep(for: .milliseconds(500))
    let left = memoryUsage()
    let leftCount = chat.items.count
    malloc_zone_pressure_relief(nil, 0)
    let leftRelieved = memoryUsage()

    print("  · \(count)-item chat, cache only: footprint \(mb(Int64(baseline.footprint)))")
    print("  · opened: \(openedCount) items in memory, footprint \(mb(Int64(opened.footprint))) (after pressure relief \(mb(Int64(openedRelieved.footprint))))")
    print("  · left:   \(leftCount) items in memory, footprint \(mb(Int64(left.footprint))) (after pressure relief \(mb(Int64(leftRelieved.footprint))))")
    chat.stopCaching()
    await TranscriptCache.remove(gatewayId: gateway.id, sessionKey: key)
}

/// Kept out of the probe body so the 20k source items are freed before the baseline is taken.
private func saveSyntheticChat(count: Int, gatewayId: UUID, key: String) async {
    let snapshot = TranscriptCache.Snapshot(items: Synthetic.items(chat: 0, count: count), complete: true, activityMs: 5)
    await TranscriptCache.save(snapshot, gatewayId: gatewayId, sessionKey: key)
}
