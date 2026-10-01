import PincerKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
/// Body-evaluation counts by view name, for measuring invalidation per streamed token.
enum BodyCounter {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func hit(_ name: String) { self.counts[name, default: 0] += 1 }

    /// Prints and resets the counts when PINCER_BODY_COUNTS=1; called as a run ends.
    static func report() {
        defer { self.counts = [:] }
        guard ProcessInfo.processInfo.environment["PINCER_BODY_COUNTS"] == "1" else { return }
        let line = ["ChatView", "TranscriptPane", "Composer", "ReasoningHint"]
            .map { "\($0)=\(self.counts[$0, default: 0])" }.joined(separator: " ")
        FileHandle.standardError.write(Data("BODY_COUNTS \(line)\n".utf8))
    }
}
#endif

struct ChatView: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @AppStorage("pincer.reasoningHintDismissed") private var hintDismissed = false
    @AppStorage(AvatarSettings.animatedKey) private var avatarAnnouncesErrors = true
    @State private var disclosure = TranscriptDisclosure()
    @State private var previewing: ImageRef?
    @State private var previewingHTML: HTMLPreviewItem?
    @State private var quickLookURL: URL?
    @State private var exporting: ExportedFile?
    @State private var find = TranscriptFind()
    @State private var jump: TranscriptJump?
    @State private var navigator = TranscriptNavigator()
    @State private var exportState = ChatExportState()
    /// A built export waiting for its sheet to close: the save panel or share sheet can't open over it (#430).
    @State private var pendingExport: ExportedFile?
    @State private var exportError: String?
    @State private var bottomState = TranscriptBottomState()
    @State private var readAloudPillInset: CGFloat = 0
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @Environment(\.chatPaneHandles) private var paneHandles
    #if os(iOS)
    @State private var sharedFile: SharedFile?
    #endif

    private var row: SessionRow? { self.chat.sessionRow }
    private var composerPlaceholder: String {
        Self.composerPlaceholder(
            sessionKey: self.chat.sessionKey,
            current: self.row,
            lastKnown: self.chatChromeSessionRow
        )
    }

    static func composerPlaceholder(sessionKey: String, current: SessionRow?, lastKnown: SessionRow?) -> String {
        let title = ComposerSessionTitle.title(sessionKey: sessionKey, current: current, lastKnown: lastKnown) ?? L("chat")
        return L("Message #\(title)")
    }

    /// The chat ⋯ menu's Reactions submenu reads the config, so load it for a chat on a supported channel.
    private func loadReactionLevels() async {
        guard self.gateway.state.isConnected, let row = self.row, ReactionLevels.target(of: row) != nil,
              self.gateway.canEditReactionLevels, !self.gateway.settings.hasLoaded else { return }
        await self.gateway.settings.load()
    }
    private var agent: AgentSummary { self.gateway.agent(self.row?.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "main") }

    /// Heights of the floating chrome, so the transcript can scroll underneath it.
    @State private var topChrome: CGFloat = 0
    @State private var bottomChrome: CGFloat = 0
    @State private var safeArea = EdgeInsets()
    @Environment(\.chatChromeSessionRow) private var chatChromeSessionRow

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("ChatView")
        #endif
        self.presentedContent
        .focusedSceneValue(\.replyToLast, self.paneIsActive ? ReplyToLast(chat: self.chat, agentName: self.agent.name) : nil)
        .task(id: self.chat.notice) {
            guard self.chat.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            self.chat.notice = nil
        }
        .onChange(of: self.app.findRequest, initial: true) { self.takeFindRequest() }
        .onChange(of: self.app.messageJump, initial: true) { self.takeMessageJump() }
        .onChange(of: self.chat.hasLoaded) { self.takeMessageJump() }
        .onChange(of: self.chat.lastOutcomeAt) { _, finished in
            if finished != nil { self.announceOutcome() }
            #if DEBUG
            if finished != nil { BodyCounter.report() }
            #endif
        }
        .modifier(ChatHandoff(sessionKey: self.chat.sessionKey))
        #if os(iOS)
        // Menu commands are macOS-only; on iOS a hardware keyboard reaches these instead.
        .background {
            Group {
                Button(L("Find in Chat")) { self.find.present() }.shortcut(.findInChat)
                if !self.find.isPresented {
                    Button(L("Find Next")) { self.find.next() }.shortcut(.findNext)
                    Button(L("Find Previous")) { self.find.previous() }.shortcut(.findPrevious)
                }
                Button(L("Reply to Last Message")) { ReplyToLast(chat: self.chat, agentName: self.agent.name).perform() }
                    .shortcut(.replyToLastMessage)
                    .disabled(self.chat.latestReplyableId == nil)
                Button(L("Previous Message")) { self.navigator.move?(false) }
                    .shortcut(.previousMessage)
                    .disabled(!self.paneIsActive)
                Button(L("Next Message")) { self.navigator.move?(true) }
                    .shortcut(.nextMessage)
                    .disabled(!self.paneIsActive)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    // Split out of `body` so the iOS compiler can type-check the modifier chain in time.
    private var transcript: some View {
        TranscriptPane(
            chat: self.chat, find: self.find, jump: self.jump, navigator: self.navigator, disclosure: self.disclosure,
            previewing: self.$previewing, previewingHTML: self.$previewingHTML, quickLookURL: self.$quickLookURL,
            exporting: self.$exporting, bottomState: self.bottomState,
            bottomInset: self.bottomChrome + self.transcriptSafeArea.bottom
                + (self.paneIsActive ? self.readAloudPillInset : 0),
            topInset: self.topChrome + self.transcriptSafeArea.top,
            reasoningOff: self.reasoningOff)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Measured outside the transcript's ignored region, so these are the toolbar and
            // home-indicator heights the transcript runs under. (Inside it, macOS reports zero.)
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { self.safeArea = $0 }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ApprovalsBanner(sessionKey: self.chat.sessionKey)
                    if self.find.isPresented {
                        TranscriptFindBar(find: self.find, reasoningOff: self.reasoningOff)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.topChrome = $0 }
            }
            .animation(.snappy, value: self.find.isPresented)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    self.errorBar
                    self.noticeBar
                    ReasoningHint(chat: self.chat, level: self.row?.reasoningLevel, dismissed: self.$hintDismissed)
                    if let card = self.chat.progressCard {
                        ProgressCardView(chat: self.chat, card: card)
                    }
                    PendingQuestionCard(chat: self.chat)
                    Composer(chat: self.chat, placeholder: self.composerPlaceholder, find: self.find)
                }
                .modifier(QuestionsAnimation())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.bottomChrome = $0 }
                // An overlay, so it doesn't change the measured height: its bottom sits just above
                // the stack's top, centred over the Send button, and rides up with the keyboard.
                .overlay(alignment: .topTrailing) {
                    ScrollToBottomButton(model: self.bottomState, chat: self.chat)
                        .alignmentGuide(.top) { $0[.bottom] + Theme.Spacing.md }
                        .padding(.trailing, ScrollToBottomButton.trailingPadding)
                }
            }
            .animation(.snappy, value: self.chat.errorMessage)
            .animation(.snappy, value: self.chat.notice)
            .animation(.snappy, value: self.chat.replyTarget)
            .animation(.snappy, value: self.chat.progressCard)
    }

    private var presentedContent: some View {
        self.transcript
        .sheet(item: self.$previewing) { ref in
            ImagePreview(ref: ref, sessionKey: self.chat.sessionKey)
        }
        .sheet(item: self.$previewingHTML) { item in
            HTMLPreviewSheet(item: item)
        }
        .quickLookPreview(self.$quickLookURL)
        .onChange(of: self.quickLookURL) { _, url in
            // The downloaded copy only lives while it's on screen.
            if url == nil { FilePreviewFiles.clear() }
        }
        .fileExporter(
            isPresented: Binding(get: { self.exporting != nil }, set: { if !$0 { self.exporting = nil } }),
            document: self.exporting,
            contentType: self.exporting?.contentType ?? .data,
            defaultFilename: self.exporting?.name) { result in
                self.exporting = nil
                if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
                    self.exportError = String(format: L("The file couldn't be saved: %@"), error.localizedDescription)
                }
            }
        .task(id: self.chat.sessionKey) {
            await self.chat.load()
        }
        .task(id: self.gateway.state.isConnected) { await self.loadReactionLevels() }
        // In the split view only the focused side answers menu commands (#404).
        .focusedSceneValue(\.transcriptFind, self.paneIsActive ? self.find : nil)
        .focusedSceneValue(\.transcriptNavigator, self.paneIsActive ? self.navigator : nil)
        .focusedSceneValue(\.chatExport, self.paneIsActive ? self.exportState : nil)
        .onAppear {
            self.paneHandles?.find = self.find
            self.paneHandles?.export = self.exportState
        }
        .readAloud(chat: self.chat, gateway: self.gateway, bottomInset: self.bottomChrome,
                   pillInset: self.$readAloudPillInset)
        .sheet(isPresented: self.$exportState.showExport, onDismiss: self.presentPendingExport) {
            ExportSheet(chat: self.chat, title: self.row?.title ?? L("Chat"), agentName: self.agent.name,
                        agents: self.gateway.agents) { file in
                self.pendingExport = file
            }
        }
        .alert(L("Couldn't Save File"), isPresented: Binding(get: { self.exportError != nil },
                                                             set: { if !$0 { self.exportError = nil } })) {
            Button(L("OK")) {}
        } message: {
            Text(self.exportError ?? "")
        }
        #if os(iOS)
        .sheet(item: self.$sharedFile) { file in
            ActivityView(url: file.url).presentationDetents([.medium, .large])
        }
        #endif
        .sheet(isPresented: self.$exportState.showBookmarks) {
            BookmarksView(store: BookmarkStore.shared(gatewayId: self.gateway.id), sessionKey: self.chat.sessionKey,
                          syncProblem: self.gateway.bookmarkSyncProblem) { bookmark in
                self.jump = TranscriptJump(id: UUID(), messageId: bookmark.messageId)
            }
        }
    }

    private var reasoningOff: Bool { self.row?.reasoningLevel == "off" }

    /// Tells VoiceOver the visible chat's run ended, once per run. The chat header's animated avatar
    /// already announces failures, so a failure is only spoken here when that avatar is off.
    private func announceOutcome() {
        guard AccessibilityAnnouncer.isVoiceOverRunning else { return }
        switch self.chat.lastOutcome {
        case .none:
            return
        case .success:
            let reply = self.chat.entries.last { if case let .assistant(turn) = $0 { turn.sender == nil } else { false } }
            guard case let .assistant(turn) = reply else { return }
            AccessibilityAnnouncer.announce(AccessibilityText.replyFinishedAnnouncement(author: self.agent.name, text: turn.body))
        case .error:
            guard !self.avatarAnnouncesErrors else { return }
            AccessibilityAnnouncer.announce(AccessibilityText.replyFailedAnnouncement(author: self.agent.name))
        }
    }

    /// A message search result is waiting to open Find in this chat.
    static func hasFindRequest(app: AppModel, gateway: GatewayStore, chat: ChatStore) -> Bool {
        guard let request = app.findRequest else { return false }
        return request.target.gatewayId == gateway.id && gateway.resolveSessionKey(request.target.sessionKey) == chat.sessionKey
    }

    /// Opens Find on a message search result meant for this chat.
    /// Opens the save panel (macOS) or share sheet (iOS) for the export built while the sheet was up.
    private func presentPendingExport() {
        guard let file = self.pendingExport else { return }
        self.pendingExport = nil
        #if os(iOS)
        guard let shared = SharedFile.write(name: file.name, data: file.data) else {
            self.exportError = L("The file couldn't be prepared for sharing.")
            return
        }
        self.sharedFile = shared
        #else
        self.exporting = file
        #endif
    }

    private func takeFindRequest() {
        guard let request = self.app.findRequest,
              Self.hasFindRequest(app: self.app, gateway: self.gateway, chat: self.chat),
              self.app.takeFindRequest(for: request.target) != nil
        else { return }
        // The whole cached history is searched, so the match can be selected wherever it is.
        Task {
            await self.chat.loadAllCached()
            self.find.present(query: request.query, select: request.match)
        }
    }

    /// Scrolls to a linked message once this chat's history has loaded.
    private func takeMessageJump() {
        guard self.chat.hasLoaded, let pending = self.app.messageJump, pending.target.gatewayId == self.gateway.id,
              self.gateway.resolveSessionKey(pending.target.sessionKey) == self.chat.sessionKey,
              let jump = self.app.takeMessageJump(for: pending.target)
        else { return }
        self.jump = TranscriptJump(id: jump.id, messageId: jump.messageId)
    }

    @ViewBuilder private var errorBar: some View {
        if let error = self.chat.errorMessage {
            HStack(spacing: Theme.Spacing.lg) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button(L("Retry")) { Task { await self.chat.load(force: true) } }
                    .glassButton()
                    .controlSize(.small)
            }
            .padding(.leading, Theme.Spacing.row)
            .padding(.trailing, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .glassSurface(in: Capsule(), tint: .orange)
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Passing notes that aren't failures, such as a quoted message that's no longer in history.
    @ViewBuilder private var noticeBar: some View {
        if let notice = self.chat.notice {
            HStack(spacing: Theme.Spacing.lg) {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    self.chat.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(L("Dismiss"))
            }
            .padding(.leading, Theme.Spacing.row)
            .padding(.trailing, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .glassSurface(in: Capsule())
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The safe area the transcript has to inset for itself. UIKit's scroll view already adds its
    /// own safe area (and SwiftUI shrinks it for the keyboard), so only macOS passes it through.
    private var transcriptSafeArea: EdgeInsets {
        #if os(macOS)
        self.safeArea
        #else
        EdgeInsets()
        #endif
    }
}

/// The "Thinking isn't being saved" hint. Its own view so its reads don't invalidate `ChatView`.
private struct ReasoningHint: View {
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
private struct TranscriptPane: View {
    let chat: ChatStore
    let find: TranscriptFind
    let jump: TranscriptJump?
    let navigator: TranscriptNavigator
    let disclosure: TranscriptDisclosure
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
    /// Not observed: only the list's bottom state and Find's toggle drive it.
    @State private var findTrim = TranscriptFindTrim()

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
            .onChange(of: ObjectIdentifier(self.chat)) { self.followBottom() }
            .onChange(of: self.find.isPresented) { _, shown in
                if shown { Task { await self.chat.loadAllCached() } }
                self.findTrim.findChanged(isPresented: shown, chat: self.chat)
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
                        let added = store.toggle(Bookmark(
                            sessionKey: chat.sessionKey, messageId: id, preview: Bookmark.preview(item?.plainText ?? ""),
                            role: item?.role.rawValue ?? "assistant", messageDate: item?.timestamp))
                        chat.notice = added && store.droppedCount > 0 ? L("To make room, Pincer removed an older bookmark.")
                            : added ? L("Bookmarked") : L("Bookmark removed")
                    },
                    isBookmarked: { [key = self.chat.sessionKey, id = self.gateway.id] in
                        BookmarkStore.shared(gatewayId: id).isBookmarked(sessionKey: key, messageId: $0)
                    },
                    previewHTML: { [$previewingHTML] in $previewingHTML.wrappedValue = HTMLPreviewItem(html: $0) },
                    quickLook: { [$quickLookURL] in $quickLookURL.wrappedValue = $0 },
                    openMCPServer: { [opener = self.openGatewaySettings, gateway = self.gateway] in
                        opener.mcpServer(gateway, name: $0)
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
private struct QuestionsAnimation: ViewModifier {
    @Environment(GatewayStore.self) private var gateway

    func body(content: Content) -> some View {
        content.animation(.snappy, value: self.gateway.questions.map(\.id))
    }
}

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
    @State private var showRuns = false
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
            .environment(\.chatChromeActions, ChatChromeActions(showRuns: self.$showRuns, toolsInspector: self.$toolsInspector))
            .environment(\.chatChromeSessionRow, self.row)
            .onGeometryChange(for: Bool.self) { $0.size.width >= ChatSplitHost.minWidth * 2 + 1 } action: { self.fitsSplit = $0 }
            .navigationTitle(self.key.map { chatTitle(self.gateway, key: $0, row: self.row) } ?? L("Chat"))
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
                ToolbarItem(placement: .topBarLeading) { if !split { ChatHeaderAvatar() } }
                #endif
                // A stable container, so a chat without branches doesn't remove the item (#262).
                ToolbarItem(placement: .primaryAction) {
                    ZStack {
                        if !split, let key { BranchHeaderChipView(chat: self.gateway.chat(for: key)) }
                    }
                }
                ToolbarItem(placement: .primaryAction) { ChatModelItem(row: split ? nil : self.row) }
                ToolbarItem(placement: .primaryAction) {
                    ChatSessionMenu(showRuns: self.$showRuns, toolsInspector: self.$toolsInspector, row: split ? nil : self.row)
                }
            }
            .sheet(item: self.$toolsInspector) { inspection in
                ChatToolsInspectorSheet(model: inspection.model, scopeTitle: inspection.scopeTitle, gateway: self.gateway)
            }
            .modifier(RunsPanelChrome(isPresented: self.$showRuns, showsToolbarButton: !split))
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

private struct ChatModelItem: View {
    let row: SessionRow?

    var body: some View {
        if let row { ModelPicker(row: row) }
    }
}

/// The chat's options. In the window toolbar it acts on the focused chat; in a split view header,
/// on that side's chat, through its `handles`.
struct ChatSessionMenu: View {
    @Binding var showRuns: Bool
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @FocusedValue(\.transcriptFind) private var focusedFind
    @FocusedValue(\.chatExport) private var focusedExport
    @Binding var toolsInspector: ChatToolsInspection?
    let row: SessionRow?
    var handles: ChatPaneHandles?
    /// Called before an item acts, so a split view side takes focus first.
    var willAct: () -> Void = {}

    private var find: TranscriptFind? { self.handles == nil ? self.focusedFind : self.handles?.find }
    private var chatExport: ChatExportState? { self.handles == nil ? self.focusedExport : self.handles?.export }

    var body: some View {
        if let row {
            Menu {
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
                }))
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
                Label(L("Chat Options"), systemImage: Theme.moreSymbol)
            }
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

struct ApprovalsBanner: View {
    let sessionKey: String?
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let approvals = self.gateway.approvals.filter { self.sessionKey == nil || $0.sessionKey == nil || $0.sessionKey == self.sessionKey }
        if !approvals.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                ForEach(approvals) { approval in
                    HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .symbolEffect(.wiggle, options: .nonRepeating)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("\(self.gateway.agent(approval.agentId ?? "main").name) wants to run a command")
                                .font(.callout.weight(.semibold))
                            Text(approval.command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                            if let cwd = approval.cwd {
                                Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let warning = approval.warning {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Button(L("Deny"), role: .destructive) {
                                Task { await self.gateway.resolveApproval(approval, decision: "deny") }
                            }
                            .glassButton()
                            Menu(L("Allow")) {
                                Button(L("Allow Once")) { Task { await self.gateway.resolveApproval(approval, decision: "allow-once") } }
                                if approval.allowsAlways {
                                    Button(L("Always Allow")) { Task { await self.gateway.resolveApproval(approval, decision: "allow-always") } }
                                }
                            } primaryAction: {
                                Task { await self.gateway.resolveApproval(approval, decision: "allow-once") }
                            }
                            .glassProminentButton()
                            .tint(.orange)
                            .fixedSize()
                        }
                    }
                    .padding(Theme.Spacing.xl)
                    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.xxLarge, style: .continuous), tint: .orange.opacity(0.35))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .glassGroup()
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.md)
            .animation(.snappy, value: approvals.map(\.id))
        }
    }
}

/// An attachment's bytes, handed to the system save panel.
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let name: String
    let data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.name = configuration.file.filename ?? "file"
        self.data = configuration.file.regularFileContents ?? Data()
    }

    var contentType: UTType {
        UTType(filenameExtension: (self.name as NSString).pathExtension) ?? .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }
}

extension ChatStore {
    /// Starts replying to a message: the composer shows the "Replying to" chip and takes focus.
    func beginReply(to messageId: String, agentName: String) {
        guard let target = self.replyTarget(for: messageId, you: Owner.displayName, agent: agentName) else { return }
        self.replyTarget = target
    }
}

/// Reply to Last Message (⇧⌘R) for the chat that has focus.
@MainActor
/// Equatable so a fresh value from each `ChatView` body pass doesn't count as a focus change:
/// otherwise every update rebuilds the main menu, which updates the view again, forever.
struct ReplyToLast: Equatable {
    let chat: ChatStore
    let agentName: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chat === rhs.chat && lhs.agentName == rhs.agentName
    }

    var isAvailable: Bool { self.chat.latestReplyableId != nil }

    func perform() {
        guard let id = self.chat.latestReplyableId else { return }
        self.chat.beginReply(to: id, agentName: self.agentName)
    }
}

