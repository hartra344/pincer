import Foundation
@testable import PincerKit

@MainActor
func runColdTranscriptHeightEstimateChecks() async {
    let item = await Task.detached {
        ChatItem(id: "cold-estimate-source", role: .user,
                 blocks: [.text("First paragraph"), .text("Second paragraph")])
    }.value
    let footprint = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: 30)
    check(footprint.lines == 3 && footprint.inspectedBytes == 31 && !footprint.incomplete,
          "actual shared cold footprint preserves distinct paragraphs without joining")
    let bounded = await Task.detached { [ContentBlock.text(String(repeating: "Text\n", count: 100_000))] }.value
    let large = ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: bounded)), charactersPerLine: 30)
    check(large.inspectedBytes == ColdTranscriptFootprint.byteLimit && large.metadataVisits <= 64 && large.incomplete,
          "actual shared cold footprint caps input and supplies an incomplete-content allowance")
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
    if let user = chat.entries.first(where: { if case .user = $0 { true } else { false } }),
       let assistant = chat.entries.first(where: { if case .assistant = $0 { true } else { false } }) {
        for entry in [user, assistant] {
            let narrow = ColdTranscriptFootprint.estimate(entry, charactersPerLine: 20)
            let wide = ColdTranscriptFootprint.estimate(entry, charactersPerLine: 70)
            check(narrow.lines.isFinite && narrow.lines >= wide.lines && narrow.inspectedBytes <= 16 * 1024 && narrow.metadataVisits <= 64,
                  "actual seeded row uses the same bounded production footprint with width sensitivity")
        }
    }
}
