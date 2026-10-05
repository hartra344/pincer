#if DEBUG
import Foundation

/// Fixture-only exactly-once signal. Cancellation never releases held worker work.
private final class WorkerTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation { pending in
            let ready = lock.withLock { () -> Bool? in
                if let result { return result }
                precondition(continuation == nil, "one waiter per fixture signal")
                continuation = pending
                return nil
            }
            if let ready { pending.resume(returning: ready) }
        }
    }
    func finish(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }
            result = value
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: value)
    }
}

/// One held worker, released only by explicit fixture open (including failure cleanup).
/// Entry observation may be cancelled/timed out independently without releasing that worker.
package final class ExplicitWorkerTestGate: @unchecked Sendable {
    private let entered = WorkerTestSignal()
    private let released = WorkerTestSignal()

    package init() {}
    package func hold() async {
        entered.finish(true)
        _ = await released.wait()
    }
    package func open() { released.finish(true) }
    package func waitUntilEntered(timeout: TimeInterval = 3) async -> Bool {
        let signal = entered
        let action: @Sendable () -> Void = { signal.finish(false) }
        let expiry = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            await signal.wait()
        } onCancel: { signal.finish(false) }
    }
}
#endif
