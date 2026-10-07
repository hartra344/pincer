import Foundation
import PincerKit
import Synchronization

/// The message-index progress throttle: bounded main-actor hops, transitions and the final value kept.
@MainActor
func runProgressThrottleChecks() async {
    let published = Mutex<[MessageIndex.Status]>([])
    let time = Mutex<TimeInterval>(0)
    let throttle = ProgressThrottle<MessageIndex.Status>(interval: 0.15, clock: { time.withLock { $0 } }) { status in
        published.withLock { $0.append(status) }
    }
    for n in 0..<300 {
        await throttle.submit(.building(done: n, total: 300))
        time.withLock { $0 += 0.001 }
    }
    await throttle.submit(.ready)
    let values = published.withLock { $0 }
    check(values.count < 10, "throttle: 300 statuses make a bounded number of publications (\(values.count))")
    check(values.first == .building(done: 0, total: 300), "throttle: the first status is published at once")
    check(values.last == .ready, "throttle: the final status is delivered")
}
