import Foundation
import Testing
@testable import PincerKit

@Suite("Avatar state machine")
struct AvatarStateMachineTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ signals: AvatarSignals, at offset: TimeInterval = 0) -> AvatarState {
        AvatarStateMachine.state(for: signals, now: self.now.addingTimeInterval(offset))
    }

    @Test func idleByDefault() {
        #expect(self.state(.idle) == .idle)
        #expect(AvatarStateMachine.nextTransition(for: .idle, now: self.now) == nil)
    }

    /// Peels signals off one at a time, highest priority first.
    @Test func priorityOrder() {
        var signals = AvatarSignals(
            isRunning: true, isThinking: true, isStreaming: true, runningToolName: "exec", awaitingApproval: true,
            isCompacting: true, lastOutcome: .error, outcomeAt: self.now)
        #expect(self.state(signals) == .awaitingApproval)
        signals.awaitingApproval = false
        #expect(self.state(signals) == .error)
        signals.lastOutcome = .none
        signals.outcomeAt = nil
        #expect(self.state(signals) == .tool(.exec))
        signals.runningToolName = nil
        #expect(self.state(signals) == .streaming)
        signals.isStreaming = false
        #expect(self.state(signals) == .thinking)
        signals.isThinking = false
        #expect(self.state(signals) == .compacting)
        signals.isCompacting = false
        // Running with nothing more specific still reads as thinking.
        #expect(self.state(signals) == .thinking)
        signals.isRunning = false
        signals.lastOutcome = .success
        signals.outcomeAt = self.now
        #expect(self.state(signals) == .success)
        signals.lastOutcome = .none
        signals.outcomeAt = nil
        #expect(self.state(signals) == .idle)
    }

    @Test func approvalBeatsEverything() {
        let signals = AvatarSignals(isRunning: true, runningToolName: "exec", awaitingApproval: true)
        #expect(self.state(signals) == .awaitingApproval)
        #expect(self.state(AvatarSignals(awaitingApproval: true)) == .awaitingApproval)
    }

    @Test func errorBeatsATool() {
        let signals = AvatarSignals(isRunning: true, runningToolName: "web_fetch", lastOutcome: .error, outcomeAt: self.now)
        #expect(self.state(signals) == .error)
        #expect(self.state(signals, at: AvatarStateMachine.errorDuration) == .tool(.web))
    }

    @Test func successGivesWayToANewRun() {
        let finished = AvatarSignals(lastOutcome: .success, outcomeAt: self.now)
        #expect(self.state(finished) == .success)
        for busy in [
            AvatarSignals(isRunning: true, lastOutcome: .success, outcomeAt: self.now),
            AvatarSignals(isRunning: true, isThinking: true, lastOutcome: .success, outcomeAt: self.now),
            AvatarSignals(isRunning: true, isStreaming: true, lastOutcome: .success, outcomeAt: self.now),
            AvatarSignals(isCompacting: true, lastOutcome: .success, outcomeAt: self.now),
        ] {
            #expect(self.state(busy) != .success)
        }
    }

    @Test func successExpires() {
        let signals = AvatarSignals(lastOutcome: .success, outcomeAt: self.now)
        let duration = AvatarStateMachine.successDuration
        #expect(duration > 0)
        #expect(self.state(signals, at: 0) == .success)
        #expect(self.state(signals, at: duration - 0.01) == .success)
        #expect(self.state(signals, at: duration) == .idle)
        #expect(self.state(signals, at: duration + 60) == .idle)
        #expect(AvatarStateMachine.nextTransition(for: signals, now: self.now) == self.now.addingTimeInterval(duration))
        #expect(AvatarStateMachine.nextTransition(for: signals, now: self.now.addingTimeInterval(duration)) == nil)
    }

    @Test func errorExpiresAndLastsLongerThanSuccess() {
        let signals = AvatarSignals(lastOutcome: .error, outcomeAt: self.now)
        let duration = AvatarStateMachine.errorDuration
        #expect(duration > AvatarStateMachine.successDuration)
        #expect(self.state(signals, at: duration - 0.01) == .error)
        #expect(self.state(signals, at: duration) == .idle)
        #expect(AvatarStateMachine.nextTransition(for: signals, now: self.now.addingTimeInterval(1))
            == self.now.addingTimeInterval(duration))
        #expect(AvatarStateMachine.nextTransition(for: signals, now: self.now.addingTimeInterval(duration + 1)) == nil)
    }

    @Test func outcomeWithoutATimeIsNotShown() {
        #expect(self.state(AvatarSignals(lastOutcome: .success)) == .idle)
        #expect(self.state(AvatarSignals(lastOutcome: .error)) == .idle)
        #expect(AvatarStateMachine.nextTransition(for: AvatarSignals(lastOutcome: .error), now: self.now) == nil)
    }

    /// A clock that runs behind the outcome's timestamp doesn't show a pose early.
    @Test func futureOutcomeIsNotShownYet() {
        let signals = AvatarSignals(lastOutcome: .success, outcomeAt: self.now.addingTimeInterval(10))
        #expect(self.state(signals) == .idle)
    }

    @Test func toolStateCarriesItsKind() {
        #expect(self.state(AvatarSignals(isRunning: true, runningToolName: "ask_user")) == .tool(.question))
        #expect(self.state(AvatarSignals(isRunning: true, runningToolName: "read")) == .tool(.read))
        #expect(self.state(AvatarSignals(isRunning: true, runningToolName: "mystery")) == .tool(.generic))
    }

    @Test func galleryCoversEveryState() {
        let gallery = AvatarState.gallery
        #expect(gallery.count == 8 && gallery.contains(.tool(.exec)))
        #expect(Set(gallery).count == gallery.count)
        for state in [AvatarState.idle, .thinking, .streaming, .awaitingApproval, .success, .error, .compacting] {
            #expect(gallery.contains(state))
        }
        #expect(gallery.contains { if case .tool = $0 { true } else { false } })
    }

    @Test func accessibilityNamesTheAgent() {
        for state in AvatarState.gallery {
            #expect(!state.accessibilityPhrase.isEmpty)
            #expect(state.accessibilityLabel(agentName: "Scout").hasPrefix("Scout "))
        }
        #expect(AvatarState.tool(.exec).accessibilityLabel(agentName: "Forge").contains("exec"))
    }
}

