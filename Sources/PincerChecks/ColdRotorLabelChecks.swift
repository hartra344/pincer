import Foundation
@testable import PincerKit

@MainActor
func runColdRotorLabelChecks() async {
    let fixture = await Task.detached {
        (body: "a" + String(repeating: "\u{301}", count: 10_000),
         author: String(repeating: "Author", count: 100))
    }.value
    let opening = ColdRotorTextOpening.capture(blocks: [.text("First"), .text("Second")])
    check(opening.text == "First\n\nSecond", "actual cold rotor opening preserves distinct source paragraphs")
    let giant = ColdRotorTextOpening.capture(text: fixture.body)
    check(giant.inspectedBytes == 400 && giant.text.utf8.count <= 400 && !giant.text.contains("�"),
          "actual cold rotor opening bounds a giant grapheme and cuts complete scalars")
    check(ColdRotorTextOpening.author(fixture.author).inspectedBytes == 128,
          "actual cold rotor author is bounded before speaker formatting")
}

@MainActor
func runDemoColdRotorLabelChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("cold rotor Demo", timeout: 25, {
        gateway.state.isConnected && gateway.sessions["agent:main:dashboard:trip"] != nil
    }) else { check(false, "actual cold rotor Demo connects"); return }
    let chat = gateway.chat(for: "agent:main:dashboard:trip")
    await chat.load()
    var meaningful = 0
    for entry in chat.entries {
        let result: ColdRotorTextOpening.Capture
        switch entry {
        case let .user(item): result = ColdRotorTextOpening.capture(blocks: item.blocks)
        case let .assistant(turn): result = ColdRotorTextOpening.capture(text: turn.text.first ?? "")
        case .marker: continue
        }
        if !result.text.isEmpty { meaningful += 1 }
        check(result.inspectedBytes <= 400 && result.visitedBlocks <= 64,
              "actual seeded rotor source uses the bounded production opening")
    }
    check(meaningful > 0, "actual seeded cold rotor opening retains useful source text")
}
