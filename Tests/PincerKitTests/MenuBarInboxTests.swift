import Foundation
import Testing
@testable import PincerKit

@Suite("Menu bar inbox")
struct MenuBarInboxTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let nowMs = 1_000_000_000.0

    static func row(_ key: String, _ fields: String = "", age: Double = 0) -> SessionRow {
        let extra = fields.isEmpty ? "" : ",\(fields)"
        return SessionRow(Fixtures.json(#"{"key":"\#(key)","updatedAt":\#(Self.nowMs - age)\#(extra)}"#))!
    }

    static func approval(_ id: String, command: String = "rm -rf ./build", session: String? = nil,
                         expiresAtMs: Double? = nil) -> ExecApproval
    {
        let sessionField = session.map { #","sessionKey":"\#($0)""# } ?? ""
        let expiry = expiresAtMs.map { #","expiresAtMs":\#($0)"# } ?? ""
        return ExecApproval(Fixtures.json(#"{"id":"\#(id)","request":{"command":"\#(command)"\#(sessionField)}\#(expiry)}"#))!
    }

    static func question(_ id: String, text: String = "What do you want removed?", session: String? = nil,
                         status: String = "pending", expiresAtMs: Double? = nil) -> QuestionPrompt
    {
        let sessionField = session.map { #","sessionKey":"\#($0)""# } ?? ""
        let expiry = expiresAtMs.map { #","expiresAtMs":\#($0)"# } ?? ""
        return QuestionPrompt(Fixtures.json(#"""
        {"id":"\#(id)","status":"\#(status)"\#(sessionField)\#(expiry),
         "questions":[{"questionId":"q","header":"Cleanup","question":"\#(text)","options":[]}]}
        """#))!
    }

    static let agents = [AgentSummary(id: "main", name: "Claw", emoji: "🦞"), AgentSummary(id: "coder", name: "Forge")]

    static func gateway(_ name: String = "Home", state: ConnectionState = .connected, sessions: [SessionRow] = [],
                        approvals: [ExecApproval] = [], questions: [QuestionPrompt] = []) -> MenuBarInbox.GatewayInput
    {
        MenuBarInbox.GatewayInput(name: name, state: state, sessions: sessions, approvals: approvals, questions: questions,
                                  agents: Self.agents)
    }

    static func build(_ gateways: MenuBarInbox.GatewayInput...) -> MenuBarInbox {
        MenuBarInbox.build(gateways, now: Self.now)
    }

    // MARK: Sections and caps

    @Test func approvalsBeforeQuestions() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main")],
                                            approvals: [Self.approval("a1"), Self.approval("a2", command: "ls")],
                                            questions: [Self.question("q1")]))
        #expect(inbox.needsYou.map(\.kind) == [.approval, .approval, .question])
        #expect(inbox.needsYou.map(\.title) == ["Approve: rm -rf ./build", "Approve: ls", "Question: What do you want removed?"])
        #expect(inbox.needsYouCount == 3 && inbox.needsYouOverflow == 0)
    }

    @Test func approvalsFromEveryGatewayComeBeforeAnyQuestion() {
        let home = Self.gateway("Home", approvals: [Self.approval("a1")], questions: [Self.question("q1")])
        let work = Self.gateway("Work", approvals: [Self.approval("a2")])
        let inbox = Self.build(home, work)
        #expect(inbox.needsYou.map(\.kind) == [.approval, .approval, .question])
        #expect(inbox.needsYou.map(\.target.gatewayId) == [home.id, work.id, home.id])
    }

    @Test func expiredAndUnanswerableAreDropped() {
        let inbox = Self.build(Self.gateway(
            approvals: [Self.approval("old", expiresAtMs: Self.nowMs - 1), Self.approval("live", expiresAtMs: Self.nowMs + 60_000),
                        Self.approval("forever")],
            questions: [Self.question("answered", status: "answered"), Self.question("late", expiresAtMs: Self.nowMs - 1),
                        Self.question("open", expiresAtMs: Self.nowMs + 60_000)]))
        #expect(inbox.needsYou.map(\.id).map { $0.split(separator: ":").last.map(String.init) } == ["live", "forever", "open"])
        #expect(inbox.needsYouCount == 3)
    }

    @Test func capsAndOverflow() {
        let approvals = (1...7).map { Self.approval("a\($0)") }
        let running = (1...6).map { Self.row("agent:main:run\($0)", #""hasActiveRun":true"#, age: Double($0)) }
        let unread = (1...10).map { Self.row("agent:main:unread\($0)", #""unread":true"#, age: Double(100 + $0)) }
        let inbox = Self.build(Self.gateway(sessions: running + unread, approvals: approvals))
        #expect(inbox.needsYou.count == 5 && inbox.needsYouOverflow == 2 && inbox.needsYouCount == 7)
        #expect(inbox.running.count == 5 && inbox.runningOverflow == 1)
        #expect(inbox.unread.count == 8 && inbox.unreadOverflow == 2 && inbox.unreadCount == 10)
        #expect(MenuBarInbox.needsYouLimit == 5 && MenuBarInbox.runningLimit == 5 && MenuBarInbox.unreadLimit == 8)
    }

    @Test func needsYouCapSpillsQuestionsIntoOverflow() {
        let inbox = Self.build(Self.gateway(approvals: (1...4).map { Self.approval("a\($0)") },
                                            questions: (1...3).map { Self.question("q\($0)") }))
        #expect(inbox.needsYou.map(\.kind) == [.approval, .approval, .approval, .approval, .question])
        #expect(inbox.needsYouOverflow == 2 && inbox.needsYouCount == 7)
    }

    @Test func runningCapKeepsTheNewest() {
        let running = (1...7).map { Self.row("agent:main:run\($0)", #""hasActiveRun":true"#, age: Double(10 * $0)) }
        let inbox = Self.build(Self.gateway(sessions: running.reversed()))
        #expect(inbox.running.map(\.target.sessionKey) == (1...5).map { "agent:main:run\($0)" })
        #expect(inbox.runningOverflow == 2 && inbox.running.allSatisfy { $0.kind == .running })
    }

    /// The Gateway never sends an empty question, but a blank one falls back to the header.
    @Test func questionFallsBackToHeader() {
        let inbox = Self.build(Self.gateway(questions: [Self.question("q1", text: "  ")]))
        #expect(inbox.needsYou.map(\.title) == ["Question: Cleanup"])
    }

    @Test func questionWithUnknownChatHasNoSuffixAndClaimsNothing() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main", #""unread":true"#)],
                                            questions: [Self.question("q1"), Self.question("q2", session: "agent:main:gone")]))
        #expect(inbox.needsYou.map(\.title) == ["Question: What do you want removed?", "Question: What do you want removed?"])
        #expect(inbox.needsYou.map(\.target.sessionKey) == ["", "agent:main:gone"])
        #expect(inbox.unread.map(\.target.sessionKey) == ["agent:main:main"])
    }

    @Test func itemIdsAreUniqueAcrossGateways() {
        let home = Self.gateway("Home", sessions: [Self.row("agent:main:main", #""unread":true"#)], approvals: [Self.approval("a1")])
        let work = Self.gateway("Work", sessions: [Self.row("agent:main:main", #""unread":true"#)], approvals: [Self.approval("a1")])
        let inbox = Self.build(home, work)
        let ids = (inbox.needsYou + inbox.running + inbox.unread).map(\.id)
        #expect(ids.count == 4 && Set(ids).count == 4)
    }

    // MARK: Dedupe

    @Test func questionClaimsARunningChat() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main", #""hasActiveRun":true,"unread":true"#)],
                                            questions: [Self.question("q1", session: "agent:main:main")]))
        #expect(inbox.needsYou.count == 1 && inbox.running.isEmpty && inbox.unread.isEmpty && inbox.unreadCount == 1)
    }

    @Test func sectionsDedupeInPriorityOrder() {
        let sessions = [
            Self.row("agent:main:blocked", #""unread":true,"hasActiveRun":true"#),
            Self.row("agent:main:busy", #""unread":true,"hasActiveRun":true"#),
            Self.row("agent:main:quiet", #""unread":true"#),
        ]
        let inbox = Self.build(Self.gateway(sessions: sessions, approvals: [Self.approval("a1", session: "agent:main:blocked")]))
        #expect(inbox.needsYou.map(\.target.sessionKey) == ["agent:main:blocked"])
        #expect(inbox.running.map(\.target.sessionKey) == ["agent:main:busy"])
        #expect(inbox.unread.map(\.target.sessionKey) == ["agent:main:quiet"])
        #expect(inbox.unreadCount == 3)
    }

    @Test func questionsAlsoClaimTheirChat() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main", #""unread":true"#)],
                                            questions: [Self.question("q1", session: "agent:main:main")]))
        #expect(inbox.needsYou.count == 1 && inbox.unread.isEmpty && inbox.unreadCount == 1)
    }

    @Test func twoApprovalsInOneChatGetTwoRows() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main")],
                                            approvals: [Self.approval("a1", session: "agent:main:main"),
                                                        Self.approval("a2", command: "ls", session: "agent:main:main")]))
        #expect(inbox.needsYou.count == 2 && Set(inbox.needsYou.map(\.id)).count == 2)
        #expect(inbox.needsYou.allSatisfy { $0.target.sessionKey == "agent:main:main" })
    }

    @Test func sameChatOnTwoGatewaysIsNotDeduped() {
        let home = Self.gateway("Home", sessions: [Self.row("agent:main:main", #""unread":true"#)],
                                approvals: [Self.approval("a1", session: "agent:main:main")])
        let work = Self.gateway("Work", sessions: [Self.row("agent:main:main", #""unread":true"#)])
        let inbox = Self.build(home, work)
        #expect(inbox.needsYou.count == 1 && inbox.unread.map(\.target.gatewayId) == [work.id])
    }

    // MARK: Filters and sorting

    @Test func archivedAndSubagentRowsAreLeftOut() {
        let sessions = [
            Self.row("agent:main:old", #""unread":true,"hasActiveRun":true,"archived":true"#),
            Self.row("agent:main:subagent:abc", #""unread":true,"hasActiveRun":true"#),
            Self.row("agent:main:main", #""unread":true"#),
        ]
        let inbox = Self.build(Self.gateway(sessions: sessions))
        #expect(inbox.running.isEmpty && inbox.unread.map(\.target.sessionKey) == ["agent:main:main"] && inbox.unreadCount == 1)
    }

    @Test func newestFirstAcrossGateways() {
        let home = Self.gateway("Home", sessions: [Self.row("agent:main:a", #""unread":true"#, age: 3_000),
                                                   Self.row("agent:main:b", #""unread":true"#, age: 1_000)])
        let work = Self.gateway("Work", sessions: [Self.row("agent:main:c", #""unread":true"#, age: 2_000),
                                                   Self.row("agent:main:d", #""hasActiveRun":true"#, age: 5_000),
                                                   Self.row("agent:main:e", #""hasActiveRun":true"#, age: 500)])
        let inbox = Self.build(home, work)
        #expect(inbox.unread.map(\.target.sessionKey) == ["agent:main:b", "agent:main:c", "agent:main:a"])
        #expect(inbox.running.map(\.target.sessionKey) == ["agent:main:e", "agent:main:d"])
    }

    // MARK: Counts

    @Test func unreadCountMatchesTotalUnreadFilter() {
        let sessions = [
            Self.row("agent:main:a", #""unread":true"#),
            Self.row("agent:main:b", #""unread":true,"archived":true"#),
            Self.row("agent:main:subagent:x", #""unread":true"#),
            Self.row("agent:main:c", #""unread":true,"hasActiveRun":true"#),
            Self.row("agent:main:d"),
        ]
        let expected = sessions.filter { $0.isUnread && !$0.isArchived && !$0.isSubagent }.count
        let inbox = Self.build(Self.gateway(sessions: sessions))
        #expect(inbox.unreadCount == expected && expected == 2)
        #expect(inbox.unread.count == 1 && inbox.running.count == 1)
    }

    @Test func badgeAndAccessibility() {
        var inbox = MenuBarInbox()
        #expect(inbox.badgeText == nil && inbox.accessibilityLabel == "Pincer")
        inbox.unreadCount = 2
        inbox.needsYouCount = 1
        #expect(inbox.badgeText == "3" && inbox.accessibilityLabel == "Pincer, 2 unread, 1 needs you")
        inbox.needsYouCount = 3
        #expect(inbox.accessibilityLabel == "Pincer, 2 unread, 3 need you")
        inbox.unreadCount = 0
        #expect(inbox.accessibilityLabel == "Pincer, 3 need you")
        inbox.unreadCount = 97
        #expect(inbox.badgeText == "99+")
        inbox.unreadCount = 96
        #expect(inbox.badgeText == "99")
    }

    // MARK: Connection

    @Test func disconnectedGatewayOnlyShowsStatus() {
        let offline = Self.gateway("Work", state: .reconnecting(attempt: 1, delaySeconds: 2, reason: "x"),
                                   sessions: [Self.row("agent:main:a", #""unread":true,"hasActiveRun":true"#)],
                                   approvals: [Self.approval("a1")], questions: [Self.question("q1")])
        let inbox = Self.build(offline)
        #expect(inbox.isEmpty && inbox.unreadCount == 0 && inbox.needsYouCount == 0)
        #expect(!inbox.hasConnectedGateway && !inbox.isCaughtUp)
        #expect(inbox.gateways.map(\.title) == ["Work — Reconnecting…"] && inbox.gateways.first?.id == offline.id)
    }

    @Test func caughtUp() {
        let quiet = Self.build(Self.gateway(sessions: [Self.row("agent:main:main")]))
        #expect(quiet.isEmpty && quiet.isCaughtUp)
        let busy = Self.build(Self.gateway(sessions: [Self.row("agent:main:main", #""unread":true"#)]))
        #expect(!busy.isEmpty && !busy.isCaughtUp)
        let none = Self.build()
        #expect(none.isEmpty && !none.isCaughtUp && none.gateways.isEmpty)
    }

    // MARK: Labels

    @Test func emojiFollowsTheAgent() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:discord:channel:1", #""label":"home-lab","unread":true"#, age: 1),
                                                       Self.row("agent:coder:main", #""label":"Main","unread":true"#, age: 2),
                                                       Self.row("agent:research:x", #""label":"Paper digest","unread":true"#, age: 3)]))
        #expect(inbox.unread.map(\.title) == ["🦞 home-lab · Claw", "Main · Forge", "Paper digest · Research"])
    }

    @Test func gatewaySuffixOnlyWithSeveralGateways() {
        let sessions = [Self.row("agent:main:main", #""label":"Inbox","unread":true"#)]
        let single = Self.build(Self.gateway("Home", sessions: sessions, approvals: [Self.approval("a1")]))
        #expect(single.unread.map(\.title) == ["🦞 Inbox · Claw"] && single.needsYou.map(\.title) == ["Approve: rm -rf ./build"])
        let multi = Self.build(Self.gateway("Home", sessions: sessions, approvals: [Self.approval("a1")]),
                               Self.gateway("Work", state: .failed("bad token")))
        #expect(multi.unread.map(\.title) == ["🦞 Inbox · Claw — Home"] && multi.needsYou.map(\.title) == ["Approve: rm -rf ./build — Home"])
    }

    @Test func approvalAndQuestionNameTheirChat() {
        let sessions = [Self.row("agent:coder:main", #""label":"Main""#)]
        let inbox = Self.build(Self.gateway("Main", sessions: sessions,
                                            approvals: [Self.approval("a1", session: "agent:coder:main")],
                                            questions: [Self.question("q1", session: "agent:coder:main")]),
                               Self.gateway("Work"))
        #expect(inbox.needsYou.map(\.title) == ["Approve: rm -rf ./build — Main · Forge — Main",
                                                "Question: What do you want removed? — Main · Forge — Main"])
    }

    @Test func truncation() {
        let longTitle = String(repeating: "t", count: 50)
        let longCommand = "echo " + String(repeating: "x", count: 60)
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:a", #""label":"\#(longTitle)","unread":true"#)],
                                            approvals: [Self.approval("a1", command: longCommand)]))
        #expect(inbox.unread.first?.title == "🦞 " + String(repeating: "t", count: 39) + "… · Claw")
        #expect(inbox.needsYou.first?.title == "Approve: " + String(longCommand.prefix(39)) + "…")
        #expect(MenuBarInbox.truncated(String(repeating: "a", count: 40)) == String(repeating: "a", count: 40))
        #expect(MenuBarInbox.truncated("two\nlines  here") == "two lines here")
        #expect(MenuBarInbox.truncated(String(repeating: "a", count: 38) + " bcd") == String(repeating: "a", count: 38) + "…")
    }

    @Test func unknownOrMissingSessionKey() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:main")],
                                            approvals: [Self.approval("none"), Self.approval("gone", session: "agent:main:gone")]))
        #expect(inbox.needsYou.map(\.title) == ["Approve: rm -rf ./build", "Approve: rm -rf ./build"])
        #expect(inbox.needsYou.map(\.target.sessionKey) == ["", "agent:main:gone"])
    }

    @Test func sessionKeysMatchCaseInsensitively() {
        let inbox = Self.build(Self.gateway(sessions: [Self.row("agent:main:Trip", #""label":"Trip","unread":true"#)],
                                            approvals: [Self.approval("a1", session: "agent:main:trip")]))
        #expect(inbox.needsYou.first?.target.sessionKey == "agent:main:Trip" && inbox.needsYou.first?.title.hasSuffix("— 🦞 Trip · Claw") == true)
        #expect(inbox.unread.isEmpty)
    }

    // MARK: Status

    @Test func statusText() {
        typealias Level = MenuBarInbox.GatewayStatus.Level
        let cases: [(ConnectionState, GatewayHealthLevel, String, String, Level)] = [
            (.connected, .healthy, "Connected", "checkmark.circle", .ok),
            (.connected, .degraded, "Degraded", "exclamationmark.triangle", .warning),
            (.connected, .restarting, "Restarting…", "arrow.clockwise.circle", .pending),
            (.reconnecting(attempt: 1, delaySeconds: 1, reason: "restart"), .restarting, "Restarting…", "arrow.clockwise.circle", .pending),
            (.idle, .down, "Connecting…", "circle.dotted", .pending),
            (.connecting, .down, "Connecting…", "circle.dotted", .pending),
            (.reconnecting(attempt: 2, delaySeconds: 4, reason: "x"), .down, "Reconnecting…", "exclamationmark.triangle", .warning),
            (.awaitingPairing(requestId: "r", deviceId: "d"), .down, "Waiting for approval", "hourglass", .pending),
            (.failed("unauthorized: a very long reason"), .down, "Can't connect", "xmark.circle", .error),
        ]
        for (state, health, text, symbol, level) in cases {
            let status = MenuBarInbox.statusText(state: state, healthLevel: health)
            #expect(status.text == text && status.symbol == symbol && status.level == level, "\(state) / \(health)")
        }
    }

    @Test func buildUsesEachGatewaysHealth() {
        let degraded = MenuBarInbox.GatewayInput(name: "Home", state: .connected, healthLevel: .degraded,
                                                 sessions: [Self.row("agent:main:main", #""unread":true"#)])
        let inbox = Self.build(degraded)
        #expect(inbox.gateways.map(\.title) == ["Home — Degraded"] && inbox.gateways.first?.level == .warning)
        #expect(inbox.unread.count == 1 && inbox.hasConnectedGateway, "a degraded but connected gateway still lists rows")
    }

    @Test func gatewaysKeepRailOrder() {
        let inbox = Self.build(Self.gateway("Home"), Self.gateway("Work", state: .connecting), Self.gateway("Demo"))
        #expect(inbox.gateways.map(\.title) == ["Home — Connected", "Work — Connecting…", "Demo — Connected"])
    }

    // MARK: Settings

    @Test func settingsDefaultOffAndRoundTrip() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let settings = MenuBarSettings(defaults: scratch.defaults)
        #expect(!settings.isEnabled && MenuBarSettings.enabledKey == "pincer.menuBar.enabled")
        settings.isEnabled = true
        #expect(MenuBarSettings(defaults: scratch.defaults).isEnabled && scratch.defaults.bool(forKey: "pincer.menuBar.enabled"))
        settings.isEnabled = false
        #expect(!MenuBarSettings(defaults: scratch.defaults).isEnabled)
    }
}
