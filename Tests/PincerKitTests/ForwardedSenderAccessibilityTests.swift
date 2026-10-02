import Foundation
import Testing
@testable import PincerKit

@Suite("Forwarded sender accessibility author")
struct ForwardedSenderAccessibilityTests {
    private let agents = [
        AgentSummary(id: "main", name: "Main"),
        AgentSummary(id: "kiko", name: "Kiko"),
    ]

    @Test func onlyKnownOtherAgentUsesCompactForwardedMarker() {
        let kiko = MessageSender(kind: .agent, sessionKey: "agent:kiko:main", agentId: "kiko")
        #expect(kiko.accessibilityAuthor(agents: self.agents, receivingAgentId: "main") == "Kiko, forwarded")

        let sameAgent = MessageSender(kind: .agent, sessionKey: "agent:main:other", agentId: "main")
        #expect(sameAgent.accessibilityAuthor(agents: self.agents, receivingAgentId: "main") == "Main, from another chat")

        let namedUnknownAgent = MessageSender(kind: .agent, sessionKey: "agent:scout:main", agentId: "scout")
        #expect(namedUnknownAgent.accessibilityAuthor(agents: self.agents, receivingAgentId: "main")
                == "Scout, forwarded")
        #expect(namedUnknownAgent.accessibilityAuthor(agents: [], receivingAgentId: "main", resolvedName: "Scout")
                == "Scout, forwarded", "the renderer can reuse the already resolved header name")
    }

    @Test func helperAutomationAndUnknownSourcesKeepTheirContext() {
        let helper = MessageSender(kind: .helper, sessionKey: "agent:main:subagent:abc", label: "Research helper")
        #expect(helper.accessibilityAuthor(agents: self.agents, receivingAgentId: "main") == "Research helper, from a helper")

        let automation = MessageSender(kind: .automation, label: "Morning briefing")
        #expect(automation.accessibilityAuthor(agents: self.agents, receivingAgentId: "main")
                == "Morning briefing, from an automation")

        let unknown = MessageSender(kind: .agent)
        #expect(unknown.accessibilityAuthor(agents: self.agents, receivingAgentId: "main")
                == "Another agent, from another agent")
    }
}
