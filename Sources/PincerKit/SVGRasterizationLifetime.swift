import Foundation

/// A one-shot lifetime gate shared by the SVG WebKit renderer and its offline checks.
@MainActor
package final class SVGRasterizationLifetime {
    package enum Outcome: Equatable {
        case completed
        case failed
        case timedOut
        case cancelled
    }

    package typealias DeadlineScheduler = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    private let onTermination: @MainActor (Outcome) -> Void
    private var cancelDeadline: (@MainActor () -> Void)?
    package private(set) var outcome: Outcome?

    package init(
        scheduleDeadline: DeadlineScheduler,
        onTermination: @escaping @MainActor (Outcome) -> Void
    ) {
        self.onTermination = onTermination
        let cancel = scheduleDeadline { [weak self] in
            _ = self?.finish(.timedOut)
        }
        if self.outcome != nil {
            cancel()
        } else {
            self.cancelDeadline = cancel
        }
    }

    @discardableResult
    package func finish(_ outcome: Outcome) -> Bool {
        guard self.outcome == nil else { return false }
        self.outcome = outcome
        let cancel = self.cancelDeadline
        self.cancelDeadline = nil
        cancel?()
        self.onTermination(outcome)
        return true
    }
}
