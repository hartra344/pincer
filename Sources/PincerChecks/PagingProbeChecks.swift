import Foundation
@testable import PincerKit

/// A warm registered transcript must not become the store used by a cold latest-page probe.
@MainActor
func runPagingProbeChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    let key = "agent:main:dashboard:trip"
    let resident = gateway.chat(for: key)
    resident.items = (0..<302).map { index in
        var item = ChatItem(id: "resident-\(index)", role: .user, blocks: [.text("resident row \(index)")])
        item.transcriptId = item.id
        return item
    }
    resident.hasLoaded = true
    resident.hasMoreHistory = true

    let probe = pagingProbe(gateway: gateway, key: key)
    check(probe !== resident, "paged history probe doesn't reuse the registered warm chat")
    check(probe.headless && probe.cacheRoot == nil && probe.items.isEmpty && !probe.hasLoaded,
          "paged history probe starts as an empty, uncached headless store")
}
