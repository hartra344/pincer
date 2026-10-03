import Testing
@testable import PincerKit

@MainActor
struct SVGRasterizationLifetimeTests {
    @MainActor
    private final class ManualDeadline {
        var fire: (@MainActor () -> Void)?
        var cancelCount = 0
        var firesDuringScheduling = false

        func schedule(_ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            self.fire = fire
            if self.firesDuringScheduling { fire() }
            return { [weak self] in self?.cancelCount += 1 }
        }
    }

    @Test func deadlineTerminatesOnceAndRejectsLateWebKitCallbacks() {
        let timer = ManualDeadline()
        var outcomes: [SVGRasterizationLifetime.Outcome] = []
        let lifetime = SVGRasterizationLifetime(
            scheduleDeadline: { timer.schedule($0) },
            onTermination: { outcomes.append($0) })

        timer.fire?()

        #expect(lifetime.outcome == .timedOut)
        #expect(outcomes == [.timedOut])
        #expect(timer.cancelCount == 1)
        #expect(!lifetime.finish(.completed))
        #expect(!lifetime.finish(.failed))
        timer.fire?()
        #expect(outcomes == [.timedOut], "late navigation and snapshot callbacks cannot resume twice")
        #expect(timer.cancelCount == 1)
    }

    @Test func successfulRenderCancelsItsDeadlineAndIgnoresLateExpiry() {
        let timer = ManualDeadline()
        var outcomes: [SVGRasterizationLifetime.Outcome] = []
        let lifetime = SVGRasterizationLifetime(
            scheduleDeadline: { timer.schedule($0) },
            onTermination: { outcomes.append($0) })

        #expect(lifetime.finish(.completed))
        timer.fire?()

        #expect(lifetime.outcome == .completed)
        #expect(outcomes == [.completed])
        #expect(timer.cancelCount == 1)
    }

    @Test func callerCancellationHasItsOwnTerminalOutcome() {
        let timer = ManualDeadline()
        var outcomes: [SVGRasterizationLifetime.Outcome] = []
        let lifetime = SVGRasterizationLifetime(
            scheduleDeadline: { timer.schedule($0) },
            onTermination: { outcomes.append($0) })

        #expect(lifetime.finish(.cancelled))
        #expect(!lifetime.finish(.timedOut))
        #expect(outcomes == [.cancelled])
        #expect(timer.cancelCount == 1)
    }

    @Test func terminationCallbackCanReenterWithoutCompletingTwice() {
        let timer = ManualDeadline()
        var reentrantResult: Bool?
        var lifetime: SVGRasterizationLifetime?
        lifetime = SVGRasterizationLifetime(
            scheduleDeadline: { timer.schedule($0) },
            onTermination: { _ in reentrantResult = lifetime?.finish(.failed) })

        #expect(lifetime?.finish(.completed) == true)
        #expect(reentrantResult == false)
        #expect(timer.cancelCount == 1)
    }

    @Test func immediateDeadlineDeliveryCancelsTheReturnedToken() {
        let timer = ManualDeadline()
        timer.firesDuringScheduling = true
        var outcomes: [SVGRasterizationLifetime.Outcome] = []
        let lifetime = SVGRasterizationLifetime(
            scheduleDeadline: { timer.schedule($0) },
            onTermination: { outcomes.append($0) })

        #expect(lifetime.outcome == .timedOut)
        #expect(outcomes == [.timedOut])
        #expect(timer.cancelCount == 1)
        #expect(!lifetime.finish(.completed))
    }
}
