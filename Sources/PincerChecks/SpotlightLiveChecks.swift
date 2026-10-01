import Foundation
import PincerKit

/// Runs against a fresh mock Gateway; the public fake keeps checks out of Core Spotlight.
@MainActor
func runLiveSpotlightChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let profile = GatewayProfile(name: "Search check", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    let indexer = FakeSpotlightIndexer()
    gateway.spotlightIndexer = indexer
    defer {
        gateway.stop()
        SpotlightCenter.shared.forgetGateway(gateway.id)
        defaults.removePersistentDomain(forName: suite)
    }

    gateway.start()
    guard await waitFor("Spotlight mock connection", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }) else {
        check(false, "normal mock profile connects for Spotlight reindex")
        return
    }
    await gateway.reindexSpotlight()
    let indexed = indexer.entries
    check(!indexed.isEmpty && indexed.allSatisfy { $0.contentDescription == profile.name },
          "actual Spotlight reindex includes the Gateway name and no message text by default")
    check(indexed.allSatisfy { $0.snippet == nil }, "actual default Spotlight reindex contains no snippets")
}
