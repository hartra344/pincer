import Foundation
import Testing
@testable import PincerKit

/// `RunTimeline` (#35): per-run lanes reduced from streamed `agent` / `chat` events.
struct RunTimelineTests {
    static let base = 1_000_000_000.0 // ms
    static let received = Date(timeIntervalSince1970: 5_000_000)

    /// Feeds events for one timeline, upstream-shaped: `{runId, seq, stream, ts, sessionKey, data}`.
    final class Feed {
        var timeline: RunTimeline
        var seq: [String: Int] = [:]

        init(maxRuns: Int = RunTimeline.defaultMaxRuns, maxSegments: Int = RunTimeline.defaultMaxSegmentsPerRun) {
            self.timeline = RunTimeline(maxRuns: maxRuns, maxSegmentsPerRun: maxSegments)
        }

        @discardableResult
        func agent(_ stream: String, _ data: [String: JSONValue], at ms: Double?, run: String = "r1",
                            session: String? = "agent:main:main", seq explicit: Int? = nil) -> Bool
        {
            let next = explicit ?? (self.seq[run, default: 0] + 1)
            self.seq[run] = max(self.seq[run, default: 0], next)
            var payload: [String: JSONValue] = ["runId": .string(run), "seq": JSONValue(next), "stream": .string(stream),
                                                "data": .object(data)]
            if let ms { payload["ts"] = .number(RunTimelineTests.base + ms) }
            if let session { payload["sessionKey"] = .string(session) }
            return self.timeline.apply(agent: .object(payload), receivedAt: RunTimelineTests.received)
        }

        @discardableResult
        func chat(_ state: String, at ms: Double? = nil, run: String = "r1", _ extra: [String: JSONValue] = [:]) -> Bool {
            var payload: [String: JSONValue] = ["runId": .string(run), "sessionKey": "agent:main:main", "state": .string(state)]
            if let ms { payload["ts"] = .number(RunTimelineTests.base + ms) }
            payload.merge(extra) { _, new in new }
            return self.timeline.apply(chat: .object(payload), receivedAt: RunTimelineTests.received)
        }

        func start(at ms: Double, run: String = "r1") {
            self.agent("lifecycle", ["phase": "start", "startedAt": .number(RunTimelineTests.base + ms)], at: ms, run: run)
        }

        func toolStart(_ id: String, _ name: String = "exec", at ms: Double, run: String = "r1") -> Bool {
            self.agent("tool", ["phase": "start", "name": .string(name), "toolCallId": .string(id), "args": [:]], at: ms, run: run)
        }

        func toolResult(_ id: String, _ name: String = "exec", at ms: Double, isError: Bool = false,
                                 result: JSONValue = "ok", run: String = "r1") -> Bool
        {
            self.agent("tool", ["phase": "result", "name": .string(name), "toolCallId": .string(id), "isError": .bool(isError),
                                "result": result], at: ms, run: run)
        }

