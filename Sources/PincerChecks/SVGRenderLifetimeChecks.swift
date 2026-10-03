import PincerKit

@MainActor
func runSVGRenderLifetimeChecks() {
    var deadline: (@MainActor () -> Void)?
    var cancellations = 0
    var outcomes: [SVGRasterizationLifetime.Outcome] = []
    let stalled = SVGRasterizationLifetime(scheduleDeadline: { fire in
        deadline = fire
        return { cancellations += 1 }
    }, onTermination: { outcomes.append($0) })
    deadline?()
    check(outcomes == [.timedOut] && cancellations == 1,
          "a stalled SVG render terminates and releases its deadline")
    check(!stalled.finish(.completed) && !stalled.finish(.failed)
          && outcomes == [.timedOut] && cancellations == 1,
          "late WebKit replies cannot complete or clean up a timed-out render twice")

    deadline = nil
    cancellations = 0
    outcomes = []
    let successful = SVGRasterizationLifetime(scheduleDeadline: { fire in
        deadline = fire
        return { cancellations += 1 }
    }, onTermination: { outcomes.append($0) })
    check(successful.finish(.completed), "a completed SVG render finishes")
    deadline?()
    check(outcomes == [.completed] && cancellations == 1,
          "a completed SVG render ignores an already-enqueued deadline")

    cancellations = 0
    outcomes = []
    let cancelled = SVGRasterizationLifetime(scheduleDeadline: { _ in
        { cancellations += 1 }
    }, onTermination: { outcomes.append($0) })
    check(cancelled.finish(.cancelled) && !cancelled.finish(.completed)
          && outcomes == [.cancelled] && cancellations == 1,
          "caller cancellation releases an SVG render once and rejects its late image")

    cancellations = 0
    outcomes = []
    let immediate = SVGRasterizationLifetime(scheduleDeadline: { fire in
        fire()
        return { cancellations += 1 }
    }, onTermination: { outcomes.append($0) })
    check(outcomes == [.timedOut] && cancellations == 1 && !immediate.finish(.completed),
          "an immediately-expired SVG deadline still releases the returned timer token")
}
