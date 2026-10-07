import Foundation
import Synchronization

/// Coalesces a stream of progress values so a consumer that must hop to another actor (the
/// main actor, for UI) does so at most once per `interval`, not once per value.
///
/// The first value, any value for which `isTransition` holds against the last one published
/// (a change the UI depends on, such as building to ready), and `finish` are delivered at once.
/// Everything else inside the interval is held and replaced by the newer value; `finish`
/// delivers the held one. Runs wherever `submit` is called; the throttle itself never hops.
public final class ProgressThrottle<Value: Sendable>: Sendable {
    private struct State {
        var lastPublished: Value?
        var lastTime: TimeInterval?
        var held: Value?
    }

    private let interval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let isTransition: @Sendable (Value, Value) -> Bool
    private let publish: @Sendable (Value) async -> Void
    private let state = Mutex(State())

    /// ~150 ms: about 7 updates a second reads as live progress for a "Indexing 12 of 300"
    /// label while the per-chat work (read, decode, index) takes tens of milliseconds each.
    public static var defaultInterval: TimeInterval { 0.15 }

    public init(interval: TimeInterval = ProgressThrottle.defaultInterval,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                isTransition: @escaping @Sendable (Value, Value) -> Bool,
                publish: @escaping @Sendable (Value) async -> Void)
    {
        self.interval = interval
        self.clock = clock
        self.isTransition = isTransition
        self.publish = publish
    }

    public func submit(_ value: Value) async {
        let now = self.clock()
        let send: Bool = self.state.withLock { state in
            let due = state.lastTime.map { now - $0 >= self.interval } ?? true
            let transition = state.lastPublished.map { self.isTransition($0, value) } ?? true
            guard due || transition else {
                state.held = value
                return false
            }
            state.lastPublished = value
            state.lastTime = now
            state.held = nil
            return true
        }
        if send { await self.publish(value) }
    }

    /// Delivers `value` as the last one, whatever was held.
    public func finish(_ value: Value) async {
        self.state.withLock { state in
            state.lastPublished = value
            state.lastTime = self.clock()
            state.held = nil
        }
        await self.publish(value)
    }
}

extension ProgressThrottle where Value == MessageIndex.Status {
    /// Publishes every change of case (building, ready, unavailable); counts within `building` are throttled.
    public convenience init(interval: TimeInterval = ProgressThrottle.defaultInterval,
                            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            publish: @escaping @Sendable (MessageIndex.Status) async -> Void)
    {
        self.init(interval: interval, clock: clock, isTransition: { old, new in
            switch (old, new) {
            case (.building, .building): false
            default: old != new
            }
        }, publish: publish)
    }
}
