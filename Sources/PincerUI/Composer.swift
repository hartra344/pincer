import PhotosUI
import PincerKit
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Bindable var chat: ChatStore
    let placeholder: String
    /// While Find is open the field doesn't take focus on appear; nil means it always may.
    var find: TranscriptFind?
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.appTheme) private var theme
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var isTargeted = false
    @State private var menuSelection = 0
    /// Text the suggestion menu was dismissed at (Escape); it comes back once the text changes.
    @State private var dismissedMenuText: String?
    @State private var caretAtEnd = true
    @State private var focusRequest = 0
    @State private var sendPending = false
    @State private var selection: NSRange?
    @State private var fieldFocused = false
    @State private var caretRequest: CaretRequest?
    @State private var dictationHolder = DictationHolder()
    private var dictation: DictationModel { self.dictationHolder.model }
    @ScaledMetric(relativeTo: .body) private var attachIconSize: CGFloat = 14

    private static let corner: CGFloat = 22
    /// Height of a single-line field, which the side controls match.
    static let controlHeight: CGFloat = 40

    var body: some View {
        #if DEBUG
        let _ = BodyCounter.hit("Composer")
        #endif
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let offlineNote = self.offlineNote {
                Label(offlineNote, systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
            if let edit = self.chat.editTarget {
                MessageEditChip(originalText: edit.originalText) { self.chat.cancelEdit() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let target = self.chat.replyTarget {
                ReplyChip(target: target) { self.chat.replyTarget = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !self.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(self.attachments) { attachment in
                            AttachmentThumb(attachment: attachment) {
                                self.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
                self.attachMenu
                self.textField
                self.dictationButton
                ContextMeter(chat: self.chat)
                if self.chat.isRunning {
                    Button {
                        Task { await self.chat.abort() }
                    } label: {
                        ComposerActionLabel(systemImage: "stop.fill", tint: .red, active: true)
                    }
                    .buttonStyle(.plain)
                    .composerControl()
                    .help(Text("Stop the current run", bundle: .module))
                    .shortcut(.stopRun)
                    .accessibilityLabel(Text("Stop", bundle: .module))
                    .transition(.scale.combined(with: .opacity))
                }
                Button(action: self.submit) {
                    ComposerActionLabel(systemImage: "arrow.up", tint: self.theme.accent, active: self.canSend)
                }
                .buttonStyle(.plain)
                .composerControl()
                .disabled(!self.canSend || self.sendPending)
                .help(self.sendLabel)
                .accessibilityLabel(self.sendLabel)
                .accessibilityHint(self.gateway.state.isConnected ? "" : Self.offlineHint)
            }
            .padding(.leading, Theme.Spacing.lg)
            .padding(.trailing, 7)
            .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(self.theme.accent, lineWidth: 2)
                    .opacity(self.isTargeted ? 1 : 0))
            .animation(.snappy, value: self.chat.isRunning)
            .animation(.snappy, value: self.canSend)
            // An overlay, so the floating chrome's measured height (and the transcript's inset) stays put.
            .overlay(alignment: .top) {
                let suggestions = self.suggestions
                if !suggestions.isEmpty {
                    // A fixed-height box whose bottom sits just above the field, so the menu grows upward.
                    let box = SlashCommandMenu.maxHeight + 40
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        SlashCommandMenu(suggestions: suggestions, selection: self.$menuSelection, onPick: self.accept)
                    }
                    .frame(height: box, alignment: .bottom)
                    .offset(y: -(box + 8))
                    .transition(.opacity)
                }
            }
            .onChange(of: self.suggestions.map(\.id)) { self.menuSelection = 0 }
        }
        .onChange(of: self.chat.editTarget) { old, new in
            if let new, new != old { self.focusRequest += 1 }
        }
        .onChange(of: self.chat.replyTarget) { old, new in
            if let new, new != old { self.focusRequest += 1 }
        }
        .padding(.horizontal, Theme.Spacing.row)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xl)
        .onDrop(of: [.fileURL, .image, .audiovisualContent, .pdf], isTargeted: self.$isTargeted) { providers in
            self.ingest(providers.map(PastedMedia.provider))
            return true
        }
        .fileImporter(isPresented: self.$importing, allowedContentTypes: [.image, .pdf, .plainText, .item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            self.ingest(urls.map(PastedMedia.file))
        }
        .dictationLifecycle(self.dictation, draft: self.chat.draft.text, chatKey: self.chat.sessionKey)
        .task(id: self.isTypingCommand ? self.chat.sessionKey : nil) {
            guard self.isTypingCommand else { return }
            await self.gateway.loadCommands(sessionKey: self.chat.sessionKey, agentId: self.agentId)
            await self.gateway.loadModels(agentId: self.agentId)
        }
        .task(id: self.chat.sessionKey) {
            // The meter falls back to the model's context window when the session row has none.
            if self.gateway.needsModelCatalogForContext(self.chat.sessionKey) {
                await self.gateway.loadModels(agentId: self.agentId)
            }
        }
        .onChange(of: self.photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        self.addImage(data, name: "photo.jpg")
                    }
                }
                self.photoItems = []
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button { self.importing = true } label: { Label { Text("Choose File…", bundle: .module) } icon: { Image(systemName: "doc") } }
            #if os(iOS)
            Button {
                let items = MediaPasteboard.items(from: .general)
                if !items.isEmpty {
                    self.ingest(items)
                } else if let image = UIPasteboard.general.image, let data = image.pngData() {
                    self.addImage(data, name: "Pasted Image.png")
                } else {
                    self.attachmentError = L("There’s no image or file on the clipboard.")
                }
            } label: {
                Label { Text("Paste Image", bundle: .module) } icon: { Image(systemName: "doc.on.clipboard") }
            }
            #endif
        } label: {
            Image(systemName: "plus")
                .font(.system(size: min(self.attachIconSize, 22), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        } primaryAction: {
            self.importing = true
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .composerControl()
        .disabled(!self.canAttach)
        .help(self.canAttach ? L("Attach files") : Self.attachmentsNeedConnection)
        .accessibilityLabel(Text("Attach files", bundle: .module))
        .accessibilityHint(self.canAttach ? "" : Self.attachmentsNeedConnection)
        .overlay(alignment: .trailing) {
            #if os(iOS)
            PhotosPicker(selection: self.$photoItems, maxSelectionCount: 6, matching: .images) {
                Image(systemName: "photo").font(.title3)
            }
            .disabled(!self.canAttach)
            .help(self.canAttach ? L("Attach photos") : Self.attachmentsNeedConnection)
            .accessibilityLabel(Text("Attach photos", bundle: .module))
            .accessibilityHint(self.canAttach ? "" : Self.attachmentsNeedConnection)
            .offset(x: 30)
            #endif
        }
        #if os(iOS)
        .padding(.trailing, 30)
        #endif
    }

    private var text: String {
        get { self.chat.draft.text }
        nonmutating set { self.chat.draft.text = newValue }
    }

    private var attachments: [OutgoingAttachment] {
        get { self.chat.draft.attachments }
        nonmutating set { self.chat.draft.attachments = newValue }
    }

    private var canSend: Bool {
        guard !self.chat.isSendingEdit else { return false }
        guard !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.attachments.isEmpty else { return false }
        // Offline, messages queue in the outbox (attachments too while they fit on disk); commands need the Gateway.
        return self.gateway.state.isConnected || (self.attachmentsFitOffline && !self.isTypingCommand)
    }

    /// Offline, attachments queue like text while the outbox can keep them on disk.
    private var attachmentsFitOffline: Bool {
        self.attachments.isEmpty || self.gateway.canPersistAttachments(bytes: self.attachments.reduce(0) { $0 + $1.data.count })
    }

    private var canAttach: Bool { self.gateway.state.isConnected || self.gateway.canPersistAttachments(bytes: 0) }

    private static var offlineHint: String { L("Offline — messages send when you reconnect") }
    private static var attachmentsNeedConnection: String { L("Attachments need a connection") }

    private var sendLabel: String {
        if !self.gateway.state.isConnected { return L("Queue Message") }
        return self.chat.isRunning ? L("Queue a follow-up") : L("Send")
    }

    /// Offline: what happens to what's typed, and how many messages are waiting.
    private var offlineNote: String? {
        guard !self.gateway.state.isConnected else { return nil }
        let queued = self.chat.unsentEntries.filter { $0.state == .queued }.count
        let waiting = queued == 0 ? nil : L("\(queued) messages queued")
        if !self.attachments.isEmpty, !self.attachmentsFitOffline {
            let reason = self.gateway.canPersistAttachments(bytes: 0)
                ? L("Too large to queue offline — sends when you’re connected") : Self.attachmentsNeedConnection
            return [waiting, reason].compactMap(\.self).joined(separator: " · ")
        }
        if self.isTypingCommand {
            return [waiting, L("Connect to run commands")].compactMap(\.self).joined(separator: " · ")
        }
        return [waiting, Self.offlineHint].compactMap(\.self).joined(separator: " · ")
    }

    private var textField: some View {
        ComposerTextView(
            placeholder: self.placeholder,
            text: self.$chat.draft.text,
            menuActive: !self.suggestions.isEmpty,
            escapeActive: self.chat.replyTarget != nil || self.chat.editTarget != nil || self.dictation.isActive
                || ReadAloudController.shared.isActive,
            focusRequest: self.focusRequest,
            onSubmit: self.submit,
            onMedia: self.ingest,
            onKey: self.menuKey,
            onCaretAtEnd: { if self.caretAtEnd != $0 { self.caretAtEnd = $0 } },
            onSelectionChange: self.selectionChanged,
            caretRequest: self.caretRequest,
            onFocusChange: { self.fieldFocused = $0 },
            autoFocus: { [find = self.find, app = self.app, gateway = self.gateway, chat = self.chat] in
                // Opening on a message search result: the Find field keeps focus.
                !(find?.isPresented ?? false) && !ChatView.hasFindRequest(app: app, gateway: gateway, chat: chat)
            })
            .padding(.vertical, 11)
            .frame(minHeight: Self.controlHeight)
    }

    private var dictationButton: some View {
        DictationButton(
            model: self.dictation, app: self.app, sessionKey: self.chat.sessionKey, draft: self.$chat.draft.text, selection: self.selection,
            onCaret: self.placeCaret, isFieldFocused: self.fieldFocused, onRequestFocus: { self.focusRequest += 1 })
    }

    private func selectionChanged(_ range: NSRange) {
        if self.selection != range { self.selection = range }
    }

    private func placeCaret(_ offset: Int) {
        self.caretRequest = CaretRequest(offset: offset, serial: (self.caretRequest?.serial ?? 0) + 1)
    }

    /// Words still being recognised land in the draft before it's read, so Send doesn't lose the last few.
    private func submit() {
        guard !self.sendPending else { return }
        guard self.dictation.isActive else {
            self.send()
            return
        }
        self.sendPending = true
        Task {
            await self.dictation.finishForSend()
            self.sendPending = false
            self.send()
        }
    }

    private func send() {
        let suggestions = self.suggestions
        if suggestions.indices.contains(self.menuSelection), !suggestions[self.menuSelection].isComplete(for: self.text) {
            self.accept(suggestions[self.menuSelection])
            return
        }
        guard self.canSend else { return }
        let text = SlashCommand.outgoingText(self.text, commands: self.gateway.slashCommands(for: self.chat.sessionKey))
        let attachments = self.attachments
        if self.chat.editTarget != nil, !self.isTypingCommand {
            self.attachmentError = nil
            Task {
                // The store restores the pre-edit draft on success; on failure the edit stays in progress.
                _ = await self.chat.sendEdit(text, attachments: attachments)
            }
            return
        }
        let draft = self.chat.draft
        // Commands aren't replies; the reply stays set for the next message.
        let replyTo = self.isTypingCommand ? nil : self.chat.replyTarget
        self.chat.draft = ComposerDraft()
        self.attachmentError = nil
        Task {
            guard case .failed = await self.chat.sendMessage(text, attachments: attachments, replyTo: replyTo) else { return }
            // Keep what was typed so it can be retried, unless something new was started meanwhile.
            if self.chat.draft.text.isEmpty, self.chat.draft.attachments.isEmpty { self.chat.draft = draft }
        }
    }

    // MARK: Slash commands

    private var row: SessionRow? { self.chat.sessionRow }

    private var agentId: String {
        self.row?.agentId ?? self.chat.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? self.gateway.defaultAgentId
    }

    private var isTypingCommand: Bool { self.text.hasPrefix("/") }

    private var suggestions: [SlashSuggestion] {
        guard self.isTypingCommand, self.caretAtEnd, self.text != self.dismissedMenuText else { return [] }
        // A fully typed command stays listed; Return sends it since accepting wouldn't change anything.
        return SlashCompletion.suggestions(
            for: self.text, commands: self.gateway.slashCommands(for: self.chat.sessionKey), choices: self.choices)
    }

    /// Values for a command's argument: the catalog's, or ones Pincer knows (models, thinking levels).
    private func choices(_ command: SlashCommand, _ index: Int, _ arg: SlashCommandArg?) -> [SlashCommandChoice] {
        if let arg, !arg.choices.isEmpty { return arg.choices }
        guard index == 0 else { return [] }
        if command.matches("model") || arg?.name == "model" {
            return (self.gateway.modelCatalogs[self.agentId] ?? [])
                .filter { $0.isAvailable && $0.manualSelectionAllowed }
                .map { SlashCommandChoice(value: $0.ref, label: $0.displayName, detail: $0.provider) }
        }
        if command.matches("think") {
            let levels = self.row?.thinkingLevelChoices?.nilIfEmpty
                ?? SlashCommand.fallbackThinkingLevels.map { SlashCommandChoice(value: $0) }
            return [SlashCommandChoice(value: "default")] + levels.filter { $0.value != "default" }
        }
        return []
    }

    private func accept(_ suggestion: SlashSuggestion) {
        self.text = suggestion.replacement
        self.dismissedMenuText = nil
        self.menuSelection = 0
        self.caretAtEnd = true
    }

    private func menuKey(_ key: ComposerKey) -> Bool {
        let suggestions = self.suggestions
        guard !suggestions.isEmpty else {
            guard key == .escape else { return false }
            let action = ComposerEscapeAction.resolve(
                menuOpen: false, dictating: self.dictation.isActive, editing: self.chat.editTarget != nil,
                replying: self.chat.replyTarget != nil, readingAloud: ReadAloudController.shared.isActive)
            switch action {
            case .finishDictation: self.dictation.finish()
            case .cancelEdit: self.chat.cancelEdit()
            case .cancelReply: self.chat.replyTarget = nil
            case .stopReadAloud: ReadAloudController.shared.stop()
            case .dismissMenu, nil: return false
            }
            return true
        }
        switch key {
        case .up:
            self.menuSelection = (self.menuSelection - 1 + suggestions.count) % suggestions.count
        case .down:
            self.menuSelection = (self.menuSelection + 1) % suggestions.count
        case .tab:
            self.accept(suggestions[min(self.menuSelection, suggestions.count - 1)])
        case .escape:
            self.dismissedMenuText = self.text
        }
        return true
    }

    // MARK: Attachments

    private var attachmentIngest: AttachmentIngest {
        AttachmentIngest(
            limits: self.gateway.uploadLimits,
            limitsAreLastKnown: self.gateway.uploadLimitsAreLastKnown,
            add: { self.attachments.append($0) },
            report: { self.attachmentError = $0 })
    }

    private func ingest(_ items: [PastedMedia]) {
        self.attachmentIngest.ingest(items)
    }

    private func addImage(_ data: Data, name: String) {
        self.attachmentIngest.addImage(data, name: name)
    }
}

/// The round Send / Stop control: a tinted glass disc when active, a quiet one when not.
private struct ComposerActionLabel: View {
    let systemImage: String
    let tint: Color
    let active: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 14

    var body: some View {
        let icon = Image(systemName: self.systemImage)
            .font(.system(size: min(self.iconSize, 22), weight: .bold))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        if #available(macOS 26, iOS 26, *) {
            icon
                .foregroundStyle(self.active ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .glassEffect(self.active ? Glass.regular.tint(self.tint).interactive() : .identity, in: Circle())
        } else {
            icon
                .foregroundStyle(self.active ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .background(self.active ? AnyShapeStyle(self.tint.gradient) : AnyShapeStyle(.quaternary), in: Circle())
        }
    }
}

private extension View {
    /// Side controls share one box as tall as a single-line field, so with bottom alignment they
    /// centre on the first line and stay pinned to the last line as the field grows.
    func composerControl() -> some View {
        self.frame(width: 32, height: Composer.controlHeight)
    }
}

private extension Array {
    var nilIfEmpty: Self? { self.isEmpty ? nil : self }
}

/// "Replying to <Sender>" above the composer, with the start of the message and a cancel button.
private struct ReplyChip: View {
    let target: ReplyTarget
    let onCancel: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrowshape.turn.up.left")
                .foregroundStyle(self.theme.accent)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Replying to **\(self.target.senderLabel)**", bundle: .module)
                    .font(.caption)
                Text(Replies.previewLine(self.target.preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: self.onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel reply", bundle: .module))
            .accessibilityLabel(Text("Cancel reply", bundle: .module))
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