@Suite("Avatar tool kinds")
struct AvatarToolTests {
    @Test(arguments: [
        ("exec", AvatarTool.exec), ("bash", .exec), ("process", .exec), ("EXEC", .exec),
        ("ask_user", .question),
        ("read", .read), ("view_file", .read),
        ("write", .write), ("edit", .write), ("apply_patch", .write),
        ("grep", .search), ("find", .search), ("web_search", .search), ("memory_search", .search),
        ("web_fetch", .web), ("browser", .web),
        ("image", .image), ("canvas", .image),
        ("sessions_spawn", .agent), ("sessions_send", .agent),
        ("memory_get", .memory),
        ("message", .message),
        ("progress_card", .generic), ("cron", .generic), ("", .generic),
    ])
    func kind(name: String, expected: AvatarTool) {
        #expect(AvatarTool.kind(forToolName: name) == expected)
    }

    @Test func everyKindHasASymbol() {
        for tool in AvatarTool.allCases {
            #expect(!tool.symbolName.isEmpty)
        }
        #expect(Set(AvatarTool.allCases.map(\.symbolName)).count == AvatarTool.allCases.count)
    }
}

@Suite("Avatar style")
struct AvatarStyleTests {
    @Test func seededIsDeterministic() {
        for seed in ["Claw", "Scout", "Forge", "main", "", "🦞", "agent:research"] {
            #expect(AvatarStyle.seeded(from: seed) == AvatarStyle.seeded(from: seed))
        }
    }

