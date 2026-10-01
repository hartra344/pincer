import Foundation
import Testing
@testable import PincerKit

/// Records what the coordinator asks the host to do.
@MainActor
final class FakeRunActivityHost: RunActivityHost {
    enum Event: Equatable {
        case start(RunActivityIdentity, RunActivityState)
        case update(String, RunActivityState)
        case end(String, RunActivityState, TimeInterval)
    }

    var events: [Event] = []
    /// Nil refuses to start, like ActivityKit when Live Activities are off.
    var nextId: String? = "activity-1"

    func start(_ identity: RunActivityIdentity, state: RunActivityState) -> String? {
        self.events.append(.start(identity, state))
        return self.nextId
    }

    func update(id: String, state: RunActivityState) { self.events.append(.update(id, state)) }

    func end(id: String, state: RunActivityState, dismissAfter: TimeInterval) {
        self.events.append(.end(id, state, dismissAfter))
    }

    var starts: [RunActivityState] { self.events.compactMap { if case let .start(_, state) = $0 { state } else { nil } } }
    var updates: [RunActivityState] { self.events.compactMap { if case let .update(_, state) = $0 { state } else { nil } } }
    var ends: [(state: RunActivityState, dismissAfter: TimeInterval)] {
        self.events.compactMap { if case let .end(_, state, delay) = $0 { (state, delay) } else { nil } }
    }
}

@Suite("Live Activity state")
struct RunActivityStateTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func running(_ signals: AvatarSignals) -> RunActivityState {
        RunActivityState.running(signals, startedAt: self.start)
    }

    /// Peels signals off one at a time, highest priority first, like the avatar does.
    @Test func priorityOrder() {
        var signals = AvatarSignals(
            isRunning: true, isThinking: true, isStreaming: true, runningToolName: "exec", awaitingApproval: true,
            isCompacting: true)
        #expect(self.running(signals).phase == .awaitingApproval)
        #expect(self.running(signals).status == "Waiting for your approval")
        signals.awaitingApproval = false
        #expect(self.running(signals).phase == .tool)
        #expect(self.running(signals).toolName == "exec")
        #expect(self.running(signals).status == "Running exec")
        signals.runningToolName = nil
        #expect(self.running(signals).phase == .replying)
        signals.isStreaming = false
        #expect(self.running(signals).phase == .compacting)
        signals.isCompacting = false
        #expect(self.running(signals).phase == .thinking)
        #expect(self.running(signals).startedAt == self.start)
        #expect(self.running(signals).endedAt == nil)
        // Running with nothing more specific still reads as thinking.
        #expect(self.running(AvatarSignals(isRunning: true)).phase == .thinking)
    }

    @Test func mcpToolsDropTheirServer() {
        let state = self.running(AvatarSignals(isRunning: true, runningToolName: "mcp__github__create_issue"))
        #expect(state.toolName == "create_issue")
        #expect(state.status == "Running create_issue")
    }

    @Test func finishedStatesByOutcome() {
        let end = self.start.addingTimeInterval(42)
        let tool = self.running(AvatarSignals(isRunning: true, runningToolName: "exec"))
        let done = RunActivityState.finished(tool, outcome: .success, at: end)
        #expect(done.phase == .completed && done.endedAt == end && done.startedAt == self.start && done.toolName == nil)
        #expect(done.status == "Finished")
        let failed = RunActivityState.finished(tool, outcome: .error, at: end)
        #expect(failed.phase == .failed && failed.status == "Something went wrong")
        let stopped = RunActivityState.finished(tool, outcome: .none, at: end)
        #expect(stopped.phase == .stopped && stopped.status == "Stopped")
        #expect([done, failed, stopped].allSatisfy(\.phase.isFinal) && !tool.phase.isFinal)
    }

    @Test func stateRoundTripsThroughCodable() throws {
        let state = RunActivityState.finished(
            self.running(AvatarSignals(isRunning: true)), outcome: .success, at: self.start.addingTimeInterval(5))
        let decoded = try JSONDecoder().decode(RunActivityState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }
}

@MainActor
@Suite("Live Activity coordinator")
struct RunActivityCoordinatorTests {
    let scratch = ScratchDefaults()
    let host = FakeRunActivityHost()
    let gatewayId = UUID()
    let key = "agent:main:main"
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func coordinator(startDelay: TimeInterval = 0) -> RunActivityCoordinator {
        let coordinator = RunActivityCoordinator(defaults: self.scratch.defaults)
        coordinator.host = self.host
        coordinator.startDelay = startDelay
        return coordinator
    }

