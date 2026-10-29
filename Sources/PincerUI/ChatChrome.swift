import PincerKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The selected chat's title and toolbar items. Applied outside `ChatView`'s per-chat `.id`:
/// when they come and go with it, macOS rebuilds the window toolbar on every chat switch and all
/// of its buttons flash, the sidebar's included.
///
/// While the main window shows its split view, each side's header has its chat's controls (#427):
/// the toolbar items stay but show nothing, and the title follows the focused side (#404).
struct ChatChrome: ViewModifier {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Whether the window is wide enough for both sides of the split view.
    @State private var fitsSplit = false
    /// Per window, and kept across chat switches.
    @State private var panel: ChatInspectorPanel?
    /// The "Tools & Policy…" sheet. Held here, not on the toolbar menu, so a menu re-render or the
    /// session row briefly going away (refresh, reconnect) doesn't dismiss it.
    @State private var toolsInspector: ChatToolsInspection?

    /// The selected chat's row as last seen, so a refresh or reconnect that briefly drops it doesn't
    /// empty the title and toolbar items. Only ever a row of the selected chat, never a previous one.
    @State private var lastRow: SessionRow?

    private var key: String? { self.windowKey ?? self.gateway.focusedKey }
    private var row: SessionRow? {
        if let key, let current = self.gateway.sessions[key] { return current }
        return self.lastRow.flatMap { $0.key == self.key ? $0 : nil }
    }

    private var usesDetachedWindowTitle: Bool {
        #if os(macOS)
        self.windowKey != nil
        #else
        false
        #endif
    }

    private var showsCompactIdentity: Bool {
        #if os(iOS)
        self.sizeClass == .compact && !self.showsSplit
        #else
        false
        #endif
    }

    private var showsSplit: Bool {
        guard self.windowKey == nil else { return false }
        #if os(iOS)
        let regular = self.sizeClass == .regular
        #else
        let regular = true
        #endif
        return regular && self.fitsSplit && self.gateway.visibleSplitKey != nil
    }

