import Foundation

/// A reusable async gate for checks: `hold()` parks the caller until `release()`.
/// By default a cancelled holder releases the gate (and resumes every waiter);
/// pass `releasesOnCancel: false` for gates that must keep holding across cancellation.
@MainActor class CheckGate {
    var entered = false
    private(set) var enteredCount = 0
    private(set) var isReleased = false
    private let releasesOnCancel: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(releasesOnCancel: Bool = true) { self.releasesOnCancel = releasesOnCancel }

    func hold() async {
        entered = true
        enteredCount += 1
        guard releasesOnCancel else {
            await withCheckedContinuation { park($0, honorsCancellation: false) }
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { park($0, honorsCancellation: true) }
        } onCancel: { Task { @MainActor in self.release() } }
    }

    func holdThrowing() async throws {
        await hold()
        try Task.checkCancellation()
    }

    func release() {
        isReleased = true
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>, honorsCancellation: Bool) {
        if isReleased || (honorsCancellation && Task.isCancelled) { continuation.resume() } else { waiters.append(continuation) }
    }
}

/// A `CheckGate` per key: `hold(key)` parks until `release(key)` or `release()` (all keys).
/// A cancelled holder releases every key, matching `CheckGate`'s default.
@MainActor class KeyedCheckGate<Key: Hashable> {
    private(set) var entered: Set<Key> = []
    private(set) var isReleased = false
    private var releasedKeys: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ key: Key) async {
        entered.insert(key)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isReleased || releasedKeys.contains(key) || Task.isCancelled { continuation.resume() }
                else { waiters[key, default: []].append(continuation) }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }

    func release(_ key: Key) {
        releasedKeys.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
    }

    func release() {
        isReleased = true
        let parked = waiters.values.joined()
        waiters = [:]
        for waiter in parked { waiter.resume() }
    }
}

@MainActor func checkCheckGate() async {
    let early = CheckGate()
    early.release()
    await early.hold()
    check(early.isReleased && early.entered && early.enteredCount == 1, "CheckGate: hold after release returns immediately")

    let gate = CheckGate()
    var resumed = 0
    let first = Task { @MainActor in await gate.hold(); resumed += 1 }
    let second = Task { @MainActor in await gate.hold(); resumed += 1 }
    let entered = await waitFor("CheckGate waiters parked") { gate.enteredCount == 2 }
    check(entered && resumed == 0 && !gate.isReleased, "CheckGate: holders park and set entered until released")
    gate.release()
    await first.value
    await second.value
    check(resumed == 2 && gate.isReleased, "CheckGate: release resumes every waiter")

    let cancelling = CheckGate()
    let holder = Task { @MainActor in await cancelling.hold() }
    _ = await waitFor("CheckGate cancel holder parked") { cancelling.entered }
    holder.cancel()
    await holder.value
    check(cancelling.isReleased, "CheckGate: cancelling a holder releases the gate")

    let keeping = CheckGate(releasesOnCancel: false)
    let kept = Task { @MainActor in await keeping.hold() }
    _ = await waitFor("CheckGate non-releasing holder parked") { keeping.entered }
    kept.cancel()
    try? await Task.sleep(for: .milliseconds(50))
    check(!keeping.isReleased, "CheckGate: releasesOnCancel false keeps holding across cancellation")
    keeping.release()
    await kept.value

    let throwing = CheckGate()
    let thrower = Task { @MainActor () -> Bool in
        do { try await throwing.holdThrowing(); return false } catch is CancellationError { return true } catch { return false }
    }
    _ = await waitFor("CheckGate throwing holder parked") { throwing.entered }
    thrower.cancel()
    let threw = await thrower.value
    check(threw, "CheckGate: holdThrowing throws CancellationError when cancelled")

    let keyed = KeyedCheckGate<String>()
    var keyedResumed: [String] = []
    let alpha = Task { @MainActor in await keyed.hold("a"); keyedResumed.append("a") }
    let beta = Task { @MainActor in await keyed.hold("b"); keyedResumed.append("b") }
    let keyedParked = await waitFor("KeyedCheckGate holders parked") { keyed.entered == ["a", "b"] }
    check(keyedParked && keyedResumed.isEmpty && !keyed.isReleased, "KeyedCheckGate: holders park and record their keys")
    keyed.release("a")
    await alpha.value
    check(keyedResumed == ["a"], "KeyedCheckGate: release(key) resumes only that key")
    await keyed.hold("a")
    keyed.release()
    await beta.value
    check(keyedResumed == ["a", "b"] && keyed.isReleased, "KeyedCheckGate: release() resumes every key and keyed early release returns immediately")
    await keyed.hold("late")
    check(keyed.entered.contains("late"), "KeyedCheckGate: hold after release returns immediately")

    let keyedCancelling = KeyedCheckGate<String>()
    let keyedHolder = Task { @MainActor in await keyedCancelling.hold("x") }
    _ = await waitFor("KeyedCheckGate cancel holder parked") { keyedCancelling.entered.contains("x") }
    keyedHolder.cancel()
    await keyedHolder.value
    check(keyedCancelling.isReleased, "KeyedCheckGate: cancelling a holder releases every key")
}
