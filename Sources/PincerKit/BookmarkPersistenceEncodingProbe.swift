#if DEBUG
import Foundation

/// Per-store scalar observation of the actual full local persistence encoder, without source data.
package final class BookmarkPersistenceEncodingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var worker = 0
    package init() {}
    package func record() {
        let onMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        guard main + worker < 32 else { return }
        if onMain { main += 1 } else { worker += 1 }
    }
    package func snapshot() -> (main: Int, worker: Int) {
        lock.lock(); defer { lock.unlock() }
        return (main, worker)
    }
}
#endif
