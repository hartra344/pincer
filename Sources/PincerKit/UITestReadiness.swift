#if DEBUG
import Foundation

/// The actual UI test readiness loop, shared with standalone infrastructure checks.
@MainActor
package func uiTestEventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            try? await Task.sleep(for: .milliseconds(50))
            return condition()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
#endif
