import PincerKit
import SwiftUI

struct SidebarSplitPaneObservation: Equatable {
    let gatewayID: UUID
    let sessionKey: String?
}

/// The main window's split view (#48): the selected chat on the left and a second chat on the right.
/// While the split shows, each side has a header of its own with the chat's controls (#427), and the
/// side that last had focus is the one menu commands act on (#404). The left chat keeps its place in
/// the view tree whether or not the split shows, so opening or closing it doesn't reload it.
struct ChatSplitHost: ViewModifier {
    let gateway: GatewayStore
    @Binding var sidebarSplitKey: String?
    @AppStorage("pincer.splitFraction") private var fraction = 0.5
    @Environment(\.showsChatSplit) private var showsSplit
    @FocusedValue(\.chatPane) private var focusedPane
    @State private var mainHandles = ChatPaneHandles()

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let visibleKey = proxy.size.width >= Self.minWidth * 2 + 1 ? self.splitKey : nil
            let observation = SidebarSplitPaneObservation(gatewayID: self.gateway.id, sessionKey: visibleKey)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if self.splitKey != nil, let key = self.gateway.selectedKey {
                        ChatPaneHeader(gateway: self.gateway, key: key, side: .main,
                                       isFocused: !self.gateway.splitPaneFocused, handles: self.mainHandles)
                        Divider()
                    }
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .environment(\.chatPaneHandles, self.mainHandles)
                .environment(\.chatPaneIsActive, self.splitKey == nil || !self.gateway.splitPaneFocused)
                .focusedValue(\.chatPane, .main)
                if let key = self.splitKey {
                    SplitDivider(fraction: self.$fraction, totalWidth: proxy.size.width)
                    SplitChatPane(gateway: self.gateway, key: key, isFocused: self.gateway.splitPaneFocused)
                        .id("\(self.gateway.id)|split|\(key)")
                        .frame(width: max(Self.minWidth, proxy.size.width * self.clampedFraction(proxy.size.width)))
                }
            }
            .onChange(of: observation, initial: true) { _, value in self.sidebarSplitKey = value.sessionKey }
            .onDisappear { self.sidebarSplitKey = nil }
        }
        // Picking the right-hand chat in the sidebar moves it left, and the chat it replaces right.
        .onChange(of: self.gateway.selectedKey) { old, new in
            if let new, new == self.gateway.splitKey { self.gateway.splitKey = old }
        }
        // Focus elsewhere (the sidebar, a sheet) leaves the last focused side in charge.
        .onChange(of: self.focusedPane) { _, pane in
            guard let pane, self.splitKey != nil else { return }
            self.gateway.splitPaneFocused = pane == .split
        }
        .onChange(of: self.splitKey == nil) { _, hidden in
            if hidden { self.gateway.splitPaneFocused = false }
        }
    }

    private var splitKey: String? { self.showsSplit ? self.gateway.visibleSplitKey : nil }

    nonisolated static let minWidth: CGFloat = 320

    private func clampedFraction(_ width: CGFloat) -> CGFloat {
        guard width > Self.minWidth * 2 else { return 0.5 }
        let bound = Self.minWidth / width
        return min(max(self.fraction, bound), 1 - bound)
    }
}

/// Drag to resize the split; the fraction is the right pane's share of the width.
private struct SplitDivider: View {
    @Binding var fraction: Double
    let totalWidth: CGFloat
    @State private var start: Double?
    #if os(macOS)
    @State private var cursorPushed = false
    #endif

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { self.setCursor($0) }
                    .onDisappear { self.setCursor(false) }
                    #endif
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = self.start ?? self.fraction
                                self.start = start
                                guard self.totalWidth > 0 else { return }
                                self.fraction = min(max(start - value.translation.width / self.totalWidth, 0.2), 0.8)
                            }
                            .onEnded { _ in self.start = nil })
                    .accessibilityHidden(true)
            }
    }

    #if os(macOS)
    /// Balanced, so closing the split under the pointer doesn't leave the resize cursor behind.
    private func setCursor(_ resize: Bool) {
        guard resize != self.cursorPushed else { return }
        self.cursorPushed = resize
        if resize { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
    #endif
}

/// The split view's right-hand chat. Registered like a chat window, so it stays loaded and live and
/// isn't notified while on screen.
private struct SplitChatPane: View {
    let gateway: GatewayStore
    let key: String
    let isFocused: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.appTheme) private var theme
    @State private var handles = ChatPaneHandles()

    private var ref: ChatWindowRef { ChatWindowRef(gatewayId: self.gateway.id, sessionKey: self.key) }

    var body: some View {
        VStack(spacing: 0) {
            ChatPaneHeader(gateway: self.gateway, key: self.key, side: .split, isFocused: self.isFocused, handles: self.handles)
            Divider()
            ZStack {
                ChatView(chat: self.gateway.chat(for: self.key))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { self.theme.background(.chatBackground)?.ignoresSafeArea() }
        .environment(\.chatWindowKey, self.key)
        .environment(\.chatPaneHandles, self.handles)
        .environment(\.chatPaneIsActive, self.isFocused)
        .focusedValue(\.chatPane, .split)
        .onAppear { self.app.chatWindowOpened(self.ref) }
        .onDisappear { self.app.chatWindowClosed(self.ref) }
        .modifier(ChatWindowVisibility(gateway: self.gateway, key: self.key))
    }
}
