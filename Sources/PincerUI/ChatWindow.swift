import PincerKit
import SwiftUI

/// Opens a chat in a window of its own (#48). Does nothing where there are no chat windows (iOS).
struct ChatWindowOpener {
    var open: (@MainActor (ChatWindowRef) -> Void)?

    var isAvailable: Bool { self.open != nil }

    @MainActor
    func callAsFunction(_ gateway: GatewayStore, key: String) {
        self.open?(ChatWindowRef(gatewayId: gateway.id, sessionKey: key))
    }
}

extension EnvironmentValues {
    @Entry var openChatWindow = ChatWindowOpener()
    /// The chat a chat window shows. Chat chrome reads it instead of the gateway's selection, which
    /// belongs to the main window.
    @Entry var chatWindowKey: String?
}

extension ChatWindowOpener {
    #if os(macOS)
    static func window(_ openWindow: OpenWindowAction) -> ChatWindowOpener {
        ChatWindowOpener { openWindow(id: ChatWindow.sceneId, value: $0) }
    }
    #endif
}

/// One chat, its title, toolbar and composer, sharing the app's gateway connection. While it's on
/// screen the chat stays loaded and live, and isn't notified (see `AppModel.chatWindowOpened`).
struct ChatWindow: View {
    static let sceneId = "chat"

    let ref: ChatWindowRef?
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let ref, let gateway = self.app.gateways.first(where: { $0.id == ref.gatewayId }) {
                ChatWindowContent(ref: ref, gateway: gateway)
            } else {
                ContentUnavailableView(L("Chat unavailable"), systemImage: "bubble.left.and.bubble.right",
                                       description: Text("This chat's Gateway was removed.", bundle: .module))
            }
        }
        .task { self.app.start() }
    }
}

private struct ChatWindowContent: View {
    let ref: ChatWindowRef
    let gateway: GatewayStore
    @Environment(AppModel.self) private var app
    @Environment(\.appTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            ZStack {
                ChatView(chat: self.gateway.chat(for: self.ref.sessionKey))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { self.theme.background(.chatBackground)?.ignoresSafeArea() }
            .modifier(ChatChrome())
        }
        .environment(self.gateway)
        .environment(\.chatWindowKey, self.ref.sessionKey)
        .environment(\.openGatewaySettings, GatewaySettingsOpener { gateway, destination, routes in
            gateway.settings.requestedRoutes = routes
            gateway.settings.requestedDestination = destination
            self.openWindow(id: "gateway-settings", value: gateway.id)
        })
        .environment(\.openAutomations, AutomationsOpener { gateway in
            self.openWindow(id: "automations", value: gateway.id)
        })
        .onAppear { self.app.chatWindowOpened(self.ref) }
        .onDisappear { self.app.chatWindowClosed(self.ref) }
    }
}

#if os(macOS)
/// File ▸ Open Chat in New Window (⌥⌘N) for the main window's chat.
struct ChatWindowCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("Open Chat in New Window")) {
                guard let gateway = self.app.selectedGateway, let key = gateway.selectedKey else { return }
                ChatWindowOpener.window(self.openWindow)(gateway, key: key)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(self.app.selectedGateway?.selectedKey == nil)
        }
    }
}
#endif
