import Foundation

/// Holds the demo gateway's response for one RPC method at the delivery boundary (via
/// `setDemoResponseDelivery`) until `release()`. A cancelled holder releases the gate.
actor MethodDeliveryGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let method: String

    init(method: String) { self.method = method }

    func hold(_ method: String) async {
        guard method == self.method else { return }
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { await self.release() } }
    }

    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor func checkMethodDeliveryGate() async {
    let gate = MethodDeliveryGate(method: "chat.send")
    await gate.hold("other.method")
    let passedThrough = !(await gate.entered)
    check(passedThrough, "MethodDeliveryGate: other methods pass through without entering")
    let holder = Task { await gate.hold("chat.send") }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
    let parked = await gate.entered
    check(parked, "MethodDeliveryGate: the matching method parks and reports entry")
    holder.cancel()
    await holder.value
    await gate.hold("chat.send")
    check(true, "MethodDeliveryGate: a cancelled holder releases the gate for later callers")
}
