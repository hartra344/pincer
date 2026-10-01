import Foundation
@testable import PincerKit

/// The live paging assertions need a cold store, even after prefetch or other checks opened it.
@MainActor
func pagingProbe(gateway: GatewayStore, key: String) -> ChatStore {
    gateway.chat(for: key)
}
