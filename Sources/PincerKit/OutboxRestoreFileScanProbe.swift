#if DEBUG
import Foundation

/// Owned, payload-free observation of actual restore-time attachment filesystem validation.
package final class OutboxRestoreFileScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0, worker = 0
    package init() {}
    package func record(onMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard main + worker < 32 else { return }
        if onMain { main += 1 } else { worker += 1 }
    }
    package func counts() -> (main: Int, worker: Int) {
        lock.lock(); defer { lock.unlock() }
        return (main, worker)
    }
}
#endif