    /// FNV-1a is fixed, so styles match across launches and devices (unlike `hashValue`).
    @Test func hashIsStable() {
        #expect(AvatarStyle.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(AvatarStyle.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(AvatarStyle.fnv1a("foobar") == 0x85944171F73967E8)
    }

    /// Distinct names don't all get the same pet (no exact outcomes: the art set may still change).
    @Test func namesSpreadAcrossStyles() {
        let names = ["Claw", "Scout", "Forge", "Nova", "Atlas", "Pip", "Juniper", "Echo", "main", "research", "coder"]
        let styles = names.map { AvatarStyle.seeded(from: $0) }
        #expect(Set(styles.map(\.creature)).count > 1)
        #expect(Set(styles.map(\.palette)).count > 1)
        #expect(Set(styles).count > 1)
    }

    @Test func identitySeedPrefersTheName() {
        #expect(AvatarStyle.identitySeed(name: "Scout", agentId: "research") == "Scout")
        #expect(AvatarStyle.identitySeed(name: "  Scout \n", agentId: "research") == "Scout")
    }

    @Test(arguments: [nil, "", "   ", "\n\t"] as [String?])
    func identitySeedFallsBackToTheAgentId(name: String?) {
        #expect(AvatarStyle.identitySeed(name: name, agentId: "research") == "research")
    }

    /// Renaming an agent changes its pet; the same identity always gets the same one.
    @Test func identitySeedDrivesTheStyle() {
        let named = AvatarStyle.seeded(from: AvatarStyle.identitySeed(name: "Scout", agentId: "research"))
        #expect(named == AvatarStyle.seeded(from: "Scout"))
        let unnamed = AvatarStyle.seeded(from: AvatarStyle.identitySeed(name: nil, agentId: "research"))
        #expect(unnamed == AvatarStyle.seeded(from: "research"))
        #expect(named != unnamed)
    }

    /// Distinct identity names (as agents.list reports them) don't all get the same creature.
    @Test func distinctIdentitiesSpreadAcrossCreatures() {
        let agents: [(name: String?, id: String)] = [("Claw", "main"), ("Scout", "research"), ("Forge", "coder"), (nil, "ops"), ("", "qa")]
        let creatures = agents.map { AvatarStyle.seeded(from: AvatarStyle.identitySeed(name: $0.name, agentId: $0.id)).creature }
        #expect(Set(creatures).count > 1)
    }

    @Test func nearbySeedsDiffer() {
        #expect(AvatarStyle.seeded(from: "Scout") != AvatarStyle.seeded(from: "Scout2"))
        #expect(AvatarStyle.fnv1a("Claw") != AvatarStyle.fnv1a("claw"))
    }

    @Test func seededAccessoriesSuitTheCreature() {
        for index in 0..<200 {
            let style = AvatarStyle.seeded(from: "seed-\(index)")
            #expect(AvatarAccessory.allowed(for: style.creature).contains(style.accessory))
        }
    }

    @Test func renderStyleIsPassedThrough() {
        #expect(AvatarStyle.seeded(from: "Claw").renderStyle == .pixel)
        let plush = AvatarStyle.seeded(from: "Claw", renderStyle: .plush)
        #expect(plush.renderStyle == .plush)
        var pixel = plush
        pixel.renderStyle = .pixel
        #expect(pixel == AvatarStyle.seeded(from: "Claw"))
    }

    /// Whatever the pairing rules, a style never ends up wearing something its creature can't.
    @Test func unsuitedAccessoryIsDropped() {
        for creature in AvatarCreature.allCases {
            for accessory in AvatarAccessory.allCases {
                let style = AvatarStyle(creature: creature, accessory: accessory)
                #expect(AvatarAccessory.allowed(for: creature).contains(style.accessory))
                for other in AvatarCreature.allCases {
                    let swapped = style.with(creature: other)
                    #expect(swapped.creature == other && swapped.palette == style.palette)
                    #expect(AvatarAccessory.allowed(for: other).contains(swapped.accessory))
                }
            }
        }
    }

