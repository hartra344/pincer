import PincerKit
import SwiftUI

extension GatewayStore {
    /// The portals this chat's agent opened (or owns): a filter over the handful of portals, nothing per token.
    func portalScope(for key: String) -> PortalScope {
        let chat = self.chat(for: key)
        return PortalScope(sessionKey: key, agentId: chat.agentId, opened: chat.openedPortals)
    }

    /// The chat the Portals panel and its buttons act on: the window's, else the focused one.
    func portalChatKey(window: String?) -> String? { window ?? self.focusedKey ?? self.selectedKey }

    func chatPortals(for key: String?) -> [PortalSummary] {
        guard let key, !self.portals.unavailable else { return [] }
        return self.portals.portals(for: self.portalScope(for: key))
    }
}

/// The chat's portals: a tab strip, then the selected portal. Portals never open by themselves.
struct PortalsPanel: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey
    @Environment(\.scenePhase) private var scenePhase
    /// Owned by the window's inspector chrome, so loaded portals survive reopening the panel.
    let cache: PortalWebCache
    @State private var picked: String?
    @State private var closing: PortalSummary?
    @State private var lastClosingTitle = ""
    /// The panel has finished sliding in; the first web view is created only after.
    @State private var settled = false
    @State private var dismissedCloseError: String?

    private var key: String? { self.gateway.portalChatKey(window: self.windowKey) }

    var body: some View {
        let store = self.gateway.portals
        let portals = self.gateway.chatPortals(for: self.key)
        let selected = portals.first { $0.id == self.picked } ?? portals.first
        VStack(spacing: 0) {
            if !portals.isEmpty {
                PortalsTabStrip(portals: portals, selected: selected?.id, pick: { self.picked = $0 }, close: { self.closing = $0 })
                Divider()
            }
            if let error = store.closeError, error != self.dismissedCloseError {
                PortalBanner(symbol: "exclamationmark.triangle", dismiss: { self.dismissedCloseError = error }) { Text(error) }
                Divider()
            }
            if let selected {
                PortalView(portal: selected, cache: self.cache, canLoad: self.settled) { self.closing = selected }
                    .id(selected.id)
            } else {
                ContentUnavailableView {
                    Label(L("No portals"), systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("Portals this agent opens show here.", bundle: .module)
                }
            }
        }
        .task {
            try? await Task.sleep(for: WorkspacePanel.slideSettleDelay)
            self.settled = true
        }
        .onChange(of: self.key) { self.picked = nil }
        .onChange(of: self.closing) { _, new in if let new { self.lastClosingTitle = new.title } }
        .onChange(of: self.gateway.portals.portals.map(\.id)) { _, ids in self.cache.prune(keeping: Set(ids)) }
        .onChange(of: self.scenePhase) { _, phase in if phase != .active { self.cache.pauseAllMedia() } }
        .portalCloseConfirmation(title: self.closing?.title ?? self.lastClosingTitle, isPresented: Binding(get: { self.closing != nil }, set: { if !$0 { self.closing = nil } })) {
            guard let portal = self.closing, let key = self.key else { return }
            self.closing = nil
            let scope = self.gateway.portalScope(for: key)
            Task { await store.close(portal.id, scope: scope) }
        }
    }
}

private struct PortalsTabStrip: View {
    let portals: [PortalSummary]
    let selected: String?
    let pick: (String) -> Void
    let close: (PortalSummary) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(self.portals) { portal in
                    PortalTab(portal: portal, isSelected: self.selected == portal.id,
                              select: { self.pick(portal.id) }, close: { self.close(portal) })
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }
}

