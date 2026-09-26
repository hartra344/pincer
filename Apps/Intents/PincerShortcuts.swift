import AppIntents
import PincerKit

/// Siri phrases and Spotlight / Action Button shortcuts that work without any setup.
struct PincerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(\.$agent) in \(.applicationName)"],
            shortTitle: "Ask Agent",
            systemImageName: "bubble.left")
        AppShortcut(
            intent: SendToChatIntent(),
            phrases: ["Send a message with \(.applicationName)", "Send a message to \(\.$chat) in \(.applicationName)"],
            shortTitle: "Send to Chat",
            systemImageName: "paperplane")
        AppShortcut(
            intent: GetUnreadChatsIntent(),
            phrases: ["What's unread in \(.applicationName)", "Unread chats in \(.applicationName)"],
            shortTitle: "Unread Chats",
            systemImageName: "tray")
        AppShortcut(
            intent: PendingApprovalsIntent(),
            phrases: ["Pending approvals in \(.applicationName)", "What needs approval in \(.applicationName)"],
            shortTitle: "Pending Approvals",
            systemImageName: "checkmark.shield")
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)", "Open a chat in \(.applicationName)"],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: StartChatIntent(),
            phrases: ["Start a chat with \(\.$agent) in \(.applicationName)", "Start a chat in \(.applicationName)"],
            shortTitle: "Start Chat",
            systemImageName: "square.and.pencil")
    }
}

enum PincerIntentsSetup {
    /// Refreshes the agent and chat names Siri recognises in phrases whenever an agent list loads.
    @MainActor
    static func install() {
        GatewayStore.agentsDidLoad = { PincerShortcuts.updateAppShortcutParameters() }
    }
}
