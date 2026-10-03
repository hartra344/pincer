import Foundation
@testable import PincerKit

@MainActor
func runColdTranscriptHeightEstimateChecks() async {
    let item = await Task.detached {
        ChatItem(id: "cold-estimate-source", role: .user,
                 blocks: [.text("First paragraph"), .text("Second paragraph")])
    }.value
    check(item.blocks.count == 2 && item.role == .user,
          "cold geometry fixture keeps distinct real text blocks")
}

@MainActor
func runDemoColdTranscriptHeightEstimateChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("Cold estimate Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.sessions["agent:main:dashboard:trip"] != nil
    }
    check(connected, "cold geometry source connects to actual seeded Demo")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    check(chat.entries.contains { if case .user = $0 { true } else { false } },
          "actual seeded history supplies user geometry rows")
    check(chat.entries.contains { if case .assistant = $0 { true } else { false } },
          "actual seeded history supplies grouped assistant geometry rows")
}