private struct PortalTab: View {
    let portal: PortalSummary
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button(action: self.select) {
                Label(Self.shortened(self.portal.title), systemImage: "globe")
                    .font(.callout.weight(self.isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(self.portal.title)
            .accessibilityLabel(L("Portal: \(self.portal.title)"))
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
            if !self.portal.isRedacted {
                Button(action: self.close) {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        .frame(minWidth: Self.closeTarget, minHeight: Self.closeTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("Close Portal"))
                .accessibilityLabel(L("Close portal \(self.portal.title)"))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(self.isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear), in: Capsule())
        .contextMenu {
            if !self.portal.isRedacted {
                Button(L("Close Portal"), systemImage: "xmark.circle", role: .destructive, action: self.close)
            }
        }
    }

    #if os(iOS)
    static let closeTarget: CGFloat = 44
    #else
    static let closeTarget: CGFloat = 24
    #endif

    /// One line, about 24 characters; the full title is in the help.
    static func shortened(_ title: String) -> String {
        title.count > 24 ? title.prefix(23) + "…" : title
    }
}


/// The Portals toolbar button (⌥⌘P): shown when this chat has a portal or the panel is open (on compact
/// iPhone only while open; "Show Portals" in the chat's ⋯ menu covers the rest). The badge counts this chat's portals.
struct PortalsToolbarButton: View {
    @Binding var isPresented: Bool
    let isCompact: Bool
    var sessionKey: String?
    var isFocused = true
    var focus: () -> Void = {}
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey

    var body: some View {
        let key = self.sessionKey ?? self.gateway.portalChatKey(window: self.windowKey)
        let count = self.gateway.chatPortals(for: key).count
        let open = self.isPresented && self.isFocused
        Group {
            if open || (!self.isCompact && count > 0) {
                let title = self.isPresented ? L("Hide Portals") : L("Show Portals")
                self.focusedPaneShortcut(Button {
                    if self.isFocused {
                        self.isPresented.toggle()
                    } else {
                        self.focus()
                        self.isPresented = true
                    }
                } label: {
                    Label {
                        Text(L("Portals"))
                    } icon: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "rectangle.on.rectangle")
                            if count > 0 {
                                Text(count > 99 ? "99+" : "\(count)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, count > 9 ? 3 : 0)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Color.accentColor, in: Capsule())
                                    .offset(x: 8, y: -6)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .foregroundStyle(self.isPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                })
                #if os(iOS)
                .buttonStyle(.plain)
                #endif
                .help(self.isPresented ? L("Hide Portals (⌥⌘P)") : L("Show Portals (⌥⌘P)"))
                .accessibilityLabel(count > 0 ? "\(title) — \(Self.portalCount(count))" : title)
            }
        }
    }

    static func portalCount(_ count: Int) -> String {
        count == 1 ? L("1 portal") : L("\(count) portals")
    }

    @ViewBuilder private func focusedPaneShortcut(_ button: some View) -> some View {
        if self.isFocused {
            button.shortcut(.showPortals)
        } else {
            button
        }
    }
}

/// Follows the chat's owned portals on the Gateway while it is shown. Attached to a view that is always
/// present (not to a button that only appears once portals exist), so owned-only chats get their button.
struct PortalsTracking: ViewModifier {
    let key: String?
    @Environment(GatewayStore.self) private var gateway

    func body(content: Content) -> some View {
        content.task(id: self.key) {
            guard let key = self.key else { return }
            let store = self.gateway.portals
            store.trackOwned(sessionKey: key, agentId: self.gateway.chat(for: key).agentId)
            // Parked until the chat changes or the view goes away.
            try? await Task.sleep(for: .seconds(1_000_000_000))
            store.untrackOwned(sessionKey: key)
        }
    }
}

/// "Show Portals" for the chat's session menu, only when the chat has portals (or the panel is open).
struct ShowPortalsButton: View {
    @Binding var isPresented: Bool
    var sessionKey: String?
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey

    var body: some View {
        if self.isPresented || !self.gateway.chatPortals(for: self.sessionKey ?? self.gateway.portalChatKey(window: self.windowKey)).isEmpty {
            Button(self.isPresented ? L("Hide Portals") : L("Show Portals"), systemImage: "rectangle.on.rectangle") {
                self.isPresented.toggle()
            }
        }
    }
}
