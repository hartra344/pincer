import Foundation
import PincerKit

/// Exercises the real demo session.message path on a populated, uncapped transcript.
@MainActor
func runDemoCappedRecoveryBudget() async {
#if DEBUG
    await withCacheEnvironment("off") {
        let (defaults, suite) = scratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.start()
        gateway.reconnectIfNeeded()
        defer {
            gateway.stop()
            defaults.removePersistentDomain(forName: suite)
        }

        let key = "agent:main:dashboard:lab-migration"
        let connected = await waitFor("isolated capped-recovery demo connection") {
            gateway.state.isConnected && gateway.sessions[key] != nil
        }
        check(connected, "capped recovery demo: fresh cache-off Gateway connects to the seeded long chat")
        guard connected else { return }

        let chat = gateway.chat(for: key)
        await chat.load()
        let loaded = await waitFor("isolated long-chat history", timeout: 20) { chat.hasLoaded && chat.items.count >= 60 }
        check(loaded, "capped recovery demo: load the seeded long transcript through the normal history path")
        guard loaded else { return }

        let isUncapped = !chat.items.contains(where: \.isCapped)
        check(isUncapped, "capped recovery demo: the seeded long transcript has no capped rows")
        guard isUncapped else { return }

        let prompt = "Please confirm the next maintenance step."
        let previousCount = chat.items.count
        chat.resetCappedRecoveryRowsVisitedForTesting()
        guard let runId = await chat.send(prompt) else {
            check(false, "capped recovery demo: the populated chat accepts a normal message")
            return
        }
        let delivered = await waitFor("demo recovery scan message", timeout: 20) {
            let items = chat.items
            let userCommitted = items.contains { $0.role == .user && !$0.isPending && $0.plainText == prompt }
            let replyCommitted = items.contains { $0.role == .assistant && $0.runId == runId }
            return items.count >= previousCount + 2 && userCommitted && replyCommitted && !chat.isRunning
        }
        let inspected = chat.acceptedEventRecoveryRowsVisitedForTesting
        check(delivered, "capped recovery demo: real user and assistant session messages arrive")
        check(inspected == 0,
              "capped recovery demo: uncapped accepted events avoid unrelated-row recovery scans (visited \(inspected))")
    }
#endif
}
