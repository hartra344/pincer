import Foundation
@testable import PincerKit

#if DEBUG
private actor FindQueueCheckGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold(_ ordinal: Int) async {
        guard ordinal == 1 else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released { continuation.resume() } else { self.waiter = continuation }
            }
        } onCancel: { Task { await self.release() } }
    }
    func release() { self.released = true; self.waiter?.resume(); self.waiter = nil }
}

@MainActor
private final class FindQueueCompletion { var finished = false }

@MainActor
func runTranscriptFindWorkerQueueChecks() async {
    let entries: [TranscriptEntry] = (0..<3).map {
        .user(ChatItem(id: "queue-\($0)", role: .user, blocks: [.text("needle ordinary message")], timestamp: Date(timeIntervalSince1970: 1)))
    }
    let preparation = TranscriptFindPreparation()
    let gate = FindQueueCheckGate()
    let probe = TranscriptFindWorkerProbe { await gate.hold($0) }
    preparation.probe = probe
    let first = Task { await preparation.prepare(query: "needle", entries: entries, options: .init()) }
    let entered = await waitFor("Find queue first worker", timeout: 25) { probe.snapshot.entered == 1 }
    check(entered, "queue control holds an actual matcher")
    guard entered else { first.cancel(); await gate.release(); _ = await first.value; return }
    let replacedCompletion = FindQueueCompletion()
    let replaced = Task {
        let result = await preparation.prepare(query: "ordinary", entries: entries, options: .init())
        replacedCompletion.finished = true
        return result
    }
    let admitted = await waitFor("Find queue second decision", timeout: 25) { probe.snapshot.requested == 2 }
    check(admitted, "second actual request is admitted while first worker remains held")
    guard admitted else {
        first.cancel(); replaced.cancel(); await gate.release()
        _ = await first.value; _ = await replaced.value
        return
    }
    let latest = Task { await preparation.prepare(query: "message", entries: entries, options: .init()) }
    let finished = await waitFor("superseded Find completion", timeout: 25) { replacedCompletion.finished }
    check(finished, "superseded request actually completes before reading its result")
    guard finished else {
        first.cancel(); replaced.cancel(); latest.cancel(); await gate.release()
        _ = await first.value; _ = await replaced.value; _ = await latest.value
        return
    }
    let superseded = await replaced.value
    check(superseded.status == .superseded, "replaced pending request has an explicit non-success status")
    check(probe.snapshot.entered == 1 && probe.snapshot.maximumLeases == 1, "latest replacement does not create another worker")
    await gate.release()
    let old = await first.value
    let current = await latest.value
    check(old.status == .completed && current.status == .completed
          && current.matches == entries.map { .init(entryId: $0.id, section: .message(0), occurrence: 0) },
          "only accepted first and latest requests produce exact completed matches")
    check(probe.snapshot.completed == 2 && probe.snapshot.leases == 0 && probe.snapshot.mainEntries == 0,
          "queue control drains real workers off-main before cleanup")
}
#endif
