import PincerKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the Read Aloud menu command and the auto-read hook act on for the chat in the focused window.
@MainActor
@Observable
final class ReadAloudChatState {
    typealias ReplyPreparer = @Sendable ([ChatItem]) async -> SpeechText.PreparedReply?

    weak var chat: ChatStore?
    weak var gateway: GatewayStore?
    private let controller: ReadAloudController
    private let prepareReply: ReplyPreparer
    private let prepareAutoReadReply: ReplyPreparer
    @ObservationIgnored private let autoReadBlocked: @MainActor () -> Bool
    /// The window is frontmost and this chat is the one on screen; auto-read only speaks then.
    var isVisible = true {
        didSet {
            if oldValue && !self.isVisible { self.invalidateAutoReadWork() }
        }
    }

    private(set) var preparedReply: SpeechText.PreparedReply?
    @ObservationIgnored private var preparedRevision: Int?
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var pendingPreparation: PreparationRequest?
    @ObservationIgnored private var activePreparation: Task<SpeechText.PreparedReply?, Never>?
    @ObservationIgnored private var activePreparationID: UUID?
    @ObservationIgnored private var activeRequest: PreparationRequest?
    @ObservationIgnored private var autoReadToken: UUID?
    @ObservationIgnored private var autoReadGeneration = 0
    @ObservationIgnored private var pendingAutoRead: AutoReadRequest?
    @ObservationIgnored private var activeAutoRead: Task<SpeechText.PreparedReply?, Never>?
    @ObservationIgnored private var activeAutoReadID: UUID?

#if DEBUG
    /// Internal worker status for deterministic tests waiting for all auto-read preparation to drain.
    var autoReadPreparationIsIdle: Bool {
        self.activeAutoRead == nil && self.pendingAutoRead == nil
    }
#endif

    private struct PreparationRequest {
        let chat: ChatStore
        let snapshot: [ChatItem]
        let revision: Int
        let contextGeneration: Int
    }

    private struct AutoReadRequest {
        let chat: ChatStore
        let gateway: GatewayStore
        let item: ChatItem
        let committedSource: ChatItem?
        let legacyItemsSnapshot: [ChatItem]?
        let messageID: String
        let revision: Int
        let contextGeneration: Int
        let autoReadGeneration: Int
        let callbackToken: UUID
    }

    init(controller: ReadAloudController = .shared,
         prepareReply: @escaping ReplyPreparer = { SpeechText.latestSpeakableReply(in: $0) },
         autoReadPreparer: ReplyPreparer? = nil,
         autoReadBlocked: @escaping @MainActor () -> Bool = { false })
    {
        self.controller = controller
        self.prepareReply = prepareReply
        self.prepareAutoReadReply = autoReadPreparer ?? prepareReply
        self.autoReadBlocked = autoReadBlocked
    }

    var lastReply: (id: String, text: String)? {
        guard let chat, self.preparedRevision == chat.contentRevision,
              let preparedReply = self.preparedReply else { return nil }
        return (preparedReply.messageId, preparedReply.text)
    }

    /// Reads the newest reply, or stops if something is being read.
    func toggleLastReply() {
        if self.controller.isActive { self.controller.stop(); return }
        guard let reply = self.lastReply else { return }
        self.controller.start(messageId: reply.id, text: reply.text, gateway: self.gateway?.voice)
    }

    var isEnabled: Bool { self.controller.isActive || self.lastReply != nil }

    /// Installs the same accepted-reply callback used by the SwiftUI modifier. Kept on the state
    /// so the production callback can be exercised without relying on a hosting view's lifecycle.
    func installAutoReadCallback() {
        guard let chat = self.chat else { return }
        if chat.onFinalAssistantReplyOwner === self, self.autoReadToken != nil,
           chat.onFinalAssistantReply != nil { return }
        self.invalidateAutoReadWork()
        let token = UUID()
        self.autoReadToken = token
        chat.onFinalAssistantReplyOwner = self
        chat.onFinalAssistantReply = { [weak self] item in
            self?.enqueueAutoRead(item, callbackToken: token)
        }
    }

