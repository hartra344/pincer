import Foundation

// Snapshot the synchronous operation entry before its first suspension.
private func measurementCheckRunsOffMain() -> Bool { !Thread.isMainThread }
import PincerKit

private actor MeasurementCheckGate {
    struct Value: Sendable {
        let input: Int
        let ranOffMain: Bool
    }

    private(set) var started: [Int] = []
    private var releases: [Int: (CheckedContinuation<Value, Never>, Bool)] = [:]
    private var isClosed = false

    func measure(_ input: Int, ranOffMain: Bool) async -> Value {
        if self.isClosed { return Value(input: input, ranOffMain: ranOffMain) }
        return await withCheckedContinuation { continuation in
            self.started.append(input)
            self.releases[input] = (continuation, ranOffMain)
        }
    }

    func waitForStarts(_ count: Int, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.started.count < count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func release(_ input: Int) {
        guard let (continuation, ranOffMain) = self.releases.removeValue(forKey: input) else { return }
        continuation.resume(returning: Value(input: input, ranOffMain: ranOffMain))
    }

    func releaseAll() {
        self.isClosed = true
        for (input, (continuation, ranOffMain)) in self.releases {
            continuation.resume(returning: Value(input: input, ranOffMain: ranOffMain))
        }
        self.releases.removeAll()
    }
}

@MainActor
func runLatestMeasurementChecks() async {
    let gate = MeasurementCheckGate()
    let worker = LatestMeasurementWorker<Int, MeasurementCheckGate.Value> { input in
        let ranOffMain = measurementCheckRunsOffMain()
        return await gate.measure(input, ranOffMain: ranOffMain)
    }
    var published: [MeasurementCheckGate.Value] = []
    worker.submit(1) { published.append($0) }
    let firstStarted = await gate.waitForStarts(1)
    check(firstStarted, "latest measurement starts its first operation")
    guard firstStarted else {
        await gate.releaseAll()
        return
    }

    worker.submit(2) { published.append($0) }
    worker.submit(3) { published.append($0) }
    check(worker.activeCount == 1 && worker.pendingCount == 1, "latest measurement retains one active and one pending request")
    await gate.release(1)

    let newestStarted = await gate.waitForStarts(2)
    check(newestStarted, "latest measurement drains the newest pending request")
    guard newestStarted else {
        await gate.releaseAll()
        return
    }
    let started = await gate.started
    check(started == [1, 3], "latest measurement replaces intermediate pending work")
    check(published.isEmpty, "latest measurement suppresses an obsolete result")
    await gate.release(3)

    let completed = await waitFor("latest measurement result", timeout: 3) { published.count == 1 }
    check(completed, "latest measurement publishes the final result")
    check(published.first?.input == 3 && published.first?.ranOffMain == true,
          "latest measurement runs away from the main thread and publishes the newest input")
    check(worker.activeCount == 0 && worker.pendingCount == 0, "latest measurement retires all bounded work")
    await gate.releaseAll()
}
