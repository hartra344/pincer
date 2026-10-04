import Foundation
@testable import PincerKit

@MainActor
func runPremeasureMetadataChecks() {
    let descriptors = BoundedMetadataFIFO<Int>(limit: 64)
    for id in 0..<64 { _ = descriptors.append(id) }
    check(descriptors.count == 64 && !descriptors.append(64), "actual worker descriptor FIFO rejects overflow")
    descriptors.removeAll { $0 < 32 }
    check(descriptors.count == 32 && descriptors.popFirst() == 32 && descriptors.append(64),
          "actual descriptor cancellation releases admission and preserves FIFO order")
}

@MainActor
func runDemoPremeasureMetadataChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:garden"
    guard await waitFor("premeasure source Demo", timeout: 25, { gateway.state.isConnected && gateway.sessions[key] != nil }) else {
        check(false, "actual premeasure source Demo connects"); return
    }
    let chat = gateway.chat(for: key)
    await chat.load()
    let items = chat.items
    let sources = await Task.detached {
        TranscriptBuilder.build(items).compactMap { entry -> String? in
            switch entry {
            case let .user(item):
                let text = item.plainText
                return text.isEmpty ? nil : text
            case let .assistant(turn):
                let text = turn.text.joined(separator: "\n\n")
                return turn.isStreaming || text.isEmpty ? nil : text
            default: return nil
            }
        }
    }.value
    check(sources.count >= 2 && sources.allSatisfy { !$0.isEmpty },
          "actual seeded transcript retains exact user and committed assistant premeasure sources")
    runPremeasureMetadataChecks()
}