    /// Clears this state's callback, or an unowned callback, just as the modifier's old cleanup did.
    func uninstallAutoReadCallback(from chat: ChatStore? = nil) {
        guard let chat = chat ?? self.chat,
              chat.onFinalAssistantReplyOwner === self || chat.onFinalAssistantReplyOwner == nil else { return }
        self.autoReadToken = nil
        self.invalidateAutoReadWork()
        chat.onFinalAssistantReply = nil
        chat.onFinalAssistantReplyOwner = nil
    }

    func bind(chat: ChatStore, gateway: GatewayStore) {
        let changed = self.chat !== chat || self.gateway !== gateway
        if changed, let oldChat = self.chat { self.clearAutoReadCallback(from: oldChat) }
        if changed { self.invalidateAutoReadWork() }
        self.chat = chat
        self.gateway = gateway
        guard changed else {
            self.requestPreparation()
            return
        }

        self.contextGeneration += 1
        self.pendingPreparation = nil
        self.preparedReply = nil
        self.preparedRevision = nil
        self.activePreparation?.cancel()
        self.observeItems(in: chat, generation: self.contextGeneration)
        self.requestPreparation()
    }

    func unbind() {
        self.contextGeneration += 1
        if let chat = self.chat { self.clearAutoReadCallback(from: chat) }
        self.invalidateAutoReadWork()
        self.chat = nil
        self.gateway = nil
        self.pendingPreparation = nil
        self.preparedReply = nil
        self.preparedRevision = nil
        self.activePreparation?.cancel()
    }

    private func enqueueAutoRead(_ item: ChatItem, callbackToken: UUID) {
        guard let chat = self.chat, let gateway = self.gateway,
              self.autoReadToken == callbackToken,
              chat.onFinalAssistantReplyOwner === self, chat.onFinalAssistantReply != nil,
              self.isAutoReadAvailable,
              item.role == .assistant, !item.isPending, !item.isError else { return }
        let messageID = item.transcriptId ?? item.id
        let committedSource: ChatItem?
        let legacyItemsSnapshot: [ChatItem]?
        if item.transcriptId == nil {
            // Old Gateway events may not carry a transcript ID. Keep the existing array buffer
            // by copy-on-write and verify membership on the worker instead of scanning on Main.
            committedSource = nil
            legacyItemsSnapshot = chat.items
        } else {
            guard let committed = chat.message(withId: messageID),
                  committed.id == item.id, committed.role == .assistant,
                  !committed.isPending, !committed.isError else { return }
            committedSource = committed
            legacyItemsSnapshot = nil
        }

        let request = AutoReadRequest(chat: chat, gateway: gateway, item: item,
                                      committedSource: committedSource,
                                      legacyItemsSnapshot: legacyItemsSnapshot,
                                      messageID: messageID, revision: chat.contentRevision,
                                      contextGeneration: self.contextGeneration,
                                      autoReadGeneration: self.autoReadGeneration,
                                      callbackToken: callbackToken)
        if self.activeAutoRead != nil {
            // Keep one latest reply while the current bounded worker retires. Its result is
            // suppressed while this replacement is present.
            self.pendingAutoRead = request
            return
        }
        self.startAutoRead(request)
    }

    private var isAutoReadAvailable: Bool {
        self.isVisible && !ReadAloudSupport.isVoiceOverRunning
            && !self.controller.isDictating && !self.autoReadBlocked()
    }

