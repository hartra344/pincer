import Foundation

/// Single-consumer ordered event queue. Never drops. When the newest queued element has the same non-nil
/// `replaceKey` as a newly yielded one, the new element replaces it in place (tail-only coalescing, so order vs
/// every other event is preserved). Lifecycle / approval / terminal / incremental events have nil key.
final class CoalescingEventBuffer<Element: Sendable>: @unchecked Sendable, AsyncSequence {
    private struct Entry {
        var element: Element
        var key: String?
    }

    private let lock = NSLock()
    private let replaceKey: @Sendable (Element) -> String?
    private var queue: [Entry] = []
    private var head = 0
    private var finished = false
    private var waiter: CheckedContinuation<Element?, Never>?
    private var coalesced = 0

    init(replaceKey: @escaping @Sendable (Element) -> String?) {
        self.replaceKey = replaceKey
    }

    func yield(_ element: Element) {
        let key = self.replaceKey(element)
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        if let waiter = self.waiter {
            self.waiter = nil
            self.lock.unlock()
            waiter.resume(returning: element)
            return
        }
        if let key, self.queue.count > self.head, self.queue[self.queue.count - 1].key == key {
            self.queue[self.queue.count - 1].element = element
            self.coalesced += 1
        } else {
            self.queue.append(Entry(element: element, key: key))
        }
        self.lock.unlock()
    }

    func finish() {
        self.lock.lock()
        self.finished = true
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume(returning: nil)
    }

    var pendingCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.queue.count - self.head
    }

    var coalescedCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.coalesced
    }

    private func next() async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                self.lock.lock()
                if self.queue.count > self.head {
                    let element = self.queue[self.head].element
                    self.head += 1
                    if self.head == self.queue.count {
                        self.queue.removeAll(keepingCapacity: true)
                        self.head = 0
                    }
                    self.lock.unlock()
                    continuation.resume(returning: element)
                } else if self.finished || Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    self.waiter = continuation
                    self.lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            self.lock.unlock()
            waiter?.resume(returning: nil)
        }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let buffer: CoalescingEventBuffer<Element>
        mutating func next() async -> Element? { await self.buffer.next() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(buffer: self) }
}

extension GatewayEvent {
    /// Non-nil only for replaceable snapshots: a chat delta carrying a cumulative `message` object, or
    /// `deltaText` with `replace == true`. Plain `deltaText` deltas are incremental and never coalesce.
    var coalescingKey: String? {
        guard self.name == "chat", self.payload["state"]?.string == "delta",
              let runId = self.payload["runId"]?.text else { return nil }
        let cumulative = self.payload["message"]?.object != nil
            || (self.payload["deltaText"]?.string != nil && self.payload["replace"]?.bool == true)
        guard cumulative else { return nil }
        let session = self.payload["sessionKey"]?.string ?? ""
        return "chat|\(session)|\(runId)"
    }
}
