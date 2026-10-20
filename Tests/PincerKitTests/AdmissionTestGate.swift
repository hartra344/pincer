import Foundation
import Testing

/// Holds an already computed result at a delivery boundary. Cancellation of either side releases it.
@MainActor final class AdmissionTestGate {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?

    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                entry?.resume(); entry = nil
                if released || Task.isCancelled { continuation.resume() }
                else { delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }

    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered || Task.isCancelled { continuation.resume() }
                else { entry = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        entry?.resume(); entry = nil
        delivery?.resume(); delivery = nil
    }
}

@MainActor
@Suite("AdmissionTestGate")
struct AdmissionTestGateTests {
    @Test(.timeLimit(.minutes(1))) func holdParksUntilRelease() async throws {
        let gate = AdmissionTestGate()
        var resumed = false
        let holder = Task { @MainActor in await gate.hold(); resumed = true }
        try await gate.waitForEntry()
        await Task.yield()
        #expect(!resumed)
        gate.release()
        await holder.value
        #expect(resumed)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingHolderReleasesGate() async throws {
        let gate = AdmissionTestGate()
        let holder = Task { @MainActor in await gate.hold() }
        try await gate.waitForEntry()
        holder.cancel()
        await holder.value
        await gate.hold() // already released: returns immediately
    }
}
