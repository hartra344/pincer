import Foundation
import Synchronization
import Testing
@testable import PincerKit

@Suite("Progress throttle")
struct ProgressThrottleTests {
    final class Recorder: Sendable {
        let values = Mutex<[MessageIndex.Status]>([])
        let time = Mutex<TimeInterval>(0)
        func advance(_ dt: TimeInterval) { self.time.withLock { $0 += dt } }
        var now: TimeInterval { self.time.withLock { $0 } }
        var published: [MessageIndex.Status] { self.values.withLock { $0 } }
    }

    func make(_ r: Recorder, interval: TimeInterval = 0.15) -> ProgressThrottle<MessageIndex.Status> {
        ProgressThrottle<MessageIndex.Status>(interval: interval, clock: { r.now }) { status in
            r.values.withLock { $0.append(status) }
        }
    }

    /// Baseline: without the throttle every status is one main-actor hop.
    @Test func unthrottledBaselineHopsOncePerStatus() async {
        let r = Recorder()
        for n in 0..<500 { r.values.withLock { $0.append(.building(done: n, total: 500)) } }
        #expect(r.published.count == 500)
    }

    @Test func burstIsBounded() async {
        let r = Recorder()
        let throttle = self.make(r)
        for n in 0..<500 {
            await throttle.submit(.building(done: n, total: 500))
            r.advance(0.001)
        }
        await throttle.submit(.ready)
        let published = r.published
        #expect(published.count <= 5 && published.count < 500 / 10, "\(published.count) hops")
        #expect(published.first == .building(done: 0, total: 500))
        #expect(published.last == .ready)
    }

    @Test func spacedUpdatesAllPublish() async {
        let r = Recorder()
        let throttle = self.make(r)
        for n in 0..<5 {
            await throttle.submit(.building(done: n, total: 5))
            r.advance(0.2)
        }
        #expect(r.published.count == 5)
    }

    @Test func transitionsAreNeverCoalesced() async {
        let r = Recorder()
        let throttle = self.make(r)
        await throttle.submit(.building(done: 0, total: 3))
        await throttle.submit(.building(done: 1, total: 3))
        await throttle.submit(.unavailable)
        await throttle.submit(.building(done: 0, total: 3))
        await throttle.submit(.ready)
        #expect(r.published == [.building(done: 0, total: 3), .unavailable, .building(done: 0, total: 3), .ready])
    }

    @Test func finishDeliversLastValue() async {
        let r = Recorder()
        let throttle = self.make(r)
        await throttle.submit(.building(done: 0, total: 9))
        await throttle.submit(.building(done: 8, total: 9))
        #expect(r.published == [.building(done: 0, total: 9)])
        await throttle.finish(.building(done: 9, total: 9))
        #expect(r.published.last == .building(done: 9, total: 9))
    }
}