    private func startAutoRead(_ request: AutoReadRequest) {
        guard self.activeAutoRead == nil, self.isCurrent(request), self.pendingAutoRead == nil,
              self.isAutoReadAvailable else { return }
        let id = UUID()
        let preparer = self.prepareAutoReadReply
        let item = request.item
        let committedSource = request.committedSource
        let legacyItemsSnapshot = request.legacyItemsSnapshot
        let worker: Task<SpeechText.PreparedReply?, Never> = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            if let committedSource {
                guard committedSource == item, committedSource.role == .assistant,
                      !committedSource.isPending, !committedSource.isError else { return nil }
            } else if let legacyItemsSnapshot {
                guard legacyItemsSnapshot.contains(where: {
                    $0.id == item.id && $0.transcriptId == nil && $0 == item
                        && $0.role == .assistant && !$0.isPending && !$0.isError
                }) else { return nil }
            } else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let prepared = await preparer([item])
            guard !Task.isCancelled else { return nil }
            return prepared
        }
        self.activeAutoReadID = id
        self.activeAutoRead = worker
        Task { @MainActor [weak self] in
            let reply = await worker.value
            self?.finishAutoRead(reply, request: request, id: id)
        }
    }

    private func finishAutoRead(_ reply: SpeechText.PreparedReply?, request: AutoReadRequest, id: UUID) {
        guard self.activeAutoReadID == id else { return }
        self.activeAutoReadID = nil
        self.activeAutoRead = nil

        if self.pendingAutoRead == nil, self.isCurrent(request),
           let reply, reply.messageId == request.messageID, !reply.text.isEmpty,
           self.isAutoReadAvailable
        {
            self.controller.start(messageId: request.messageID, text: reply.text, gateway: request.gateway.voice)
        }

        if let pending = self.pendingAutoRead {
            self.pendingAutoRead = nil
            self.startAutoRead(pending)
        }
    }

    private func isCurrent(_ request: AutoReadRequest) -> Bool {
        guard self.chat === request.chat, self.gateway === request.gateway,
              self.contextGeneration == request.contextGeneration,
              self.autoReadGeneration == request.autoReadGeneration,
              self.autoReadToken == request.callbackToken,
              request.chat.onFinalAssistantReplyOwner === self,
              request.chat.onFinalAssistantReply != nil,
              request.chat.contentRevision == request.revision else { return false }
        if request.item.transcriptId == nil {
            // The worker validated the legacy no-transcript-ID item against its COW snapshot;
            // the unchanged content revision above proves it is still the committed source.
            return request.legacyItemsSnapshot != nil
        }
        guard let current = request.chat.message(withId: request.messageID) else { return false }
        return current.id == request.item.id && current.role == .assistant
            && !current.isPending && !current.isError
    }

    private func invalidateAutoReadWork() {
        self.autoReadGeneration += 1
        self.pendingAutoRead = nil
        self.activeAutoRead?.cancel()
    }

    private func clearAutoReadCallback(from chat: ChatStore) {
        guard chat.onFinalAssistantReplyOwner === self else { return }
        self.uninstallAutoReadCallback(from: chat)
    }

    private func observeItems(in chat: ChatStore, generation: Int) {
        withObservationTracking {
            _ = chat.items
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat, self.chat === chat, self.contextGeneration == generation else { return }
                self.observeItems(in: chat, generation: generation)
                self.requestPreparation()
            }
        }
    }

    private func requestPreparation() {
        guard let chat = self.chat else { return }
        let revision = chat.contentRevision
        if self.preparedRevision == revision || self.pendingPreparation?.revision == revision { return }
        if let activeRequest = self.activeRequest,
           activeRequest.chat === chat, activeRequest.revision == revision,
           activeRequest.contextGeneration == self.contextGeneration { return }
        if self.activePreparation != nil {
            if self.pendingPreparation?.revision != revision {
                self.pendingPreparation = PreparationRequest(chat: chat, snapshot: chat.items,
                                                             revision: revision, contextGeneration: self.contextGeneration)
                self.preparedReply = nil
                self.preparedRevision = nil
                self.activePreparation?.cancel()
            }
            return
        }
        self.pendingPreparation = PreparationRequest(chat: chat, snapshot: chat.items,
                                                     revision: revision, contextGeneration: self.contextGeneration)
        self.preparedReply = nil
        self.preparedRevision = nil
        self.startPendingPreparation()
    }

    private func startPendingPreparation() {
        guard self.activePreparation == nil, let request = self.pendingPreparation else { return }
        self.pendingPreparation = nil
        guard self.chat === request.chat, self.contextGeneration == request.contextGeneration,
              self.chat?.contentRevision == request.revision else {
            self.requestPreparation()
            return
        }

        let preparationID = UUID()
        let snapshot = request.snapshot
        let prepareReply = self.prepareReply
        let worker = Task.detached(priority: .userInitiated) {
            await prepareReply(snapshot)
        }
        self.activePreparationID = preparationID
        self.activePreparation = worker
        self.activeRequest = request
        Task { @MainActor [weak self] in
            let reply = await worker.value
            self?.finishPreparation(reply, request: request, id: preparationID)
        }
    }

    private func finishPreparation(_ reply: SpeechText.PreparedReply?, request: PreparationRequest, id: UUID) {
        guard self.activePreparationID == id else { return }
        self.activePreparationID = nil
        self.activePreparation = nil
        self.activeRequest = nil

        if self.chat === request.chat, self.contextGeneration == request.contextGeneration,
           self.chat?.contentRevision == request.revision, self.pendingPreparation == nil
        {
            self.preparedReply = reply
            self.preparedRevision = request.revision
        } else if self.pendingPreparation == nil, self.chat === request.chat,
                  self.contextGeneration == request.contextGeneration
        {
            self.requestPreparation()
        }
        self.startPendingPreparation()
    }
}

