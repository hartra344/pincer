import Foundation
import Testing
@testable import PincerKit

@Suite("Runs duration numeric boundary", .timeLimit(.minutes(2)))
struct RunDurationOverflowTests {
    private func completedLane(endingAt milliseconds: Double) throws -> RunLane {
        var timeline = RunTimeline()
        let received = Date(timeIntervalSince1970: 1)
        // Explicit LOCAL legal AgentEvent fixtures, not a replay claimed to come from the Gateway.
        let acceptedStart = timeline.apply(agent: ["runId": "local-duration", "seq": 1, "stream": "lifecycle", "ts": 1000,
                                      "data": ["phase": "start", "startedAt": 1000]], receivedAt: received)
        #expect(acceptedStart)
        let acceptedEnd = timeline.apply(agent: ["runId": "local-duration", "seq": 2, "stream": "lifecycle", "ts": .number(milliseconds),
                                      "data": ["phase": "end", "endedAt": .number(milliseconds)]], receivedAt: received)
        #expect(acceptedEnd)
        let lane = try #require(timeline.lane("local-duration"))
        #expect(lane.status == .done && lane.endedAt != nil)
        return lane
    }
    @Test func largeLegalTimestampReachesActualRunsFormatter() throws {
        let lane = try completedLane(endingAt: 1e30)
        let duration = lane.duration(now: Date(timeIntervalSince1970: 1))
        #expect(duration.isFinite && duration > Double(Int.max))
        #expect(!RunDuration.format(duration).isEmpty)
    }
    @Test func ordinaryLifecycleAndSubsecondControlsRemainExact() throws {
        let lane = try completedLane(endingAt: 66000)
        #expect(lane.duration(now: Date(timeIntervalSince1970: 1)) == 65)
        #expect(RunDuration.format(lane.duration(now: Date(timeIntervalSince1970: 1))) == "1:05")
        #expect(RunDuration.format(0.5) == "<1s" && RunDuration.format(-1) == "<1s")
    }
}
