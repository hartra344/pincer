#if DEBUG
import Foundation
import Synchronization

package final class EmbeddedImageBase64Probe: Sendable {
    private let counts = Mutex((main: 0, worker: 0))
    package init() {}
    func record() {
        counts.withLock {
            guard $0.main + $0.worker < 32 else { return }
            if Thread.isMainThread { $0.main += 1 } else { $0.worker += 1 }
        }
    }
    package func snapshot() -> (main: Int, worker: Int) { counts.withLock { $0 } }
}
#endif
