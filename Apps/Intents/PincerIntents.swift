import AppIntents
import Foundation
import PincerKit

// Actions for Shortcuts, Siri, Spotlight and the Action Button. Anything that reads replies or
// sends as you requires the device to be unlocked: agents can run commands on your machines.
// Reply text is never logged.

struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Agent"
    static let description = IntentDescription("Sends a prompt to an agent's main chat and returns its reply.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Prompt", requestValueDialog: "What do you want to ask?")
    var prompt: String

    @Parameter(title: "Agent", description: "Defaults to the Gateway's default agent.")
    var agent: AgentEntity?

    @Parameter(title: "Gateway", description: "Used when no agent is chosen. Defaults to the selected Gateway.")
    var gateway: GatewayEntity?

    @Parameter(title: "Wait for Reply", default: true)
    var waitForReply: Bool

    @Parameter(title: "Timeout (seconds)", default: 60, inclusiveRange: (5, 300))
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) \(\.$prompt)") {
            \.$gateway
            \.$waitForReply
            \.$timeoutSeconds
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await PincerIntentService.make().ask(
            self.prompt, agentId: self.agent?.agentId, agentName: self.agent?.name,
            gatewayId: self.agent?.gatewayId ?? self.gateway?.gatewayId,
            gatewayName: self.agent?.gatewayName ?? self.gateway?.name,
            waitForReply: self.waitForReply, timeoutSeconds: self.timeoutSeconds)
        guard self.waitForReply else {
            return .result(value: "", dialog: "Sent to \(result.agentName).")
        }
        let spoken = IntentService.spoken(result.text)
        return .result(value: result.text, dialog: spoken.isEmpty ? "\(result.agentName) replied without text." : "\(spoken)")
    }
}

/// Requires authentication too: a message can make an agent act, so it shouldn't be sendable
/// from a locked device.
struct SendToChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to Chat"
    static let description = IntentDescription("Sends a message to a chat without waiting for the reply.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat")
    var chat: ChatEntity

    @Parameter(title: "Message", requestValueDialog: "What should I send?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$chat)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PincerIntentService.make().send(self.message, to: self.chat.chat)
        return .result(dialog: "Sent.")
    }
}

struct StartChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Chat with Agent"
    static let description = IntentDescription("Creates a new chat with an agent, optionally sends a first message, and opens it.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Message")
    var message: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a chat with \(\.$agent)") {
            \.$message
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ChatEntity> {
        let chat = try await PincerIntentService.make().startChat(
            agentId: self.agent.agentId, agentName: self.agent.name, gatewayId: self.agent.gatewayId,
            gatewayName: self.agent.gatewayName, message: self.message)
        AppModel.shared.open(chat.target)
        return .result(value: ChatEntity(chat))
    }
}

struct GetUnreadChatsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Unread Chats"
    static let description = IntentDescription("Lists chats with unread replies, like the app's unread badge.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Gateway", description: "Leave empty for every Gateway.")
    var gateway: GatewayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get unread chats on \(\.$gateway)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ChatEntity]> & ProvidesDialog {
        let chats = try await PincerIntentService.make().unreadChats(
            gatewayId: self.gateway?.gatewayId, gatewayName: self.gateway?.name)
        return .result(value: chats.map(ChatEntity.init), dialog: "\(IntentService.unreadSummary(chats))")
    }
}

/// Read-only: approving from Shortcuts is out of scope, use the app or its notifications.
struct PendingApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pending Approvals"
    static let description = IntentDescription("Counts exec approvals waiting for a decision.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Gateway", description: "Leave empty for every Gateway.")
    var gateway: GatewayEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get pending approvals on \(\.$gateway)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let approvals = try await PincerIntentService.make().pendingApprovals(
            gatewayId: self.gateway?.gatewayId, gatewayName: self.gateway?.name)
        return .result(value: approvals.count, dialog: "\(IntentService.approvalsSummary(approvals))")
    }
}

struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a chat in Pincer.")

    @Parameter(title: "Chat")
    var target: ChatEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.open(self.target.chat.target)
        return .result()
    }
}
