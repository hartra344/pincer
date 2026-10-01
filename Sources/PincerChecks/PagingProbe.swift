import Foundation
@testable import PincerKit

/// The live paging assertions need a cold store, even after prefetch or other checks opened it.
@MainActor
func pagingProbe(gateway: GatewayStore, key: String) -> ChatStore {
    // Do not register with the Gateway: reconnects and finished prefetch fills operate on its
    // resident UI stores. A nil cache root and headless mode also prevent restore and backfill.
    let probe = ChatStore(sessionKey: key, agentId: gateway.sessions[key]?.agentId, gateway: gateway, headless: true)
    probe.cacheRoot = nil
    return probe
}
