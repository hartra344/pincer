import PincerKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @AppStorage("pincer.reasoningHintDismissed") private var hintDismissed = false
    @State private var disclosure = TranscriptDisclosure()
    @State private var previewing: ImageRef?
    @State private var exporting: ExportedFile?
    @State private var find = TranscriptFind()

    private var row: SessionRow? { self.gateway.sessions[self.chat.sessionKey] }
    private var agent: AgentSummary { self.gateway.agent(self.row?.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "main") }

    /// Heights of the floating chrome, so the transcript can scroll underneath it.
    @State private var topChrome: CGFloat = 0
    @State private var bottomChrome: CGFloat = 0
    @State private var safeArea = EdgeInsets()

    var body: some View {
        self.transcript
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
                    self.reasoningHint
                    if let card = self.chat.progressCard {
                        ProgressCardView(chat: self.chat, card: card)
                    }
                    PendingQuestionCard(chat: self.chat)
                    Composer(chat: self.chat, placeholder: "Message #\(self.row?.title ?? "chat")",
                             autoFocus: { [find = self.find, app = self.app, gateway = self.gateway, chat = self.chat] in
                                 // Opening on a message search result: the Find field keeps focus.
                                 !find.isPresented && !Self.hasFindRequest(app: app, gateway: gateway, chat: chat)
                             })
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.bottomChrome = $0 }
            }
            .animation(.snappy, value: self.chat.errorMessage)
            .animation(.snappy, value: self.chat.progressCard)
            .animation(.snappy, value: self.gateway.questions.map(\.id))
        .navigationTitle(self.row?.title ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "Chat")
        #if os(macOS)
        .navigationSubtitle(self.subtitle)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { self.toolbar }
        .sheet(item: self.$previewing) { ref in
            ImagePreview(ref: ref, sessionKey: self.chat.sessionKey)
        }
        .fileExporter(
            isPresented: Binding(get: { self.exporting != nil }, set: { if !$0 { self.exporting = nil } }),
            document: self.exporting,
            contentType: self.exporting?.contentType ?? .data,
            defaultFilename: self.exporting?.name) { _ in
                self.exporting = nil
            }
        .task(id: self.chat.sessionKey) {
            await self.chat.load()
        }
        .focusedSceneValue(\.transcriptFind, self.find)
        .onAppear { self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff) }
        .onChange(of: self.chat.entries) { self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff) }
        .onChange(of: self.reasoningOff) { self.find.update(entries: self.chat.entries, reasoningOff: self.reasoningOff) }
        .onChange(of: self.app.findRequest, initial: true) { self.takeFindRequest() }
        #if os(iOS)
        // Menu commands are macOS-only; on iOS a hardware keyboard reaches these instead.
        .background {
            Group {
                Button("Find in Chat") { self.find.present() }.keyboardShortcut("f", modifiers: .command)
                if !self.find.isPresented {
                    Button("Find Next") { self.find.next() }.keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { self.find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }

    private var reasoningOff: Bool { self.row?.reasoningLevel == "off" }

    /// A message search result is waiting to open Find in this chat.
    private static func hasFindRequest(app: AppModel, gateway: GatewayStore, chat: ChatStore) -> Bool {
        guard let request = app.findRequest else { return false }
        return request.target.gatewayId == gateway.id && gateway.resolveSessionKey(request.target.sessionKey) == chat.sessionKey
    }

    /// Opens Find on a message search result meant for this chat.
    private func takeFindRequest() {
        guard let request = self.app.findRequest,
              Self.hasFindRequest(app: self.app, gateway: self.gateway, chat: self.chat),
              self.app.takeFindRequest(for: request.target) != nil
        else { return }
        self.find.present(query: request.query, select: request.match)
    }

    @ViewBuilder private var errorBar: some View {
        if let error = self.chat.errorMessage {
            HStack(spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Retry") { Task { await self.chat.load(force: true) } }
                    .glassButton()
                    .controlSize(.small)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassSurface(in: Capsule(), tint: .orange)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var subtitle: String {
        var parts = [self.agent.name]
        if let server = self.row?.server {
            parts.append(self.gateway.displayName(for: server))
        } else if let origin = self.row?.originLabel {
            parts.append("via \(origin)")
        }
        if let model = self.row?.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var transcript: some View {
        if self.chat.entries.isEmpty, self.chat.isLoading || !self.chat.hasLoaded {
            // Until history has loaded once (cache still reading, or the Gateway reconnecting after
            // the app was suspended), an empty chat isn't known to be empty.
            VStack(spacing: 8) {
                ProgressView()
                if !self.gateway.state.isConnected {
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if self.chat.entries.isEmpty {
            ContentUnavailableView {
                Label("Say hello to \(self.agent.name)", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Messages you send here go straight to your Gateway as the owner.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TranscriptList(
                rows: TranscriptRow.rows(for: self.chat),
                context: TranscriptContext(
                    gateway: self.gateway,
                    disclosure: self.disclosure,
                    agent: self.agent,
                    sessionKey: self.chat.sessionKey,
                    previewImage: { self.previewing = $0 },
                    saveFile: { file, data in self.exporting = ExportedFile(name: file.name, data: data) }),
                bottomInset: self.bottomChrome + self.transcriptSafeArea.bottom,
                topInset: self.topChrome + self.transcriptSafeArea.top,
                highlight: self.find.highlight)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
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

    @ViewBuilder private var reasoningHint: some View {
        let level = self.row?.reasoningLevel
        if !self.hintDismissed, self.chat.hasLoaded, !self.chat.sawThinking, level != "on", level != "stream",
           self.chat.entries.contains(where: { if case .assistant = $0 { true } else { false } })
        {
            HStack(spacing: 8) {
                Image(systemName: "brain").foregroundStyle(.purple)
                Text("Thinking isn’t being saved for this session.")
                    .font(.callout)
                Button("Turn On") {
                    Task { await self.gateway.patch(self.chat.sessionKey, ["reasoningLevel": "on"]) }
                }
                .glassButton()
                .controlSize(.small)
                Text("or send `/reasoning on`").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.snappy) { self.hintDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassSurface(in: Capsule(), tint: .purple)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let row {
                ModelPicker(row: row)
                Menu {
                    Button("Find in Chat", systemImage: "magnifyingglass") { self.find.present() }
                    Divider()
                    Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin") {
                        Task { await self.gateway.patch(row.key, ["pinned": .bool(!row.isPinned)]) }
                    }
                    ThinkingDisplayPicker()
                    ReasoningMenu(row: row)
                    Divider()
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await self.chat.load(force: true) }
                    }
                    Button("Copy Session Key", systemImage: "key") { Clipboard.copy(row.key) }
                } label: {
                    Label("Session", systemImage: Theme.moreSymbol)
                }
            }
        }
    }
}

/// What the Gateway saves and streams of the agent's reasoning for this session. How much of it
/// the transcript shows is `ThinkingDisplay`; "Off" hides reasoning text there too.
struct ReasoningMenu: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Menu("Gateway Reasoning", systemImage: "brain") {
            ForEach([("on", "Save & Stream"), ("stream", "Stream Only"), ("off", "Off")], id: \.0) { value, label in
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
            VStack(spacing: 8) {
                ForEach(approvals) { approval in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .symbolEffect(.wiggle, options: .nonRepeating)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(self.gateway.agent(approval.agentId ?? "main").name) wants to run a command")
                                .font(.callout.weight(.semibold))
                            Text(approval.command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            if let cwd = approval.cwd {
                                Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let warning = approval.warning {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Button("Deny", role: .destructive) {
                                Task { await self.gateway.resolveApproval(approval, decision: "deny") }
                            }
                            .glassButton()
                            Menu("Allow") {
                                Button("Allow Once") { Task { await self.gateway.resolveApproval(approval, decision: "allow-once") } }
                                Button("Always Allow") { Task { await self.gateway.resolveApproval(approval, decision: "allow-always") } }
                            } primaryAction: {
                                Task { await self.gateway.resolveApproval(approval, decision: "allow-once") }
                            }
                            .glassProminentButton()
                            .tint(.orange)
                            .fixedSize()
                        }
                    }
                    .padding(12)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .orange.opacity(0.35))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .glassGroup()
            .padding(.horizontal, 14)
            .padding(.top, 8)
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