        func lane(_ run: String = "r1") -> RunLane? { self.timeline.lane(run) }
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: (base + ms) / 1000) }

    // MARK: A whole run

    @Test func mockShapedRunBuildsThinkingToolWriting() throws {
        let feed = Feed()
        feed.start(at: 0)
        for (i, part) in ["Reading", " the", " task"].enumerated() {
            feed.agent("thinking", ["text": .string(part), "delta": .string(part)], at: 100 + Double(i) * 60)
        }
        _ = feed.toolStart("c1", at: 400)
        feed.agent("tool", ["phase": "update", "name": "exec", "toolCallId": "c1", "partialResult": "200 lines"], at: 500)
        _ = feed.toolResult("c1", at: 700)
        feed.agent("assistant", ["text": "Gateway", "delta": "Gateway"], at: 800)
        feed.agent("assistant", ["text": "Gateway logs", "delta": " logs"], at: 850)
        feed.agent("lifecycle", ["phase": "end", "stopReason": "stop", "aborted": false, "endedAt": .number(Self.base + 900)], at: 900)

        let lane = try #require(feed.lane())
        #expect(lane.status == .done && !lane.isRunning)
        #expect(lane.segments.map(\.kind) == [.thinking, .tool(name: "exec"), .writing])
        #expect(lane.segments.allSatisfy { $0.end != nil })
        #expect(lane.segments[0].start == Self.date(100) && lane.segments[0].end == Self.date(400), "thinking closes when the tool starts")
        #expect(abs(lane.segments[1].duration(now: .distantFuture) - 0.3) < 0.001)
        #expect(lane.segments[2].end == Self.date(900))
        #expect(lane.startedAt == Self.date(0) && lane.endedAt == Self.date(900))
        #expect(abs(lane.duration(now: .distantFuture) - 0.9) < 0.001)
        #expect(lane.toolCount == 1 && lane.errorCount == 0 && lane.error == nil)
        #expect(lane.sessionKey == "agent:main:main")
        #expect(lane.currentActivity == nil)
    }

    @Test func segmentIdsIncrease() throws {
        let feed = Feed()
        feed.start(at: 0)
        for i in 0..<10 { _ = feed.toolStart("c\(i)", at: Double(i) * 10) }
        let ids = try #require(feed.lane()).segments.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)
    }

    // MARK: Errors and aborts

    @Test func toolErrorKeepsItsFirstLineAndLifecycleErrorFails() throws {
        let feed = Feed()
        feed.start(at: 0)
        _ = feed.toolStart("t", at: 100)
        _ = feed.toolResult("t", at: 200, isError: true, result: "LoginTests.testTimeout failed\nexit code 1")
        feed.agent("lifecycle", ["phase": "error", "error": "swift test exited with code 1\nstack…", "endedAt": .number(Self.base + 300)], at: 300)
        let lane = try #require(feed.lane())
        #expect(lane.status == .error)
        #expect(lane.error == "swift test exited with code 1")
        #expect(lane.segments.map(\.kind) == [.tool(name: "exec"), .error(message: "swift test exited with code 1")])
        #expect(lane.segments[0].isError && lane.segments[0].detail == "LoginTests.testTimeout failed")
        #expect(lane.segments[1].kind.isMarker && lane.segments[1].duration(now: .distantFuture) == 0)
        #expect(lane.errorCount == 2)
        #expect(lane.endedAt == Self.date(300))
    }

    @Test func errorResultObjectsAndMissingMessages() throws {
        let feed = Feed()
        feed.start(at: 0)
        _ = feed.toolStart("a", at: 1)
        _ = feed.toolResult("a", at: 2, isError: true, result: ["error": "ENOENT: no such file"])
        feed.agent("lifecycle", ["phase": "error"], at: 3)
        let lane = try #require(feed.lane())
        #expect(lane.segments[0].detail == "ENOENT: no such file")
        #expect(lane.error?.isEmpty == false, "a generic message stands in")
    }

    @Test func errorStreamMarksWithoutEndingTheRun() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("thinking", ["text": "x"], at: 10)
        #expect(feed.agent("error", ["error": "rate limited, retrying"], at: 20))
        let lane = try #require(feed.lane())
        #expect(lane.isRunning && lane.errorCount == 1)
        #expect(lane.segments.last?.kind == .error(message: "rate limited, retrying"))
        #expect(lane.segments.first?.end == Self.date(20), "the open stream closes at the error")
    }

    @Test func upstreamAbortIsLifecycleEndThenChatAborted() throws {
        let feed = Feed()
        feed.start(at: 0)
        _ = feed.toolStart("t", "web_fetch", at: 100)
        feed.agent("lifecycle", ["phase": "end", "status": "cancelled", "aborted": true, "stopReason": "user",
                                 "startedAt": .number(Self.base), "endedAt": .number(Self.base + 400)], at: 400)
        #expect(!feed.chat("aborted", at: 410), "the chat echo changes nothing")
        let lane = try #require(feed.lane())
        #expect(lane.status == .aborted)
        #expect(lane.segments.map(\.kind) == [.tool(name: "web_fetch"), .abort])
        #expect(lane.segments[0].end == Self.date(400), "open tools close at the abort")
        #expect(abs(lane.duration(now: .distantFuture) - 0.4) < 0.001)
    }

    @Test func chatOnlyTerminalStates() throws {
        let feed = Feed()
        feed.agent("thinking", ["text": "x"], at: 0, run: "a")
        #expect(feed.chat("aborted", at: 50, run: "a"))
        feed.agent("thinking", ["text": "x"], at: 0, run: "e")
        #expect(feed.chat("error", at: 60, run: "e", ["errorMessage": "model overloaded"]))
        feed.agent("thinking", ["text": "x"], at: 0, run: "f")
        #expect(feed.chat("final", at: 70, run: "f"))
        #expect(feed.lane("a")?.status == .aborted && feed.lane("a")?.segments.last?.kind == .abort)
        #expect(feed.lane("e")?.status == .error && feed.lane("e")?.error == "model overloaded")
        #expect(feed.lane("f")?.status == .done && feed.lane("f")?.endedAt == Self.date(70))
    }

    @Test func doneNeverOverridesErrorOrAbort() throws {
        let feed = Feed()
        feed.start(at: 0, run: "e")
        feed.agent("lifecycle", ["phase": "error", "error": "boom"], at: 10, run: "e")
        #expect(!feed.chat("final", at: 20, run: "e"))
        #expect(!feed.agent("lifecycle", ["phase": "end"], at: 30, run: "e"))
        #expect(feed.lane("e")?.status == .error && feed.lane("e")?.endedAt == Self.date(10))

        feed.start(at: 0, run: "a")
        feed.agent("lifecycle", ["phase": "end", "aborted": true], at: 10, run: "a")
        #expect(!feed.chat("final", at: 20, run: "a"))
        #expect(feed.lane("a")?.status == .aborted)
        #expect(feed.lane("a")?.segments.filter { $0.kind == .abort }.count == 1)
    }

    // MARK: Duplicates and ordering

    @Test func duplicateToolEventsAreIdempotent() throws {
        let feed = Feed()
        feed.start(at: 0)
        #expect(feed.toolStart("t", at: 10))
        #expect(!feed.toolStart("t", at: 10))
        #expect(feed.toolResult("t", at: 20))
        #expect(!feed.toolResult("t", at: 20))
        let lane = try #require(feed.lane())
        #expect(lane.segments.count == 1 && lane.toolCount == 1)
    }

    @Test func duplicateTerminalEventsAreIgnored() throws {
        let feed = Feed()
        feed.start(at: 0)
        #expect(feed.agent("lifecycle", ["phase": "end"], at: 10))
        #expect(!feed.agent("lifecycle", ["phase": "end"], at: 10))
        #expect(!feed.chat("final", at: 11))
        #expect(feed.lane()?.segments.isEmpty == true)
    }

    /// The same events delivered twice (e.g. a reconnect replay) leave the lane as it was.
    @Test func replayedEventsWithSameSeqDoNotDuplicateSegments() throws {
        let feed = Feed()
        var events: [JSONValue] = []
        func add(_ stream: String, _ data: [String: JSONValue], _ ms: Double) {
            events.append(["runId": "r1", "seq": JSONValue(events.count + 1), "stream": .string(stream),
                           "ts": .number(Self.base + ms), "sessionKey": "s", "data": .object(data)])
        }
        add("lifecycle", ["phase": "start", "startedAt": .number(Self.base)], 0)
        add("thinking", ["text": "a"], 10)
        add("tool", ["phase": "start", "name": "read", "toolCallId": "c1"], 20)
        add("tool", ["phase": "result", "name": "read", "toolCallId": "c1", "isError": false], 30)
        add("thinking", ["text": "b"], 40)
        add("tool", ["phase": "start", "name": "read", "toolCallId": "c2"], 50)
        for event in events { feed.timeline.apply(agent: event, receivedAt: Self.received) }
        let once = try #require(feed.lane())
        for event in events { feed.timeline.apply(agent: event, receivedAt: Self.received) }
        let twice = try #require(feed.lane())
        #expect(twice.segments.map(\.kind) == once.segments.map(\.kind),
                "replay added \(twice.segments.count - once.segments.count) segments")
        #expect(twice.toolCount == once.toolCount)
    }

    @Test func settleEndsOnlyRunsTheRowPostdates() throws {
        let feed = Feed()
        feed.start(at: 0, run: "old")
        feed.agent("thinking", ["text": "x"], at: 50, run: "old")
        feed.start(at: 1000, run: "new")
        let asRunning = feed.timeline.settle(sessionKey: "agent:main:main", status: .running, asOf: Self.date(2000))
        #expect(!asRunning && feed.timeline.runningSessionKeys == ["agent:main:main"])
        let settled = feed.timeline.settle(sessionKey: "agent:main:main", status: .aborted, asOf: Self.date(500))
        #expect(settled)
        #expect(feed.lane("old")?.status == .aborted && feed.lane("old")?.endedAt == Self.date(50))
        #expect(feed.lane("new")?.isRunning == true, "a row older than the run says nothing about it")
        let unknown = feed.timeline.settle(sessionKey: "agent:nobody:main", status: .done, asOf: Self.date(5000))
        #expect(!unknown)
    }

    @Test func lowerSeqAfterAHigherOneIsDropped() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("thinking", ["text": "x"], at: 10, seq: 5)
        #expect(feed.toolStart("next", at: 20))
        #expect(!feed.agent("assistant", ["text": "old"], at: 30, seq: 3))
        #expect(feed.lane()?.segments.contains { $0.kind == .writing } == false)
    }

    @Test func resultBeforeStartIsDroppedAndTheLateStartStaysOpenUntilTheEnd() throws {
        let feed = Feed()
        feed.start(at: 0)
        #expect(!feed.toolResult("t", at: 20))
        #expect(feed.toolStart("t", at: 10))
        feed.agent("lifecycle", ["phase": "end"], at: 50)
        let lane = try #require(feed.lane())
        #expect(lane.segments.count == 1 && lane.segments[0].end == Self.date(50))
        #expect(!lane.segments[0].isError)
    }

    @Test func lateEventsNeverMoveTimeBackwards() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("thinking", ["text": "x"], at: 500)
        feed.agent("assistant", ["text": "y"], at: 200) // late delivery
        let lane = try #require(feed.lane())
        #expect(lane.lastEventAt == Self.date(500))
        #expect(lane.segments.allSatisfy { ($0.end ?? .distantFuture) >= $0.start }, "no negative segments")
    }

    @Test func eventsAfterTheEndAddNothing() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("lifecycle", ["phase": "end"], at: 100)
        #expect(!feed.agent("thinking", ["text": "late"], at: 150))
        #expect(!feed.toolStart("late", at: 160))
        #expect(!feed.agent("assistant", ["text": "late"], at: 170))
        let lane = try #require(feed.lane())
        #expect(lane.segments.isEmpty && lane.lastEventAt == Self.date(100))
    }

    @Test func endBeforeStartClampsToZero() throws {
        let feed = Feed()
        feed.start(at: 1000)
        feed.agent("lifecycle", ["phase": "end", "endedAt": .number(Self.base + 10)], at: 1001)
        let lane = try #require(feed.lane())
        #expect(lane.duration(now: .distantFuture) == 0 && lane.endedAt == lane.startedAt)
    }

    @Test func restartAfterEndRunsAgain() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("lifecycle", ["phase": "end"], at: 100)
        feed.start(at: 200)
        let lane = try #require(feed.lane())
        #expect(lane.isRunning && lane.endedAt == nil && lane.startedAt == Self.date(200))
    }

    @Test func runFirstSeenFinishingGetsNoLane() {
        let feed = Feed()
        #expect(!feed.agent("lifecycle", ["phase": "end"], at: 0, run: "ghost"))
        #expect(!feed.agent("lifecycle", ["phase": "error", "error": "x"], at: 0, run: "ghost"))
        #expect(!feed.chat("final", run: "ghost") && !feed.chat("aborted", run: "ghost") && !feed.chat("error", run: "ghost"))
        #expect(feed.timeline.lane("ghost") == nil && feed.timeline.count == 0)
    }

    @Test func malformedEventsAreIgnored() {
        var timeline = RunTimeline()
        let noRun = timeline.apply(agent: ["stream": "thinking", "data": [:]], receivedAt: Self.received)
        let noStream = timeline.apply(agent: ["runId": "r", "data": [:]], receivedAt: Self.received)
        let chatNoRun = timeline.apply(chat: ["state": "final"], receivedAt: Self.received)
        let other = timeline.apply(event: GatewayEvent(name: "health", payload: ["runId": "r"], seq: 1), receivedAt: Self.received)
        #expect(!noRun && !noStream && !chatNoRun && !other)
        #expect(timeline.count == 0)
    }

    @Test func applyEventRoutesAgentAndChat() {
        var timeline = RunTimeline()
        let started = timeline.apply(event: GatewayEvent(name: "agent", payload: ["runId": "r", "stream": "lifecycle",
                                                                                   "data": ["phase": "start"]], seq: 1),
                                     receivedAt: Self.received, sessionKey: "agent:main:x")
        let finished = timeline.apply(event: GatewayEvent(name: "chat", payload: ["runId": "r", "state": "final"], seq: 2),
                                      receivedAt: Self.received)
        #expect(started && finished)
        #expect(timeline.lane("r")?.status == .done && timeline.lane("r")?.sessionKey == "agent:main:x")
    }

    // MARK: Time and sessions

    @Test func missingTsUsesReceivedAt() throws {
        let feed = Feed()
        feed.agent("thinking", ["text": "x"], at: nil)
        let lane = try #require(feed.lane())
        #expect(lane.startedAt == Self.received && lane.lastEventAt == Self.received)
    }

    @Test func runningDurationUsesNow() throws {
        let feed = Feed()
        feed.start(at: 0)
        _ = feed.toolStart("t", at: 1000)
        let lane = try #require(feed.lane())
        #expect(lane.duration(now: Self.date(61_000)) == 61)
        #expect(lane.segments[0].isOpen && lane.segments[0].duration(now: Self.date(3000)) == 2)
        #expect(lane.currentActivity == "Running `exec`…")
    }

    @Test func currentActivityCaptions() throws {
        let feed = Feed()
        feed.start(at: 0)
        #expect(feed.lane()?.currentActivity == "Working…")
        feed.agent("thinking", ["text": "x"], at: 1)
        #expect(feed.lane()?.currentActivity == "Thinking…")
        feed.agent("assistant", ["text": "y"], at: 2)
        #expect(feed.lane()?.currentActivity == "Writing…")
        feed.agent("compaction", ["phase": "start"], at: 3)
        #expect(feed.lane()?.currentActivity == "Compacting context…")
        feed.agent("compaction", ["phase": "end"], at: 4)
        #expect(feed.lane()?.segments.map(\.kind) == [.thinking, .writing, .compaction])
        #expect(feed.lane()?.segments.last?.end == Self.date(4))
    }

    @Test func reasoningCountsAsThinkingAndConsecutiveDeltasShareASegment() throws {
        let feed = Feed()
        feed.start(at: 0)
        feed.agent("reasoning", ["text": "a"], at: 1)
        feed.agent("thinking", ["text": "ab"], at: 2)
        feed.agent("thinking", ["text": "abc"], at: 3)
        #expect(feed.lane()?.segments.map(\.kind) == [.thinking])
    }

    @Test func sessionKeyFallbackAndLookups() throws {
        let feed = Feed()
        feed.agent("thinking", ["text": "x"], at: 0, run: "old", session: nil)
        #expect(feed.timeline.lanes(sessionKey: "agent:main:main").isEmpty)
        // A later event names the session.
        feed.agent("thinking", ["text": "y"], at: 10, run: "old")
        feed.start(at: 100, run: "new")
        feed.agent("thinking", ["text": "x"], at: 0, run: "elsewhere", session: "agent:research:main")
        #expect(feed.timeline.lanes(sessionKey: "agent:main:main").map(\.runId) == ["new", "old"])
        #expect(feed.timeline.latestLane(sessionKey: "agent:main:main")?.runId == "new")
        #expect(feed.timeline.lastEventAt(sessionKey: "agent:main:main") == Self.date(100))
        #expect(feed.timeline.lanes(sessionKey: "agent:nobody:main").isEmpty)
        #expect(feed.timeline.runIds == ["old", "new", "elsewhere"])
        var explicit = RunTimeline()
        explicit.apply(agent: ["runId": "r", "stream": "thinking", "data": [:]], receivedAt: Self.received, sessionKey: "k")
        #expect(explicit.latestLane(sessionKey: "k")?.runId == "r")
    }

    @Test func deltasOnlyPublishOncePerCoalesceInterval() {
        let feed = Feed()
        feed.start(at: 0)
        #expect(feed.agent("thinking", ["text": "a"], at: 10))
        #expect(!feed.agent("thinking", ["text": "ab"], at: 200))
        #expect(!feed.agent("thinking", ["text": "abc"], at: 900))
        #expect(feed.agent("thinking", ["text": "abcd"], at: 10 + RunTimeline.coalesceInterval * 1000))
        #expect(feed.lane()?.lastEventAt == Self.date(10 + RunTimeline.coalesceInterval * 1000))
    }

    // MARK: Caps and performance

    @Test func evictsOldestFinishedRunsFirst() {
        let feed = Feed(maxRuns: 3)
        feed.start(at: 0, run: "running-old")
        feed.start(at: 1, run: "done-1")
        feed.agent("lifecycle", ["phase": "end"], at: 2, run: "done-1")
        feed.start(at: 3, run: "done-2")
        feed.agent("lifecycle", ["phase": "end"], at: 4, run: "done-2")
        feed.start(at: 5, run: "new")
        #expect(feed.timeline.count == 3)
        #expect(feed.lane("running-old") != nil, "a running run outlives finished ones")
        #expect(feed.lane("done-1") == nil && feed.lane("done-2") != nil && feed.lane("new") != nil)
        #expect(!feed.timeline.runIds.contains("done-1"))
        #expect(feed.timeline.lanes(sessionKey: "agent:main:main").map(\.runId).contains("done-1") == false)
    }

    @Test func allRunningEvictsTheOldest() {
        let feed = Feed(maxRuns: 2)
        for run in ["a", "b", "c"] { feed.start(at: 0, run: run) }
        #expect(feed.timeline.count == 2 && feed.lane("a") == nil)
    }

    @Test func minimumCapsAreClamped() {
        let timeline = RunTimeline(maxRuns: 0, maxSegmentsPerRun: 0)
        #expect(timeline.maxRuns >= 1 && timeline.maxSegmentsPerRun >= 2)
    }

    @Test func segmentCapDropsTheOldestAndKeepsCounting() throws {
        let feed = Feed(maxSegments: 50)
        feed.start(at: 0)
        for i in 0..<1000 {
            _ = feed.toolStart("c\(i)", at: Double(i * 2))
            _ = feed.toolResult("c\(i)", at: Double(i * 2 + 1), isError: i % 100 == 0)
        }
        let lane = try #require(feed.lane())
        #expect(lane.segments.count <= 50 && !lane.segments.isEmpty)
        #expect(lane.segments.count + lane.droppedSegments == 1000)
        #expect(lane.toolCount == 1000 && lane.errorCount == 10)
        #expect(lane.segments.last?.toolCallId == "c999" && lane.segments.last?.end == Self.date(1999))
        // A result for a tool whose segment was dropped touches nothing but the clock.
        _ = feed.toolResult("c0", at: 5000, isError: true)
        let after = try #require(feed.lane())
        #expect(after.segments == lane.segments && after.errorCount == lane.errorCount)
    }

    @Test func openToolSurvivesTrimmingOfOthers() throws {
        let feed = Feed(maxSegments: 8)
        feed.start(at: 0)
        _ = feed.toolStart("long", at: 1)
        for i in 0..<5 { _ = feed.toolStart("s\(i)", at: Double(2 + i)); _ = feed.toolResult("s\(i)", at: Double(2 + i)) }
        #expect(feed.toolResult("long", at: 100), "still within the cap")
    }

    @Test func manyRunsAndEventsStayFast() {
        let feed = Feed()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for run in 0..<500 {
                let id = "run\(run)"
                feed.start(at: Double(run), run: id)
                for step in 0..<100 {
                    let at = Double(run * 1000 + step * 5)
                    if step % 3 == 0 {
                        _ = feed.toolStart("\(id)-\(step)", at: at, run: id)
                        _ = feed.toolResult("\(id)-\(step)", at: at + 1, run: id)
                    } else {
                        feed.agent(step % 3 == 1 ? "thinking" : "assistant", ["text": "x"], at: at, run: id)
                    }
                }
                feed.agent("lifecycle", ["phase": "end"], at: Double(run * 1000 + 999), run: id)
            }
        }
        #expect(feed.timeline.count == RunTimeline.defaultMaxRuns)
        #expect(feed.timeline.runIds.count == RunTimeline.defaultMaxRuns)
        #expect(elapsed < PerfBudget.limit(.seconds(3)), "85k events took \(elapsed)")
    }

    // MARK: Rendering helpers

    @Test(arguments: [
        (0.0, "<1s"), (0.99, "<1s"), (-5, "<1s"), (.infinity, "<1s"), (.nan, "<1s"),
        (1, "0:01"), (59.9, "0:59"), (60, "1:00"), (3599, "59:59"), (3600, "1:00:00"), (36_061, "10:01:01"),
    ] as [(TimeInterval, String)])
    func durationFormat(interval: TimeInterval, expected: String) {
        #expect(RunDuration.format(interval) == expected)
    }

    @Test func spansMergeTinySegmentsAndKeepMarkers() throws {
        let feed = Feed()
        feed.start(at: 0)
        for i in 0..<200 {
            _ = feed.toolStart("c\(i)", at: Double(i * 10))
            _ = feed.toolResult("c\(i)", at: Double(i * 10 + 5))
        }
        _ = feed.toolStart("big", at: 3000)
        _ = feed.toolResult("big", at: 9000, isError: true, result: "bad")
        feed.agent("lifecycle", ["phase": "error", "error": "failed"], at: 10_000)
        let lane = try #require(feed.lane())
        let spans = lane.spans(axisStart: Self.date(0), axisEnd: Self.date(10_000), width: 200, now: Self.date(10_000))
        let bars = spans.filter { !$0.isMarker }
        let markers = spans.filter(\.isMarker)
        #expect(bars.count < 50, "\(bars.count) bars for 201 segments")
        #expect(bars.reduce(0) { $0 + $1.mergedCount } == 201)
        #expect(markers.count == 1 && markers[0].x == 200)
        #expect(spans.allSatisfy { $0.x >= 0 && $0.x <= 200 && $0.width >= 0 && $0.x + $0.width <= 200.0001 })
        #expect(bars.last?.isError == true && bars.last?.detail == "bad")
        #expect(lane.spans(axisStart: Self.date(0), axisEnd: Self.date(0), width: 100, now: Self.date(0)).isEmpty)
        #expect(lane.spans(axisStart: Self.date(0), axisEnd: Self.date(10), width: 0, now: Self.date(0)).isEmpty)
    }

    @Test func openSegmentsExtendToNowInSpans() throws {
        let feed = Feed()
        feed.start(at: 0)
        _ = feed.toolStart("t", at: 0)
        let lane = try #require(feed.lane())
        let spans = lane.spans(axisStart: Self.date(0), axisEnd: Self.date(1000), width: 100, now: Self.date(500))
        #expect(spans.count == 1 && abs(spans[0].width - 50) < 0.001)
    }

    // MARK: Seeds

    @Test func demoSeededEventsBuildRichLanes() throws {
        let now = Self.base
        var timeline = RunTimeline()
        let events = DemoGateway.seededRunEvents(now: now)
        let stamps = events.compactMap { $0["ts"]?.double }
        #expect(stamps == stamps.sorted() && stamps.count == events.count)
        for event in events { timeline.apply(agent: event, receivedAt: Self.received) }
        let kids = DemoGateway.seededSubagents
        let minute = 60.0
        let parent = try #require(timeline.latestLane(sessionKey: DemoGateway.subagentParentKey))
        #expect(parent.status == .done && parent.toolCount == 6)
        #expect(parent.segments.filter { $0.kind == .tool(name: "sessions_spawn") }.count == 3)
        #expect(parent.segments.contains { $0.kind == .thinking })
        let done = try #require(timeline.latestLane(sessionKey: kids.done))
        #expect(done.status == .done && abs(done.duration(now: .distantFuture) - 8.5 * minute) < 0.01)
        #expect(timeline.latestLane(sessionKey: kids.grandchild)?.status == .done)
        let aborted = try #require(timeline.latestLane(sessionKey: kids.aborted))
        #expect(aborted.status == .aborted && aborted.segments.last?.kind == .abort)
        let failed = try #require(timeline.latestLane(sessionKey: kids.failed))
        #expect(failed.status == .error && failed.error?.contains("503") == true)
        #expect(failed.segments.contains { $0.isError && $0.kind == .tool(name: "web_fetch") && $0.detail == "503 Service Unavailable" })
        let running = try #require(timeline.latestLane(sessionKey: kids.running))
        #expect(running.isRunning && running.toolCount == 3 && running.errorCount == 0)
        #expect(running.currentActivity == "Running `write`…")
        #expect(running.duration(now: Date(timeIntervalSince1970: now / 1000)) == 6 * minute)
        #expect(events.allSatisfy { $0["sessionKey"]?.string != nil && $0["seq"]?.double != nil })
        #expect(events.filter { $0["sessionKey"]?.string != DemoGateway.subagentParentKey }.allSatisfy { $0["spawnedBy"] != nil })
        let runningSeqs = events.filter { $0["sessionKey"]?.string == kids.running }.compactMap { $0["seq"]?.int }
        #expect(runningSeqs.last == DemoGateway.seededRunningLastSeq)
    }

    @Test func demoLiveStepsKeepAToolRunning() throws {
        var timeline = RunTimeline()
        for event in DemoGateway.seededRunEvents(now: Self.base) { timeline.apply(agent: event, receivedAt: Self.received) }
        var seq = DemoGateway.seededRunningLastSeq
        for step in 0..<8 {
            let next = DemoGateway.liveSubagentStep(step, seq: seq, now: Self.base + Double(step + 1) * 2500)
            #expect(next.seq > seq)
            seq = next.seq
            for event in next.events {
                let changed = timeline.apply(agent: event, receivedAt: Self.received)
                #expect(changed)
            }
            let lane = try #require(timeline.latestLane(sessionKey: DemoGateway.seededSubagents.running))
            #expect(lane.currentActivity?.hasPrefix("Running `") == true, "step \(step): \(lane.currentActivity ?? "nil")")
            #expect(lane.segments.filter(\.isOpen).count == 1)
        }
        #expect(timeline.latestLane(sessionKey: DemoGateway.seededSubagents.running)?.toolCount == 11)
    }
}