    func body(content: Content) -> some View {
        let split = self.showsSplit
        content
            .environment(\.showsChatSplit, split)
            .environment(\.chatChromeActions, ChatChromeActions(showRuns: self.$panel.isShowing(.runs), showWorkspace: self.$panel.isShowing(.workspace), showPortals: self.$panel.isShowing(.portals),
                                                                     toolsInspector: self.$toolsInspector))
            .environment(\.chatChromeSessionRow, self.row)
            .onGeometryChange(for: Bool.self) { $0.size.width >= ChatSplitHost.minWidth * 2 + 1 } action: { self.fitsSplit = $0 }
            .navigationTitle(self.showsCompactIdentity ? "" : ChatWindowTitle.title(
                self.key.map { chatTitle(self.gateway, key: $0, row: self.row) } ?? L("Chat"), isDetached: self.usesDetachedWindowTitle))
            #if os(macOS)
            .navigationSubtitle(split ? "" : self.subtitle)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Each side's header has its title instead (#427).
            .toolbar(removing: split ? .title : nil)
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .navigation) { if !split { ChatHeaderAvatar() } }
                #else
                // The inspector below hides the split view's own sidebar button (#564).
                ToolbarItem(placement: .topBarLeading) { ShowSidebarButton() }
                ToolbarItem(placement: .topBarLeading) { if !split && !self.showsCompactIdentity { ChatHeaderAvatar() } }
                #endif
                #if os(macOS)
                // A stable container, so a chat without branches doesn't remove the item (#262).
                ToolbarItem(placement: .primaryAction) {
                    ZStack {
                        if !split, let key { BranchHeaderChipView(chat: self.gateway.chat(for: key)) }
                    }
                }
                #else
                // Empty native toolbar items still reserve space in the iOS glass group.
                if !split && !self.showsCompactIdentity, let key, self.gateway.chat(for: key).hasBranchHeaderChip {
                    ToolbarItem(placement: .primaryAction) {
                        BranchHeaderChipView(chat: self.gateway.chat(for: key))
                    }
                }
                #endif
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) { ChatModelItem(row: split ? nil : self.row) }
                #else
                // Separate items (ChatToolbarLayout), so the glass group spaces them natively (#1088).
                // The plain style keeps SwiftUI drawing each picker's title: a bare Menu becomes an icon-only bar button.
                if !split && !self.showsCompactIdentity, let row = self.row {
                    ToolbarItem(placement: .primaryAction) { ModelPicker(row: row).menuStyle(.button).buttonStyle(.plain) }
                    ToolbarItem(placement: .primaryAction) { ThinkingLevelPicker(row: row).menuStyle(.button).buttonStyle(.plain) }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    ChatSessionMenu(showRuns: self.$panel.isShowing(.runs), showWorkspace: self.$panel.isShowing(.workspace), showPortals: self.$panel.isShowing(.portals), toolsInspector: self.$toolsInspector, row: split ? nil : self.row, compactActions: self.showsCompactIdentity)
                }
            }
            .sheet(item: self.$toolsInspector) { inspection in
                ChatToolsInspectorSheet(model: inspection.model, scopeTitle: inspection.scopeTitle, gateway: self.gateway)
            }
            #if os(iOS)
            .modifier(CompactChatIdentityChrome(active: self.showsCompactIdentity, gateway: self.gateway, key: self.key, row: self.row))
            #endif
            .modifier(ChatInspectorChrome(panel: self.$panel, showsToolbarButton: !split && !self.showsCompactIdentity, tracksPortals: !split))
            .onChange(of: self.key.flatMap { self.gateway.sessions[$0] }, initial: true) { _, row in
                if let row { self.lastRow = row }
            }
    }

    private var subtitle: String {
        let agentId = self.row?.agentId ?? self.key.flatMap(SessionKey.agentId(from:)) ?? "main"
        var parts = [self.gateway.agent(agentId).name]
        if let server = self.row?.server {
            parts.append(self.gateway.displayName(for: server))
        } else if let origin = self.row?.originLabel {
            parts.append(L("via \(origin)"))
        }
        if let model = self.row?.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

#if os(macOS)
private struct ChatModelItem: View {
    let row: SessionRow?

    var body: some View {
        if let row {
            HStack(spacing: Theme.Spacing.sm) {
                ModelPicker(row: row)
                ThinkingLevelPicker(row: row)
            }
        }
    }
}
#endif

/// The chat's options. In the window toolbar it acts on the focused chat; in a split view header,
/// on that side's chat, through its `handles`.
struct ChatSessionMenu: View {
    @Binding var showRuns: Bool
    @Binding var showWorkspace: Bool
    @Binding var showPortals: Bool
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @FocusedValue(\.transcriptFind) private var focusedFind
    @FocusedValue(\.chatExport) private var focusedExport
    @Binding var toolsInspector: ChatToolsInspection?
    let row: SessionRow?
    var compactActions = false
    var handles: ChatPaneHandles?
    /// Called before an item acts, so a split view side takes focus first.
    var willAct: () -> Void = {}

    private var find: TranscriptFind? { self.handles == nil ? self.focusedFind : self.handles?.find }
    private var chatExport: ChatExportState? { self.handles == nil ? self.focusedExport : self.handles?.export }

    var body: some View {
        if let row {
            // On compact iPhone the thinking picker lives in this menu, so a slow, costly level
            // shows on its button at a glance (#1086).
            let thinkingWarning = self.compactActions ? ThinkingLevel.expensiveWarning(for: row) : nil
            Menu {
                if self.compactActions {
                    ModelPicker(row: row, showsActionTitle: true)
                    ThinkingLevelPicker(row: row, showsActionTitle: true)
                    BranchHeaderChipView(chat: self.gateway.chat(for: row.key), showsTitle: true)
                    Divider()
                }
                Button(L("Find in Chat"), systemImage: "magnifyingglass") {
                    self.willAct()
                    self.find?.present()
                }
                Divider()
                Button(row.isPinned ? L("Unpin") : L("Pin"), systemImage: row.isPinned ? "pin.slash" : "pin") {
                    Task { await self.gateway.patch(row.key, ["pinned": .bool(!row.isPinned)]) }
                }
                ThinkingDisplayPicker()
                ReasoningMenu(row: row)
                ReactionLevelMenu(row: row)
                ShowRunsButton(isPresented: Binding(get: { self.showRuns }, set: {
                    self.willAct()
                    self.showRuns = $0
                }), sessionKey: row.key)
                ShowBrowserButton(isPresented: Binding(get: { self.showWorkspace }, set: {
                    self.willAct()
                    self.showWorkspace = $0
                }))
                ShowPortalsButton(isPresented: Binding(get: { self.showPortals }, set: {
                    self.willAct()
                    self.showPortals = $0
                }), sessionKey: row.key)
                Divider()
                Button(L("Reload"), systemImage: "arrow.clockwise") {
                    Task { await self.gateway.chat(for: row.key).load(force: true) }
                }
                Button(L("Copy Session Key"), systemImage: "key") { Clipboard.copy(row.key) }
                CopyChatLinkButton(sessionKey: row.key)
                Button(L("Export Chat…"), systemImage: "square.and.arrow.up") {
                    self.willAct()
                    self.chatExport?.showExport = true
                }
                Button(L("Bookmarks…"), systemImage: "star") {
                    self.willAct()
                    self.chatExport?.showBookmarks = true
                }
                Button(L("Session Usage…"), systemImage: "chart.bar") {
                    self.openGatewaySettings.sessionUsage(self.gateway, key: row.key, agentId: row.agentId)
                }
                if self.gateway.supportsSessionManager {
                    Button(L("Manage Session…"), systemImage: "rectangle.stack") {
                        self.openGatewaySettings(self.gateway, at: .sessions, routes: [.sessionDetail(row.key)])
                    }
                }
                if self.gateway.supportsToolsEffective {
                    Button(L("Tools & Policy…"), systemImage: "wrench.and.screwdriver") {
                        self.toolsInspector = ChatToolsInspection(model: self.gateway.toolsInspector(sessionKey: row.key),
                                                                  scopeTitle: L("Chat: \(row.title)"))
                    }
                }
            } label: {
                if thinkingWarning != nil {
                    Label(L("Chat Options"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label(L("Chat Options"), systemImage: Theme.moreSymbol)
                }
            }
            .tint(thinkingWarning != nil ? .orange : nil)
            .accessibilityValue(thinkingWarning ?? "")
        }
    }
}

/// A presented "Tools & Policy…" sheet: its inspector (made in the menu action) and scope title.
struct ChatToolsInspection: Identifiable {
    let model: ToolsInspectorModel
    let scopeTitle: String

    var id: ObjectIdentifier { ObjectIdentifier(self.model) }
}

/// What the Gateway saves and streams of the agent's reasoning for this session. How much of it
/// the transcript shows is `ThinkingDisplay`; "Off" hides reasoning text there too.
struct ReasoningMenu: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Menu(L("Gateway Reasoning"), systemImage: "brain") {
            ForEach([("on", L("Save & Stream")), ("stream", L("Stream Only")), ("off", L("Off"))], id: \.0) { value, label in
                Button {
                    Task { await self.gateway.patch(self.row.key, ["reasoningLevel": .string(value)]) }
                } label: {
                    if self.row.reasoningLevel == value {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        }
    }
}