extension FocusedValues {
    @Entry var replyToLast: ReplyToLast?
    @Entry var transcriptNavigator: TranscriptNavigator?
}

/// Placeholder rows shown while a chat's history loads, laid out like real transcript rows: an
/// avatar circle, a name bar and a few text bars. Fixed shapes, so it looks the same every time.
struct ChatLoadingSkeleton: View {
    var label: LocalizedStringKey = "Loading messages"
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onscreen = false
    @State private var dim = false

    private struct Row {
        let name: CGFloat
        /// Widths of the text bars as fractions of the available width; the last is the short one.
        let lines: [CGFloat]
    }

    private static let rows = [
        Row(name: 96, lines: [0.95, 0.85, 0.6]),
        Row(name: 84, lines: [0.9, 0.6]),
        Row(name: 108, lines: [0.92, 0.88, 0.6]),
        Row(name: 88, lines: [0.6]),
    ]

    private var pulses: Bool { !self.reduceMotion && self.scenePhase == .active && self.onscreen }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptMetrics.messageSpacing + 2 * TranscriptMetrics.verticalPadding) {
            ForEach(Self.rows.indices, id: \.self) { index in
                self.row(Self.rows[index])
            }
        }
        .padding(.horizontal, TranscriptMetrics.sidePadding)
        .padding(.top, self.topInset)
        .padding(.bottom, self.bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(self.pulses && self.dim ? 0.55 : 1)
        .onAppear { self.onscreen = true }
        .onDisappear { self.onscreen = false }
        .task(id: self.pulses) {
            guard self.pulses else {
                self.dim = false
                return
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { self.dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(self.label, bundle: .module))
    }

    private func row(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: TranscriptMetrics.avatarGap) {
            Circle().fill(Self.fill).frame(width: TranscriptMetrics.avatar, height: TranscriptMetrics.avatar)
            VStack(alignment: .leading, spacing: TranscriptMetrics.headerGap) {
                Self.bar(height: 10).frame(width: row.name)
                VStack(alignment: .leading, spacing: TranscriptMetrics.blockSpacing) {
                    ForEach(row.lines.indices, id: \.self) { line in
                        GeometryReader { proxy in
                            Self.bar(height: 12).frame(width: proxy.size.width * row.lines[line])
                        }
                        .frame(height: 12)
                    }
                }
            }
            .frame(maxWidth: TranscriptMetrics.maxCardWidth, alignment: .leading)
        }
    }

    private static let fill = Color.primary.opacity(0.09)

    private static func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(self.fill).frame(height: height)
    }
}
