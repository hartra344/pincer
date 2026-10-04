#if DEBUG
import Foundation

/// Per-model, bounded scalar observation of the real filter and text-match boundaries.
package final class ToolsInspectorSearchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0, mainFilters = 0, workerFilters = 0, mainMatches = 0, workerMatches = 0
    package init() {}
    func record(match: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard events < 128 else { return }
        events += 1
        if match {
            if Thread.isMainThread { mainMatches += 1 } else { workerMatches += 1 }
        } else {
            if Thread.isMainThread { mainFilters += 1 } else { workerFilters += 1 }
        }
    }
    package func snapshot() -> (mainFilters: Int, workerFilters: Int, mainMatches: Int, workerMatches: Int) {
        lock.lock(); defer { lock.unlock() }
        return (mainFilters, workerFilters, mainMatches, workerMatches)
    }
}
#endif