    var identity: RunActivityIdentity {
        RunActivityIdentity(
            gatewayId: self.gatewayId, sessionKey: self.key, agentName: "Moki", chatTitle: "Main", emoji: "🦞",
            url: URL(string: "pincer://open?gateway=x&session=y")!)
    }

    func refresh(_ coordinator: RunActivityCoordinator, _ signals: AvatarSignals, eligible: Bool = true, at offset: TimeInterval = 0) {
        coordinator.refresh(
            gatewayId: self.gatewayId, sessionKey: self.key, signals: signals, startedAt: self.start, eligible: eligible,
            identity: self.identity, now: self.start.addingTimeInterval(offset))
    }

    @Test func followsATurnFromStartToFinish() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true, isThinking: true))
        #expect(self.host.starts.map(\.phase) == [.thinking])
        #expect(coordinator.activityId(gatewayId: self.gatewayId, sessionKey: self.key) == "activity-1")

        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec"))
        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec"))
        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec", awaitingApproval: true))
        self.refresh(coordinator, AvatarSignals(isRunning: true, isStreaming: true))
        // The repeat didn't produce a second update.
        #expect(self.host.updates.map(\.phase) == [.tool, .awaitingApproval, .replying])

        self.refresh(
            coordinator, AvatarSignals(isRunning: false, lastOutcome: .success, outcomeAt: self.start.addingTimeInterval(30)),
            at: 31)
        let ends = self.host.ends
        #expect(ends.count == 1)
        #expect(ends.first?.state.phase == .completed)
        #expect(ends.first?.state.startedAt == self.start)
        #expect(ends.first?.state.endedAt == self.start.addingTimeInterval(31))
        #expect(ends.first?.dismissAfter == RunActivityCoordinator.finishedDismissDelay)
        #expect(coordinator.activityId(gatewayId: self.gatewayId, sessionKey: self.key) == nil)

        // Nothing more once it's over.
        self.refresh(coordinator, AvatarSignals(isRunning: false))
        #expect(self.host.events.count == 5)
    }

    @Test func aFailedTurnEndsAsFailed() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        self.refresh(
            coordinator, AvatarSignals(isRunning: false, lastOutcome: .error, outcomeAt: self.start.addingTimeInterval(2)), at: 2)
        #expect(self.host.ends.first?.state.phase == .failed)
        #expect(self.host.ends.first?.dismissAfter == RunActivityCoordinator.finishedDismissDelay)
    }

    @Test func aStoppedTurnIsDismissedAtOnce() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        self.refresh(coordinator, AvatarSignals(isRunning: false), at: 2)
        #expect(self.host.ends.first?.state.phase == .stopped)
        #expect(self.host.ends.first?.dismissAfter == 0)
    }

    @Test func anOutcomeFromAnEarlierTurnIsNotThisOnes() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        let stale = AvatarSignals(isRunning: false, lastOutcome: .success, outcomeAt: self.start.addingTimeInterval(-60))
        self.refresh(coordinator, stale, at: 2)
        #expect(self.host.ends.first?.state.phase == .stopped)
    }

    @Test func aTurnThatEndsBeforeTheDelayNeverShows() {
        let coordinator = self.coordinator(startDelay: 600)
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        #expect(coordinator.isTracking(gatewayId: self.gatewayId, sessionKey: self.key))
        self.refresh(
            coordinator, AvatarSignals(isRunning: false, lastOutcome: .success, outcomeAt: self.start.addingTimeInterval(1)), at: 1)
        #expect(self.host.events.isEmpty)
        #expect(!coordinator.isTracking(gatewayId: self.gatewayId, sessionKey: self.key))
    }

    @Test func aLongTurnStartsOnceTheDelayPasses() async {
        let coordinator = self.coordinator(startDelay: 0.05)
        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec"))
        #expect(self.host.events.isEmpty)
        for _ in 0 ..< 200 where self.host.starts.isEmpty { try? await Task.sleep(for: .milliseconds(25)) }
        // It starts with the state the turn has reached by then.
        self.refresh(coordinator, AvatarSignals(isRunning: true, isStreaming: true))
        #expect(self.host.starts.map(\.phase) == [.tool])
        #expect(self.host.updates.map(\.phase) == [.replying])
    }

    @Test func aRefusedStartIsNotRetried() {
        self.host.nextId = nil
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec"))
        self.refresh(coordinator, AvatarSignals(isRunning: false, lastOutcome: .success, outcomeAt: self.start), at: 5)
        #expect(self.host.events.count == 1)
    }

    @Test func ineligibleChatsAndDisabledSettingGetNothing() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true), eligible: false)
        #expect(self.host.events.isEmpty && !coordinator.isTracking(gatewayId: self.gatewayId, sessionKey: self.key))

        self.scratch.defaults.set(false, forKey: RunActivityCoordinator.enabledKey)
        #expect(!coordinator.isEnabled)
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        #expect(self.host.events.isEmpty)
    }

    @Test func turningTheSettingOffEndsWhatIsShowing() {
        let coordinator = self.coordinator()
        #expect(coordinator.isEnabled)
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        coordinator.isEnabled = false
        #expect(self.host.ends.count == 1 && self.host.ends.first?.dismissAfter == 0)
        // A turn already tracked doesn't come back while it's off.
        self.refresh(coordinator, AvatarSignals(isRunning: true, runningToolName: "exec"))
        #expect(self.host.events.count == 2)
    }

    @Test func noHostIsANoOp() {
        let coordinator = RunActivityCoordinator(defaults: self.scratch.defaults)
        #expect(!coordinator.isActive)
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        #expect(!coordinator.isTracking(gatewayId: self.gatewayId, sessionKey: self.key))
    }

    @Test func separateChatsGetSeparateActivities() {
        let coordinator = self.coordinator()
        self.refresh(coordinator, AvatarSignals(isRunning: true))
        coordinator.refresh(
            gatewayId: self.gatewayId, sessionKey: "agent:main:other", signals: AvatarSignals(isRunning: true), startedAt: self.start,
            eligible: true, identity: self.identity)
        #expect(self.host.starts.count == 2)
        coordinator.endAll()
        #expect(self.host.ends.count == 2)
        #expect(!coordinator.isTracking(gatewayId: self.gatewayId, sessionKey: self.key))
    }
}

