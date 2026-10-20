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

/// A value tagged with the chat it came from, so a change handler can tell a chat switch apart from
/// a change within one chat (#571).
struct PerChat<Value: Equatable>: Equatable {
    let chat: ObjectIdentifier
    let value: Value

    @MainActor init(chat: ChatStore, value: Value) {
        self.chat = ObjectIdentifier(chat)
        self.value = value
    }
}

/// `ChatView`'s state for the chat it shows, made fresh for each chat (#571).
@MainActor @Observable
final class ChatViewState {
    let disclosure = TranscriptDisclosure()
    let find = TranscriptFind()
    let navigator = TranscriptNavigator()
    let exportState = ChatExportState()
    let bottomState = TranscriptBottomState()
    @ObservationIgnored let findTrim = TranscriptFindTrim()
    var jump: TranscriptJump?
    var previewing: ImageRef?
    var previewingHTML: HTMLPreviewItem?
    var quickLookURL: URL?
    var exporting: ExportedFile?
    /// A built export waiting for its sheet to close: the save panel or share sheet can't open over it (#430).
    var pendingExport: ExportedFile?
    var exportError: String?
    #if os(iOS)
    var sharedFile: SharedFile?
    @ObservationIgnored let sharedFilePreparation = SharedFilePreparation()
    #endif
}