    @Test func everyCreatureAllowsNoAccessory() {
        for creature in AvatarCreature.allCases {
            #expect(AvatarAccessory.allowed(for: creature).contains(.none))
        }
    }

    @Test func codableRoundTrip() throws {
        let style = AvatarStyle.seeded(from: "Scout", renderStyle: .plush)
        let decoded = try JSONDecoder().decode(AvatarStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded == style)
    }
}

@MainActor
@Suite("Chat avatar signals")
struct ChatAvatarSignalsTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)
    static let key = "agent:research:main"

    func chat() -> ChatStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        return store.chat(for: Self.key)
    }

    func chatEvent(_ chat: ChatStore, _ runId: String, _ fields: [String: JSONValue]) {
        var payload = fields
        payload["runId"] = .string(runId)
        payload["sessionKey"] = .string(Self.key)
        chat.handleChat(.object(payload))
    }

    func agentEvent(_ chat: ChatStore, _ runId: String, stream: String, _ data: JSONValue) {
        chat.handleAgent(["runId": .string(runId), "sessionKey": .string(Self.key), "stream": .string(stream), "data": data])
    }

    func state(_ chat: ChatStore, at date: Date = Date()) -> AvatarState {
        AvatarStateMachine.state(for: chat.avatarSignals, now: date)
    }

    static func assistant(thinking: String? = nil, text: String? = nil) -> JSONValue {
        var content: [JSONValue] = []
        if let thinking { content.append(["type": "thinking", "thinking": .string(thinking)]) }
        if let text { content.append(["type": "text", "text": .string(text)]) }
        return ["role": "assistant", "content": .array(content)]
    }

    @Test func freshChatIsIdle() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        #expect(chat.avatarSignals == .idle)
        #expect(self.state(chat) == .idle)
    }

    /// thinking → tool → streaming → success, the way a run with a tool call reports itself.
    @Test func runWalksThroughStates() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.chatEvent(chat, "run_1", ["state": "status", "phase": "starting_model"])
        #expect(chat.avatarSignals.isRunning)
        #expect(self.state(chat) == .thinking)

        self.chatEvent(chat, "run_1", ["state": "delta", "deltaText": "",
                                       "message": Self.assistant(thinking: "Looking at the disk")])
        #expect(chat.avatarSignals.isThinking && !chat.avatarSignals.isStreaming)
        #expect(self.state(chat) == .thinking)

        self.agentEvent(chat, "run_1", stream: "tool",
                        ["phase": "start", "name": "exec", "toolCallId": "call_1", "args": ["command": "df -h"]])
        #expect(chat.avatarSignals.runningToolName == "exec")
        #expect(self.state(chat) == .tool(.exec))

        self.agentEvent(chat, "run_1", stream: "tool",
                        ["phase": "result", "name": "exec", "toolCallId": "call_1", "isError": false, "result": "ok"])
        #expect(chat.avatarSignals.runningToolName == nil)

        self.chatEvent(chat, "run_1", ["state": "delta", "deltaText": "Disk",
                                       "message": Self.assistant(thinking: "Looking at the disk", text: "Disk")])
        #expect(chat.avatarSignals.isStreaming)
        #expect(self.state(chat) == .streaming)

        let before = Date()
        self.chatEvent(chat, "run_1", ["state": "final", "message": Self.assistant(text: "Disk looks fine.")])
        self.agentEvent(chat, "run_1", stream: "lifecycle", ["phase": "end"])
        let signals = chat.avatarSignals
        #expect(!signals.isRunning && !signals.isStreaming && !signals.isThinking && signals.runningToolName == nil)
        #expect(signals.lastOutcome == .success)
        #expect(signals.outcomeAt != nil)
        let at = signals.outcomeAt ?? .distantPast
        #expect(at >= before)
        #expect(self.state(chat, at: at) == .success)
        #expect(self.state(chat, at: at.addingTimeInterval(AvatarStateMachine.successDuration + 0.1)) == .idle)
    }

    @Test func latestRunningToolWins() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.agentEvent(chat, "run_1", stream: "tool", ["phase": "start", "name": "web_fetch", "toolCallId": "a"])
        self.agentEvent(chat, "run_1", stream: "tool", ["phase": "start", "name": "read", "toolCallId": "b"])
        #expect(self.state(chat) == .tool(.read))
        self.agentEvent(chat, "run_1", stream: "tool", ["phase": "result", "name": "read", "toolCallId": "b", "isError": false])
        #expect(self.state(chat) == .tool(.web))
    }

    @Test func failedRunShowsError() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.chatEvent(chat, "run_2", ["state": "status", "phase": "starting_model"])
        self.chatEvent(chat, "run_2", ["state": "error", "errorMessage": "LLM request timed out.", "errorKind": "timeout"])
        self.agentEvent(chat, "run_2", stream: "lifecycle", ["phase": "error", "error": "LLM request timed out."])
        let signals = chat.avatarSignals
        #expect(signals.lastOutcome == .error)
        #expect(!signals.isRunning)
        let at = signals.outcomeAt ?? Date()
        #expect(self.state(chat, at: at) == .error)
        #expect(self.state(chat, at: at.addingTimeInterval(AvatarStateMachine.errorDuration + 0.1)) == .idle)
    }

    /// Only the lifecycle stream reports the failure (no chat `error`): still an error.
    @Test func lifecycleErrorAloneShowsError() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.agentEvent(chat, "run_3", stream: "tool", ["phase": "start", "name": "exec", "toolCallId": "c"])
        self.agentEvent(chat, "run_3", stream: "lifecycle", ["phase": "error"])
        #expect(chat.avatarSignals.lastOutcome == .error)
        #expect(self.state(chat, at: chat.avatarSignals.outcomeAt ?? Date()) == .error)
    }

    /// A `chat` final followed by a lifecycle `error` for the same run keeps the first outcome.
    @Test func outcomeIsRecordedOncePerRun() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.chatEvent(chat, "run_4", ["state": "final", "message": Self.assistant(text: "done")])
        self.agentEvent(chat, "run_4", stream: "lifecycle", ["phase": "error"])
        #expect(chat.avatarSignals.lastOutcome == .success)
    }

    @Test func abortedRunIsNotASuccess() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.chatEvent(chat, "run_5", ["state": "delta", "deltaText": "Hal", "message": Self.assistant(text: "Hal")])
        self.chatEvent(chat, "run_5", ["state": "aborted"])
        self.agentEvent(chat, "run_5", stream: "lifecycle", ["phase": "end"])
        #expect(chat.avatarSignals.lastOutcome == .none)
        #expect(self.state(chat) == .idle)
    }

    @Test func compactionShowsCompacting() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.agentEvent(chat, "run_6", stream: "compaction", ["phase": "start"])
        #expect(chat.avatarSignals.isCompacting)
        #expect(self.state(chat) == .compacting)
        self.agentEvent(chat, "run_6", stream: "compaction", ["phase": "end", "completed": true])
        #expect(!chat.avatarSignals.isCompacting)
    }

    /// A new run after a success replaces the success pose right away.
    @Test func newRunReplacesSuccess() {
        defer { self.scratch.remove() }
        let chat = self.chat()
        self.chatEvent(chat, "run_7", ["state": "final", "message": Self.assistant(text: "one")])
        self.agentEvent(chat, "run_7", stream: "lifecycle", ["phase": "end"])
        #expect(self.state(chat, at: chat.avatarSignals.outcomeAt ?? Date()) == .success)
        self.chatEvent(chat, "run_8", ["state": "status", "phase": "starting_model"])
        #expect(self.state(chat, at: chat.avatarSignals.outcomeAt ?? Date()) == .thinking)
    }
}
