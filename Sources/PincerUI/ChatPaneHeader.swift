import PincerKit
import SwiftUI

/// A side of the main window's split view (#48).
enum ChatPane: Hashable {
    case main, split
}

extension FocusedValues {
    /// The split view side that has focus, so the split view can follow it (#404).
    @Entry var chatPane: ChatPane?
}

extension EnvironmentValues {
    /// Whether the main window shows its split view. Set by `ChatChrome`, which hands the window's
    /// chat controls to the split view's headers while it shows (#427).
    @Entry var showsChatSplit = false
    /// False for the split view side without focus, whose chat doesn't answer menu commands (#404).
    @Entry var chatPaneIsActive = true
    /// Where a chat in a split view side leaves its Find and export state for that side's header.
    @Entry var chatPaneHandles: ChatPaneHandles?
    /// The window's Runs panel and Tools & Policy sheet, for the split view headers.
    @Entry var chatChromeActions: ChatChromeActions?
    /// The selected chat row cached by its window's chrome while a session refresh is in flight.
    @Entry var chatChromeSessionRow: SessionRow?
}

/// A split view side's Find and export state, filled in by its `ChatView`, so the side's own menu
/// acts on its chat rather than the focused one.
@MainActor
final class ChatPaneHandles {
    weak var find: TranscriptFind?
    weak var export: ChatExportState?
}

/// The window-level presentations `ChatChrome` owns.
struct ChatChromeActions {
    var showRuns: Binding<Bool>
    var toolsInspector: Binding<ChatToolsInspection?>
}

/// A chat's title for headers, before the sessions list arrives too (#407): the row's title, else
/// the title last seen for it, else the agent's name once agents have loaded, else "Chat".
@MainActor
func chatTitle(_ gateway: GatewayStore, key: String, row: SessionRow?) -> String {
    if let title = row?.title { return title }
    if let cached = gateway.cachedTitle(for: key) { return cached }
    if let agentId = SessionKey.agentId(from: key), let agent = gateway.agents.first(where: { $0.id == agentId }) {
        return agent.name
    }
    return L("Chat")
}

/// A split view side's header (#427): its chat's title and details, model, Runs and options, plus
/// swap, open in a window and close on the right-hand side.
struct ChatPaneHeader: View {
    let gateway: GatewayStore
    let key: String
    let side: ChatPane
    let isFocused: Bool
    let handles: ChatPaneHandles
    @Environment(\.chatChromeActions) private var actions
    @Environment(\.openChatWindow) private var openChatWindow
    @AppStorage(AvatarSettings.animatedKey) private var avatarsEnabled = true

    var body: some View {
        let row = self.gateway.sessions[self.key]
        let agent = self.gateway.agent(row?.agentId ?? SessionKey.agentId(from: self.key) ?? "main")
        HStack(spacing: Theme.Spacing.md) {
            if self.avatarsEnabled {
                ZStack {
                    ChatAgentAvatar(chat: self.gateway.chat(for: self.key), agent: agent, size: 22, announces: self.side == .main)
                        .id(self.key)
                }
                .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(chatTitle(self.gateway, key: self.key, row: row))
                    .font(.headline)
                    .foregroundStyle(self.isFocused ? .primary : .secondary)
                    .lineLimit(1)
                Text(self.subtitle(row: row, agent: agent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: Theme.Spacing.md)
            BranchHeaderChipView(chat: self.gateway.chat(for: self.key))
                .controlSize(.small)
            if let row {
                ModelPicker(row: row)
                    .controlSize(.small)
            }
            if let actions {
                RunsToolbarButton(isPresented: actions.showRuns, isCompact: false, sessionKey: self.key, isFocused: self.isFocused) { self.focus() }
                    .labelStyle(.iconOnly)
                ChatSessionMenu(showRuns: actions.showRuns, toolsInspector: actions.toolsInspector, row: row, handles: self.handles) {
                    self.focus()
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if self.side == .split {
                Group {
                    Button(L("Swap Chats"), systemImage: "arrow.left.arrow.right") { self.gateway.swapSplit() }
                        .help(L("Swap Chats"))
                    if self.openChatWindow.isAvailable {
                        Button(L("Open in New Window"), systemImage: "macwindow.badge.plus") {
                            self.openChatWindow(self.gateway, key: self.key)
                            self.gateway.closeSplit()
                        }
                        .help(L("Open in New Window"))
                    }
                    Button(L("Close Split View"), systemImage: "xmark") { self.gateway.closeSplit() }
                        .help(L("Close Split View"))
                }
                .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: 44)
        // Marks the side menu commands act on (#404).
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.tint)
                .frame(height: 2)
                .opacity(self.isFocused ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { self.focus() })
        .onChange(of: row?.title, initial: true) { _, title in
            if let title { self.gateway.rememberTitle(title, for: self.key) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.side == .split ? L("Split view chat") : L("Main chat"))
        .accessibilityAddTraits(self.isFocused ? .isSelected : [])
    }

    private func focus() {
        self.gateway.splitPaneFocused = self.side == .split
    }

    private func subtitle(row: SessionRow?, agent: AgentSummary) -> String {
        var parts = [agent.name]
        if let server = row?.server {
            parts.append(self.gateway.displayName(for: server))
        } else if let origin = row?.originLabel {
            parts.append(L("via \(origin)"))
        }
        return parts.joined(separator: " · ")
    }
}
