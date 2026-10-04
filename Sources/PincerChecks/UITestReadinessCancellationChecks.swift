#if DEBUG
import Foundation
import PincerKit

@MainActor private final class ReadinessTaskOwner { var task: Task<Bool, Never>? }

@MainActor func runUITestReadinessCancellationChecks() async {
    var calls = 0
    let preCanceled = Task { await uiTestEventually(timeout: .milliseconds(20)) { calls += 1; return true } }
    preCanceled.cancel()
    let preCanceledResult = await preCanceled.value
    check(!preCanceledResult && calls == 0, "actual readiness loop refuses pre-canceled admission without evaluating its predicate")

    calls = 0
    let owner = ReadinessTaskOwner()
    let canceled = Task { await uiTestEventually(timeout: .milliseconds(20)) {
        calls += 1; owner.task?.cancel(); return false
    } }
    owner.task = canceled
    let canceledResult = await canceled.value
    owner.task = nil
    check(!canceledResult && calls == 1, "actual readiness loop stops after its first predicate cancels the task")

    calls = 0
    let selfCancelingReady = Task { await uiTestEventually {
        calls += 1; owner.task?.cancel(); return true
    } }
    owner.task = selfCancelingReady
    let selfCancelingResult = await selfCancelingReady.value
    owner.task = nil
    check(!selfCancelingResult && calls == 1, "a ready predicate cannot bypass its own actual task cancellation")

    calls = 0
    var boundaries = 0
    let boundaryCanceled = Task {
        await UITestReadinessProbe.$beforeGraceSleep.withValue({
            boundaries += 1; owner.task?.cancel()
        }) {
            await uiTestEventually(timeout: .zero) { calls += 1; return false }
        }
    }
    owner.task = boundaryCanceled
    let boundaryResult = await boundaryCanceled.value
    owner.task = nil
    check(boundaries == 1 && !boundaryResult && calls == 1,
          "actual final grace sleep catches cancellation at its observed sleep boundary")

    calls = 0
    let ready = await uiTestEventually { calls += 1; return true }
    check(ready && calls == 1, "current ready predicate completes normally")
    calls = 0
    let progress = await uiTestEventually { calls += 1; return calls == 2 }
    check(progress && calls == 2, "actual current predicate progress remains ready without a fixed-delay success")
}
#endif