extension FocusedValues {
    @Entry var readAloud: ReadAloudChatState?
}

enum ReadAloudSupport {
    @MainActor static var isVoiceOverRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled
        #endif
    }
}

#if os(macOS)
/// Edit ▸ Read Last Reply Aloud (⌥⌘L) for the focused chat; "Stop Reading Aloud" while it reads.
struct ReadAloudCommands: Commands {
    @FocusedValue(\.readAloud) private var readAloud

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            ReadAloudCommandButton(state: self.readAloud)
        }
    }
}

private struct ReadAloudCommandButton: View {
    let state: ReadAloudChatState?

    var body: some View {
        let speaking = ReadAloudController.shared.isActive
        Button(speaking ? L("Stop Reading Aloud") : L("Read Last Reply Aloud")) { self.state?.toggleLastReply() }
            .shortcut(.readAloud)
            .disabled(self.state?.isEnabled != true)
    }
}
#endif

/// The "Speaking… / Stop" capsule over the bottom of the transcript while Read Aloud runs.
struct ReadAloudPill: View {
    let controller: ReadAloudController

    var body: some View {
        if case let phase = self.controller.phase, phase != .idle {
            Button { self.controller.stop() } label: {
                HStack(spacing: 8) {
                    if case .preparing = phase {
                        ProgressView().controlSize(.small)
                        Text("Preparing…", bundle: .module)
                    } else {
                        Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative)
                        Text("Speaking…", bundle: .module)
                    }
                    Text("·").foregroundStyle(.secondary)
                    Text("Stop", bundle: .module).fontWeight(.semibold)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Stop Reading Aloud"))
            .accessibilityValue(phase == .idle ? "" : { if case .preparing = phase { L("Preparing") } else { L("Speaking") } }())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ReadAloudPillHeight.self, value: geometry.size.height)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ReadAloudPillHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum ReadAloudPillLayout {
    static let bottomSpacing: CGFloat = 8
}

/// Wires a chat into Read Aloud: the menu command, the pill and auto-read of new replies.
struct ReadAloudModifier: ViewModifier {
    let chat: ChatStore
    let gateway: GatewayStore
    let bottomInset: CGFloat
    let controller: ReadAloudController
    @Binding var pillInset: CGFloat
    @State private var state: ReadAloudChatState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @AppStorage(ReadAloudSettings.autoReadKey) private var autoRead = false

    init(chat: ChatStore, gateway: GatewayStore, bottomInset: CGFloat, controller: ReadAloudController,
         pillInset: Binding<CGFloat>)
    {
        self.chat = chat
        self.gateway = gateway
        self.bottomInset = bottomInset
        self.controller = controller
        self._pillInset = pillInset
        self._state = State(initialValue: ReadAloudChatState(controller: controller))
    }

    func body(content: Content) -> some View {
        let pillInset = self.$pillInset
        content
            // In the split view only the focused side answers the menu command and shows the pill (#404).
            .focusedSceneValue(\.readAloud, self.paneIsActive ? self.state : nil)
            .overlay(alignment: .bottom) {
                if self.paneIsActive { ReadAloudPill(controller: self.controller)
                    .padding(.bottom, self.bottomInset + ReadAloudPillLayout.bottomSpacing)
                    .animation(.snappy, value: self.controller.phase) }
            }
            .onPreferenceChange(ReadAloudPillHeight.self) { height in
                let inset = height > 0 ? height + ReadAloudPillLayout.bottomSpacing : 0
                if abs(pillInset.wrappedValue - inset) > 0.5 { pillInset.wrappedValue = inset }
            }
            .onChange(of: self.paneIsActive) { _, isActive in
                if !isActive { pillInset.wrappedValue = 0 }
            }
            .background { self.hardwareShortcut }
            // Lowest priority: the composer, find bar and menus see Esc first and only pass it on when they don't use it.
            .onKeyPress(.escape) { self.stopWithEscape() }
            .onAppear { self.install() }
            .onChange(of: self.scenePhase) {
                self.state.isVisible = self.scenePhase == .active
                // Another window showing this chat may have closed and taken the handler with it.
                if self.state.isVisible { self.install() }
            }
            .onChange(of: self.autoRead) { self.install() }
            .onChange(of: ObjectIdentifier(self.chat)) { self.install() }
            .onChange(of: self.gateway.id) { self.install() }
            .onDisappear {
                self.uninstall()
                self.state.unbind()
            }
    }

    /// ⌥⌘L on iPad hardware keyboards (macOS has the Edit menu command); only the active pane answers.
    @ViewBuilder private var hardwareShortcut: some View {
        #if os(iOS)
        if self.paneIsActive {
            Button(self.controller.isActive ? L("Stop Reading Aloud") : L("Read Last Reply Aloud")) {
                if self.controller.isActive { self.controller.stop() }
                else { self.state.toggleLastReply() }
            }
            .shortcut(.readAloud)
            .disabled(!self.state.isEnabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #endif
    }

    private func stopWithEscape() -> KeyPress.Result {
        let controller = self.controller
        guard self.paneIsActive, controller.isActive, !controller.isDictating else { return .ignored }
        controller.stop()
        return .handled
    }

    private func install() {
        self.state.bind(chat: self.chat, gateway: self.gateway)
        self.state.isVisible = self.scenePhase == .active
        guard self.autoRead else { return self.uninstall() }
        self.state.installAutoReadCallback()
    }

    private func uninstall() {
        self.state.uninstallAutoReadCallback(from: self.chat)
    }
}

extension View {
    /// Read Aloud for a chat: the Edit menu command, the Stop pill and auto-read.
    func readAloud(chat: ChatStore, gateway: GatewayStore, bottomInset: CGFloat, pillInset: Binding<CGFloat>,
                   controller: ReadAloudController = .shared) -> some View
    {
        self.modifier(ReadAloudModifier(chat: chat, gateway: gateway, bottomInset: bottomInset,
                                        controller: controller, pillInset: pillInset))
    }
}