/// A chat's own events drive the shared coordinator; it's global, so these run one at a time and
/// never wait, which keeps other suites' chats out of the recording.
@MainActor
@Suite("Live Activity from a chat", .serialized)
struct ChatRunActivityTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)
    static let key = "agent:research:main"

    func withHost(_ body: (ChatStore, FakeRunActivityHost) -> Void) {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        let chat = store.chat(for: Self.key)
        let host = FakeRunActivityHost()
        let coordinator = RunActivityCoordinator.shared
        coordinator.host = host
        coordinator.startDelay = 0
        defer {
            coordinator.host = nil
            coordinator.startDelay = RunActivityCoordinator.defaultStartDelay
        }
        body(chat, host)
    }

    func status(_ chat: ChatStore, _ runId: String, state: String = "status") {
        chat.handleChat(["runId": .string(runId), "sessionKey": .string(Self.key), "state": .string(state), "phase": "thinking"])
    }

    func tool(_ chat: ChatStore, _ runId: String, phase: String) {
        chat.handleAgent([
            "runId": .string(runId), "stream": "tool",
            "data": ["toolCallId": "t1", "name": "exec", "phase": .string(phase)],
        ])
    }

    @Test func aRunStartsUpdatesAndFinishesItsActivity() {
        self.withHost { chat, host in
            self.status(chat, "r1")
            #expect(host.starts.map(\.phase) == [.thinking])
            if case let .start(identity, _)? = host.events.first {
                #expect(identity.sessionKey == Self.key && identity.agentName == "Research")
                #expect(PincerRoute(url: identity.url)?.sessionKey == Self.key)
            }

            self.tool(chat, "r1", phase: "start")
            self.tool(chat, "r1", phase: "result")
            #expect(host.updates.map(\.phase) == [.tool, .thinking])
            #expect(host.updates.first?.toolName == "exec")

            self.status(chat, "r1", state: "final")
            #expect(host.ends.map(\.state.phase) == [.completed])
        }
    }

    @Test func anErrorEndsItAsFailed() {
        self.withHost { chat, host in
            self.status(chat, "r1")
            self.status(chat, "r1", state: "error")
            #expect(host.ends.map(\.state.phase) == [.failed])
        }
    }

    @Test func anAbortedRunEndsAsStopped() {
        self.withHost { chat, host in
            self.status(chat, "r1")
            self.status(chat, "r1", state: "aborted")
            #expect(host.ends.map(\.state.phase) == [.stopped])
            #expect(host.ends.first?.dismissAfter == 0)
        }
    }

    @Test func onlyTheFirstWordsOfAReplyUpdate() {
        self.withHost { chat, host in
            self.status(chat, "r1")
            chat.handleAgent(["runId": "r1", "stream": "assistant", "data": ["text": "Hel"]])
            chat.handleAgent(["runId": "r1", "stream": "assistant", "data": ["text": "Hello"]])
            // Starting to reply is a change; more words aren't.
            #expect(host.updates.map(\.phase) == [.replying])
        }
    }
}
