import PincerKit
import SwiftUI

/// The main window's split view (#48): the selected chat on the left with the window's title and
/// toolbar, and a second chat on the right with a small header of its own. The left chat keeps its
/// place in the view tree whether or not the split shows, so opening or closing it doesn't reload it.
struct ChatSplitHost: ViewModifier {
    let gateway: GatewayStore
    @AppStorage("pincer.splitFraction") private var fraction = 0.5
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let key = self.splitKey, proxy.size.width >= Self.minWidth * 2 + 1 {
                    SplitDivider(fraction: self.$fraction, totalWidth: proxy.size.width)
                    SplitChatPane(gateway: self.gateway, key: key)
                        .id("\(self.gateway.id)|split|\(key)")
                        .frame(width: max(Self.minWidth, proxy.size.width * self.clampedFraction(proxy.size.width)))
                }
            }
        }
        // Picking the right-hand chat in the sidebar moves it left, and the chat it replaces right.
        .onChange(of: self.gateway.selectedKey) { old, new in
            if let new, new == self.gateway.splitKey { self.gateway.splitKey = old }
        }
    }

    private var splitKey: String? {
        #if os(iOS)
        guard self.sizeClass == .regular else { return nil }
        #endif
        return self.gateway.visibleSplitKey
    }

    static let minWidth: CGFloat = 320

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
    @Environment(AppModel.self) private var app
    @Environment(\.appTheme) private var theme

    private var ref: ChatWindowRef { ChatWindowRef(gatewayId: self.gateway.id, sessionKey: self.key) }

    var body: some View {
        VStack(spacing: 0) {
            SplitPaneHeader(gateway: self.gateway, key: self.key)
            Divider()
            ZStack {
                ChatView(chat: self.gateway.chat(for: self.key))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { self.theme.background(.chatBackground)?.ignoresSafeArea() }
        .environment(\.chatWindowKey, self.key)
        .onAppear { self.app.chatWindowOpened(self.ref) }
        .onDisappear { self.app.chatWindowClosed(self.ref) }
        .modifier(ChatWindowVisibility(gateway: self.gateway, key: self.key))
    }
}

private struct SplitPaneHeader: View {
    let gateway: GatewayStore
    let key: String
    @Environment(\.openChatWindow) private var openChatWindow

    var body: some View {
        let row = self.gateway.sessions[self.key]
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row?.title ?? SessionKey.agentId(from: self.key) ?? L("Chat"))
                    .font(.headline)
                    .lineLimit(1)
                Text(self.gateway.agent(row?.agentId ?? SessionKey.agentId(from: self.key) ?? "main").name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.md)
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
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Split view chat"))
    }
}