struct ChatView: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(\.isDetachedChatScene) private var isDetachedCommandScene
    #endif
    #if DEBUG && os(iOS)
    @Environment(\.chatTopChromeGeometryProbe) private var topChromeGeometryProbe
    #endif
    @AppStorage("pincer.reasoningHintDismissed") private var hintDismissed = false
    @AppStorage(AvatarSettings.animatedKey) private var avatarAnnouncesErrors = true
    /// The view outlives a chat switch (#571), so per-chat state lives here and starts over per chat.
    @State private var scoped = ChatScoped<ChatViewState>()
    private var state: ChatViewState { self.scoped.value(for: self.chat.sessionKey) { ChatViewState() } }
    private var disclosure: TranscriptDisclosure { self.state.disclosure }
    private var find: TranscriptFind { self.state.find }
    private var navigator: TranscriptNavigator { self.state.navigator }
    private var exportState: ChatExportState { self.state.exportState }
    private var bottomState: TranscriptBottomState { self.state.bottomState }
    @State private var readAloudPillInset: CGFloat = 0
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @Environment(\.chatPaneHandles) private var paneHandles

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
        .onChange(of: PerChat(chat: self.chat, value: self.chat.lastOutcomeAt)) { old, new in
            // A switch to a chat that has finished before isn't a new reply (#571).
            guard old.chat == new.chat, new.value != nil else { return }
            self.announceOutcome()
            #if DEBUG
            BodyCounter.report()
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
            chat: self.chat, find: self.find, jump: self.state.jump, navigator: self.navigator, disclosure: self.disclosure,
            findTrim: self.state.findTrim,
            previewing: Bindable(self.state).previewing, previewingHTML: Bindable(self.state).previewingHTML,
            quickLookURL: Bindable(self.state).quickLookURL,
            exporting: Bindable(self.state).exporting, bottomState: self.bottomState,
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
                        #if DEBUG && os(iOS)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            self.topChromeGeometryProbe?.report(.approvals, $0)
                        }
                        #endif
                    if self.find.isPresented {
                        TranscriptFindBar(find: self.find, reasoningOff: self.reasoningOff)
                            #if DEBUG && os(iOS)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                self.topChromeGeometryProbe?.report(.find, $0)
                            }
                            #endif
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
                            .id(self.chat.sessionKey)
                    }
                    PendingQuestionCard(chat: self.chat)
                    // Re-made per chat: its field, dictation and attachment state belong to one chat.
                    Composer(chat: self.chat, placeholder: self.composerPlaceholder, find: self.find)
                        .id(self.chat.sessionKey)
                        .transition(.identity)
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
            // A switch shows the other chat as it is: no bar, card or Find bar animates across it.
            .transaction(value: ObjectIdentifier(self.chat)) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }

    private var presentedContent: some View {
        let state = self.state
        return self.transcript
        .sheet(item: Bindable(state).previewing) { ref in
            ImagePreview(ref: ref, sessionKey: self.chat.sessionKey)
        }
        .sheet(item: Bindable(state).previewingHTML) { item in
            HTMLPreviewSheet(item: item)
        }
        .modifier(ChatQuickLookLifecycle(url: Bindable(state).quickLookURL))
        .fileExporter(
            isPresented: Binding(get: { state.exporting != nil }, set: { if !$0 { state.exporting = nil } }),
            document: state.exporting,
            contentType: state.exporting?.contentType ?? .data,
            defaultFilename: state.exporting?.name) { result in
                state.exporting = nil
                if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
                    state.exportError = String(format: L("The file couldn't be saved: %@"), error.localizedDescription)
                }
            }
        .task(id: self.chat.sessionKey) {
            await self.chat.load()
        }
        .task(id: PerChat(chat: self.chat, value: self.gateway.state.isConnected)) { await self.loadReactionLevels() }
        // In the split view only the focused side answers menu commands (#404).
        .focusedSceneValue(\.transcriptFind, self.paneIsActive ? self.find : nil)
        .focusedSceneValue(\.transcriptNavigator, self.paneIsActive ? self.navigator : nil)
        .focusedSceneValue(\.chatExport, self.paneIsActive ? self.exportState : nil)
        #if os(macOS)
        .focusedSceneValue(\.chatWindowCommandTarget, self.paneIsActive
            ? ChatWindowCommandTarget(ref: .init(gatewayId: self.gateway.id, sessionKey: self.chat.sessionKey),
                                      isDetached: self.isDetachedCommandScene) : nil)
        #endif
        .onAppear { self.publishPaneHandles() }
        .onChange(of: self.chat.sessionKey) { self.chatChanged() }
        .readAloud(chat: self.chat, gateway: self.gateway, bottomInset: self.bottomChrome,
                   pillInset: self.$readAloudPillInset)
        .sheet(isPresented: Bindable(state.exportState).showExport, onDismiss: self.presentPendingExport) {
            ExportSheet(chat: self.chat, title: self.row?.title ?? L("Chat"), agentName: self.agent.name,
                        agents: self.gateway.agents) { file in
                state.pendingExport = file
            }
        }
        .alert(L("Couldn't Save File"), isPresented: Binding(get: { state.exportError != nil },
                                                             set: { if !$0 { state.exportError = nil } })) {
            Button(L("OK")) {}
        } message: {
            Text(state.exportError ?? "")
        }
        #if os(iOS)
        .sheet(item: Bindable(state).sharedFile) { file in
            ActivityView(url: file.url).presentationDetents([.medium, .large])
        }
        .onDisappear { self.state.sharedFilePreparation.cancel() }
        #endif
        .sheet(isPresented: Bindable(state.exportState).showBookmarks) {
            BookmarksView(store: BookmarkStore.shared(gatewayId: self.gateway.id), sessionKey: self.chat.sessionKey,
                          syncProblem: self.gateway.bookmarkSyncProblem) { bookmark in
                state.jump = TranscriptJump(id: UUID(), messageId: bookmark.messageId)
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
        let state = self.state
        guard let file = state.pendingExport else { return }
        state.pendingExport = nil
        #if os(iOS)
        state.sharedFilePreparation.request(name: file.name, data: file.data) { shared in
            guard let shared else {
                state.exportError = L("The file couldn't be prepared for sharing.")
                return
            }
            state.sharedFile = shared
        }
        #else
        state.exporting = file
        #endif
    }

    private func takeFindRequest() {
        guard let request = self.app.findRequest,
              Self.hasFindRequest(app: self.app, gateway: self.gateway, chat: self.chat),
              self.app.takeFindRequest(for: request.target) != nil
        else { return }
        // The whole cached history is searched, so the match can be selected wherever it is.
        let find = self.find
        Task {
            await self.chat.loadAllCached()
            find.present(query: request.query, select: request.match)
        }
    }

    /// Scrolls to a linked message once this chat's history has loaded.
    private func takeMessageJump() {
        guard self.chat.hasLoaded, let pending = self.app.messageJump, pending.target.gatewayId == self.gateway.id,
              self.gateway.resolveSessionKey(pending.target.sessionKey) == self.chat.sessionKey,
              let jump = self.app.takeMessageJump(for: pending.target)
        else { return }
        self.state.jump = TranscriptJump(id: jump.id, messageId: jump.messageId)
    }

    private func publishPaneHandles() {
        self.paneHandles?.find = self.find
        self.paneHandles?.export = self.exportState
    }

    /// The view stayed and its chat changed (#571): what a freshly built view did on appear.
    private func chatChanged() {
        if let retired = self.scoped.takeRetired() {
            retired.findTrim.retire()
            #if os(iOS)
            retired.sharedFilePreparation.cancel()
            #endif
        }
        self.publishPaneHandles()
        self.takeFindRequest()
        self.takeMessageJump()
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
