#if DEBUG
import Foundation

/// Default-nil, task-owned observation of the actual final sleep boundary.
package enum UITestReadinessProbe {
    @TaskLocal package static var beforeGraceSleep: (@MainActor @Sendable () -> Void)?
}

/// The actual UI test readiness loop, shared with standalone infrastructure checks.
@MainActor
package func uiTestEventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        guard !Task.isCancelled else { return false }
        let ready = condition()
        guard !Task.isCancelled else { return false }
        if ready { return true }
        if ContinuousClock.now >= deadline {
            guard !Task.isCancelled else { return false }
            UITestReadinessProbe.beforeGraceSleep?()
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
            guard !Task.isCancelled else { return false }
            let finalReady = condition()
            return !Task.isCancelled && finalReady
        }
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch { return false }
        guard !Task.isCancelled else { return false }
    }
}
#endif
