import Foundation
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
    try? await Task.sleep(for: .seconds(2))
    let after = memoryUsage()
    print("  · opened \(chatCount) chats × \(perChat) items in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    print("  · footprint \(mb(Int64(before.footprint))) → \(mb(Int64(after.footprint))) (peak \(mb(Int64(peak)))), resident \(mb(Int64(before.resident))) → \(mb(Int64(after.resident)))")
    print("  · chats known: \(gateway.chats.count), hydrated: \(ChatResidencyShim.hydratedCount(gateway))")
    for chat in gateway.chats.values { chat.stopCaching() }
}
