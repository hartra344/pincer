#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("UI readiness cancellation", .timeLimit(.minutes(2)))
struct UITestReadinessCancellationTests {
    @MainActor final class TaskOwner { var task: Task<Bool, Never>? }

    @Test func preCanceledAdmissionDoesNotEvaluatePredicate() async {
        var calls = 0
        let task = Task { await uiTestEventually(timeout: .milliseconds(20)) { calls += 1; return true } }
        task.cancel() // No suspension: cancel before the MainActor task can enter the loop.
        let result = await task.value
        #expect(!result && calls == 0)
    }

    @Test func cancellationAfterFirstPredicateDoesNotPollAgain() async {
        let owner = TaskOwner()
        var calls = 0
        let task = Task { await uiTestEventually(timeout: .milliseconds(20)) {
            calls += 1
            owner.task?.cancel() // Actual cancellation from the first real predicate invocation.
            return false
        } }
        owner.task = task
        defer { task.cancel(); owner.task = nil }
        let result = await task.value
        #expect(!result && calls == 1)
    }

    @Test func currentReadyAndActualProgressRemainReady() async {
        var calls = 0
        let ready = await uiTestEventually { calls += 1; return true }
        #expect(ready && calls == 1)
        calls = 0
        let progress = await uiTestEventually { calls += 1; return calls == 2 }
        #expect(progress && calls == 2)
    }
    @Test func readyPredicateCannotEscapeItsOwnCancellation() async {
        let owner = TaskOwner()
        var calls = 0
        let task = Task { await uiTestEventually {
            calls += 1; owner.task?.cancel(); return true
        } }
        owner.task = task
        defer { task.cancel(); owner.task = nil }
        let result = await task.value
        #expect(!result && calls == 1)
    }

    @Test func cancellationAtFinalGraceSleepBoundaryDoesNotReadPredicateAgain() async {
        let owner = TaskOwner()
        var calls = 0, boundaries = 0
        let task = Task {
            await UITestReadinessProbe.$beforeGraceSleep.withValue({
                boundaries += 1
                owner.task?.cancel()
            }) {
                await uiTestEventually(timeout: .zero) { calls += 1; return false }
            }
        }
        owner.task = task
        defer { task.cancel(); owner.task = nil }
        let result = await task.value
        #expect(boundaries == 1 && !result && calls == 1)
    }

}
#endif
