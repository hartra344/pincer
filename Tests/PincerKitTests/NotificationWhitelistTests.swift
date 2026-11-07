import Foundation
import Testing
import UserNotifications
@testable import PincerKit

/// The agent notification whitelist (#1100): only whitelisted agents' reply and activity reports
/// notify; approvals and questions are exempt, and so are sessions whose key is not an agent key.
/// The live post path reads `UserDefaults.standard`, so behaviour-level tests never write defaults
/// — the default whitelist (main, wx-assistant) is the fixture. Tests run without a bundle, so the
/// notifier's real center is nil and `postingProbe` records what `center.add` would have posted.
@MainActor
struct NotificationWhitelistTests {
    /// What passed every gate; a class so the probe closure and the test share one array.
    private final class Posted {
        var ids: [String] = []
    }

    /// A demo gateway with a fresh notifier wired in. The store never starts, so nothing touches
    /// the network; `stop()` and the scratch suite are still cleaned up.
    private func withPostingGateway(_ body: (GatewayStore, Notifier, Posted) async throws -> Void) async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil
        defer { gateway.stop(); scratch.remove() }
        let notifier = Notifier()
        gateway.notifier = notifier
        let posted = Posted()
        notifier.postingProbe = { posted.ids.append($0) }
        try await body(gateway, notifier, posted)
    }

    private func row(_ key: String) -> SessionRow? {
        SessionRow(["key": key, "updatedAt": .number(1_700_000_000_000), "unread": true])
    }

    @Test func whitelistedAgentsPostTheirReports() async throws {
        try await self.withPostingGateway { gateway, notifier, posted in
            let main = try #require(self.row("agent:main:dashboard:trip"))
            let sub = try #require(self.row("agent:main:main:sub"))
            let green = try #require(self.row("agent:wx-assistant:chat:1"))
            notifier.notifyReply(row: main, text: "Trip booked", dedupe: "run-1", gateway: gateway)
            notifier.notifyActivity(row: sub, gateway: gateway)
            notifier.notifyReply(row: green, text: "Reported back", dedupe: "run-2", gateway: gateway)
            notifier.notifyActivity(row: green, gateway: gateway)
            #expect(posted.ids == [
                "reply:run-1",
                "reply:agent:main:main:sub:1700000000000",
                "reply:run-2",
                "reply:agent:wx-assistant:chat:1:1700000000000",
            ])
        }
    }

    @Test func otherAgentsStaySilent() async throws {
        try await self.withPostingGateway { gateway, notifier, posted in
            let writer = try #require(self.row("agent:dev-writer:task:1"))
            notifier.notifyReply(row: writer, text: "Progress", dedupe: nil, gateway: gateway)
            notifier.notifyActivity(row: writer, gateway: gateway)
            #expect(posted.ids.isEmpty, "a non-whitelisted agent's reply and activity stay quiet")
        }
    }

    @Test func approvalsAndQuestionsExemptNonWhitelistedAgents() async throws {
        try await self.withPostingGateway { gateway, notifier, posted in
            let approval = try #require(ExecApproval(Fixtures.json(
                #"{"id": "a1", "command": "deploy", "sessionKey": "agent:dev-writer:task:1"}"#)))
            notifier.notifyApproval(approval, gateway: gateway)
            let prompt = try #require(QuestionPrompt(Fixtures.json(
                #"{"id": "q1", "agentId": "dev-writer", "sessionKey": "agent:dev-writer:task:1", "questions": [{"questionId": "q1", "question": "Keep going?"}]}"#)))
            notifier.notifyQuestion(prompt, gateway: gateway)
            #expect(posted.ids == ["approval:a1", "question:q1"],
                    "approvals and questions post even for agents outside the whitelist")
        }
    }

    @Test func backgroundBatchFiltersReportsAndKeepsTheRest() async throws {
        try await self.withPostingGateway { gateway, notifier, posted in
            let writerReply = Notifier.replyContent(
                id: "reply:agent:dev-writer:task:1:1700000000000", title: "dev-writer · Dev Writer",
                body: "Progress", target: Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:dev-writer:task:1"))
            let mainReply = Notifier.replyContent(
                id: "reply:agent:main:dashboard:trip:1700000000000", title: "main · Main",
                body: "Trip booked", target: Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:main:dashboard:trip"))
            let approval = try #require(ExecApproval(Fixtures.json(#"{"id": "a2", "command": "deploy"}"#)))
            let prompt = try #require(QuestionPrompt(Fixtures.json(
                #"{"id": "q2", "questions": [{"questionId": "q2", "question": "Ship it?"}]}"#)))
            let question = try #require(Notifier.questionRequest(
                prompt, gatewayId: gateway.id, agent: AgentSummary(id: "dev-writer", name: "Dev Writer"), chatTitle: nil))
            let content = UNMutableNotificationContent()
            content.title = "Demo"
            content.body = "And 2 more chats"
            let summary = UNNotificationRequest(identifier: "refresh-summary:1:2", content: content, trigger: nil)
            await notifier.postBackground([writerReply, mainReply, Notifier.approvalRequest(
                approval, gatewayId: gateway.id, gatewayName: "Demo"), question, summary])
            #expect(posted.ids == [
                "reply:agent:main:dashboard:trip:1700000000000",
                "approval:a2",
                "question:q2",
                "refresh-summary:1:2",
            ], "the whitelisted report posts, the non-whitelisted one is dropped, exemptions pass")
        }
    }

    @Test func storedWhitelistOverridesTheDefault() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        scratch.defaults.set(["main"], forKey: "pincer.notificationAgentWhitelist")
        let whitelist = Notifier.notificationAgentWhitelist(defaults: scratch.defaults)
        #expect(whitelist == ["main"])
        #expect(Notifier.allowsReply(sessionKey: "agent:main:dashboard:x", whitelist: whitelist))
        #expect(!Notifier.allowsReply(sessionKey: "agent:wx-assistant:main:1", whitelist: whitelist))
    }

    @Test func unsetWhitelistUsesTheDefaultAgents() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(Notifier.notificationAgentWhitelist(defaults: scratch.defaults) == ["main", "wx-assistant"])
    }

    @Test func nonAgentSessionsAlwaysPassAndPrefixesMatchWholeIds() {
        // The whitelist governs agent reports only; other keys are never agent reports.
        for key in ["main", "global", "discord:channel:42"] {
            #expect(Notifier.allowsReply(sessionKey: key, whitelist: []), "\(key) is not an agent key")
        }
        // Prefixes match whole agent ids, not substrings; sub-sessions belong to their agent.
        #expect(!Notifier.allowsReply(sessionKey: "agent:mainx:1", whitelist: ["main"]))
        #expect(Notifier.allowsReply(sessionKey: "agent:main:main:sub", whitelist: ["main"]))
        #expect(!Notifier.allowsReply(sessionKey: "agent:dev-writer:task:1", whitelist: ["main", "wx-assistant"]))
    }
}
