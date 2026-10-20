import PincerKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The "Thinking isn't being saved" hint. Its own view so its reads don't invalidate `ChatView`.
struct ReasoningHint: View {
    let chat: ChatStore
    let level: String?
    @Binding var dismissed: Bool
    @Environment(GatewayStore.self) private var gateway

    @ViewBuilder var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("ReasoningHint")
        #endif
        if !self.dismissed, self.chat.hasLoaded, !self.chat.sawThinking, self.level != "on", self.level != "stream",
           self.chat.items.contains { $0.role == .assistant }
        {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "brain").foregroundStyle(.purple)
                Text("Thinking isn’t being saved for this chat.", bundle: .module)
                    .font(.callout)
                Button(L("Turn On")) {
                    Task { await self.gateway.patch(self.chat.sessionKey, ["reasoningLevel": "on"]) }
                }
                .glassButton()
                .controlSize(.small)
                Text("or send `/reasoning on`", bundle: .module).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy) { self.dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Dismiss"))
            }
            .padding(.leading, Theme.Spacing.row)
            .padding(.trailing, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.sm)
            .glassSurface(in: Capsule(), tint: .purple)
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The transcript and its empty and loading states. The only view that observes `chat.entries`,
/// so a streamed token re-evaluates this and not `ChatView`.
struct TranscriptPane: View {
    let chat: ChatStore
    let find: TranscriptFind
    let jump: TranscriptJump?
    let navigator: TranscriptNavigator
    let disclosure: TranscriptDisclosure
    /// Not observed: only the list's bottom state and Find's toggle drive it.
    let findTrim: TranscriptFindTrim
    @Binding var previewing: ImageRef?
    @Binding var previewingHTML: HTMLPreviewItem?
    @Binding var quickLookURL: URL?
    @Binding var exporting: ExportedFile?
    let bottomState: TranscriptBottomState
    let bottomInset: CGFloat
    let topInset: CGFloat
    let reasoningOff: Bool
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.chatChromeActions) private var chromeActions

    private var agent: AgentSummary {
        self.gateway.agent(self.chat.sessionRow?.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "main")
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("TranscriptPane")
        #endif
        self.content
            .onAppear {
                self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff)
                self.followBottom()
            }
            .onChange(of: ObjectIdentifier(self.chat)) {
                // The pane outlives a chat switch (#571); the new chat's Find starts from its entries.
                self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff)
                self.followBottom()
            }
            .onChange(of: PerChat(chat: self.chat, value: self.find.isPresented)) { old, new in
                // On a switch the old chat's Find is retired by `ChatView`; the new one starts closed.
                guard old.chat == new.chat else { return }
                if new.value { Task { await self.chat.loadAllCached() } }
                self.findTrim.findChanged(isPresented: new.value, chat: self.chat)
            }
            .onChange(of: self.chat.entries) { self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff) }
            .onChange(of: self.reasoningOff) { self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff) }
    }

    @ViewBuilder private var content: some View {
        if self.chat.entries.isEmpty, self.chat.isLoading || !self.chat.hasLoaded {
            // Until history has loaded once (cache still reading, or the Gateway reconnecting after
            // the app was suspended), an empty chat isn't known to be empty.
            VStack(spacing: Theme.Spacing.md) {
                ChatLoadingSkeleton(label: self.gateway.state.isConnected ? "Loading messages" : "Connecting…",
                                    topInset: self.topInset)
                if !self.gateway.state.isConnected {
                    Text("Connecting…", bundle: .module).font(.callout).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, self.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { self.bottomState.reset() }
            #if os(macOS)
            // Like the transcript list: fill the pane, then add the insets once.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            #endif
        } else if self.chat.entries.isEmpty {
            ContentUnavailableView {
                Label(L("Say hello to \(self.agent.name)"), systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Messages you send here go straight to your Gateway as the owner.", bundle: .module)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { self.bottomState.reset() }
        } else {
            TranscriptList(
                rows: TranscriptRow.rows(for: self.chat),
                context: TranscriptContext(
                    gateway: self.gateway,
                    disclosure: self.disclosure,
                    agent: self.agent,
                    sessionKey: self.chat.sessionKey,
                    previewImage: { [$previewing] in $previewing.wrappedValue = $0 },
                    saveFile: { [$exporting] file, data in $exporting.wrappedValue = ExportedFile(name: file.name, data: data) },
                    chat: self.chat,
                    reply: { [chat = self.chat, agent = self.agent] in chat.beginReply(to: $0, agentName: agent.name) },
                    copyLink: { [app = self.app, gateway = self.gateway, key = self.chat.sessionKey] in
                        CopyChatLinkButton.copyLink(app: app, gateway: gateway, sessionKey: key, messageId: $0)
                    },
                    toggleBookmark: { [chat = self.chat, gateway = self.gateway] id in
                        let item = chat.items.first { $0.transcriptId == id || $0.id == id }
                        let store = BookmarkStore.shared(gatewayId: gateway.id)
                        let notice = ChatNoticeOperation(chat)
                        let added = store.toggle(item, sessionKey: chat.sessionKey, messageId: id) { dropped in
                            if dropped > 0 { notice.publishIfCurrent(L("To make room, Pincer removed an older bookmark.")) }
                        }
                        notice.publish(added && store.droppedCount > 0 ? L("To make room, Pincer removed an older bookmark.")
                            : added ? L("Bookmarked") : L("Bookmark removed"))
                    },
                    isBookmarked: { [key = self.chat.sessionKey, id = self.gateway.id] in
                        BookmarkStore.shared(gatewayId: id).isBookmarked(sessionKey: key, messageId: $0)
                    },
                    previewHTML: { [$previewingHTML] in $previewingHTML.wrappedValue = HTMLPreviewItem(html: $0) },
                    quickLook: { [$quickLookURL] in $quickLookURL.wrappedValue = $0 },
                    openMCPServer: { [opener = self.openGatewaySettings, gateway = self.gateway,
                                      sessionKey = self.chat.sessionKey] in
                        opener.mcpServer(gateway, name: $0, sessionKey: sessionKey)
                    },
                    openBrowserPage: { [chrome = self.chromeActions, gateway = self.gateway] page in
                        chrome?.openBrowserPage(page, in: gateway) ?? false
                    }),
                isConnected: self.gateway.state.isConnected,
                bottomInset: self.bottomInset,
                topInset: self.topInset,
                highlight: self.find.highlight,
                jump: self.jump,
                bottomState: self.bottomState,
                navigator: self.navigator)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
    }

    /// Find's trim waits for the list to follow the bottom again (#335).
    private func followBottom() {
        self.bottomState.onAnchorChange = { [findTrim = self.findTrim, chat = self.chat] in
            findTrim.bottomAnchorChanged($0, chat: chat)
        }
    }
}

/// Animates the bottom stack as pending questions come and go, without `ChatView` observing them.
struct QuestionsAnimation: ViewModifier {
    @Environment(GatewayStore.self) private var gateway

    func body(content: Content) -> some View {
        content.animation(.snappy, value: self.gateway.questions.map(\.id))
    }
}
