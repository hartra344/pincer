#if DEBUG
import Foundation

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
