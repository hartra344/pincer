import PincerKit
import SwiftUI
import UniformTypeIdentifiers

/// The share sheet: pick a gateway and chat (or a new chat with an agent), add a note, send.
struct ShareView: View {
    @Bindable var model: ShareModel
    let isLoadingContent: Bool
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                self.statusSection
                if case .unavailable = self.model.phase {} else {
                    self.destinationSection
                    Section("Note") {
                        TextField("Add a note (optional)", text: self.$model.note, axis: .vertical)
                            .lineLimit(2...6)
                    }
                    self.contentSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Send to Pincer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: self.onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if self.model.phase == .sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send") {
                            Task {
                                if await self.model.send() { self.onDone() }
                            }
                        }
                        .disabled(!self.model.canSend || self.isLoadingContent)
                    }
                }
            }
        }
        .onAppear { if self.model.profile != nil { self.model.connect() } }
        .onDisappear { self.model.disconnect() }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch self.model.phase {
        case let .unavailable(message):
            Section { Label(message, systemImage: "info.circle") }
        case let .connecting(reason):
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reason.map { "Connecting… (\($0))" } ?? "Connecting…").foregroundStyle(.secondary)
                }
            }
        case let .awaitingPairing(deviceId):
            Section {
                Label("This device is waiting for approval on the Gateway host. Run `openclaw devices approve` for device \(deviceId.prefix(12))…",
                      systemImage: "lock.shield")
            }
        case let .failed(message):
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        case .ready, .sending, .sent:
            if let error = self.model.sendError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }

    private var destinationSection: some View {
        Section("Send To") {
            if self.model.profiles.count > 1 {
                Picker("Gateway", selection: self.$model.profileId) {
                    ForEach(self.model.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
            }
            NavigationLink {
                ShareTargetList(model: self.model)
            } label: {
                LabeledContent("Chat") {
                    Text(self.targetTitle).lineLimit(1)
                }
            }
            .disabled(self.model.phase != .ready)
        }
    }

    private var targetTitle: String {
        switch self.model.target {
        case let .chat(key)?:
            return self.model.chats.first { $0.key == key }?.title ?? key
        case let .newChat(agentId)?:
            return "New chat with \(self.model.agents.first { $0.id == agentId }?.name ?? agentId)"
        case nil:
            return "—"
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        Section("Sharing") {
            if self.isLoadingContent {
                ProgressView()
            }
            ForEach(Array(self.model.content.texts.enumerated()), id: \.offset) { _, text in
                Label { Text(text).lineLimit(3) } icon: { Image(systemName: "text.quote") }
            }
            ForEach(self.model.content.urls, id: \.self) { url in
                Label { Text(url.absoluteString).lineLimit(2) } icon: { Image(systemName: "link") }
            }
            ForEach(self.model.attachments) { attachment in
                Label {
                    Text(attachment.fileName).lineLimit(1)
                } icon: {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                }
            }
            ForEach(self.model.content.problems + self.model.attachmentProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if !self.isLoadingContent, self.model.content.isEmpty, self.model.content.problems.isEmpty {
                Text("Nothing to share.").foregroundStyle(.secondary)
            }
        }
    }
}

/// Searchable list of chats plus "New chat with …" for each agent.
private struct ShareTargetList: View {
    @Bindable var model: ShareModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            Section("New Chat") {
                ForEach(self.agents) { agent in
                    self.row(.newChat(agentId: agent.id), title: "New chat with \(agent.name)",
                             subtitle: nil, systemImage: "square.and.pencil")
                }
            }
            Section("Chats") {
                ForEach(self.filteredChats) { chat in
                    self.row(.chat(chat.key), title: chat.title, subtitle: self.agentName(chat.agentId),
                             systemImage: chat.isPinned ? "pin" : "bubble.left")
                }
            }
        }
        .searchable(text: self.$query)
        .navigationTitle("Chat")
    }

    private var agents: [AgentSummary] {
        let agents = self.model.agents.isEmpty ? [AgentSummary(id: self.model.defaultAgentId, name: self.model.defaultAgentId.capitalized)] : self.model.agents
        guard !self.query.isEmpty else { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(self.query) }
    }

    private var filteredChats: [SessionRow] {
        guard !self.query.isEmpty else { return self.model.chats }
        return self.model.chats.filter {
            $0.title.localizedCaseInsensitiveContains(self.query) || self.agentName($0.agentId).localizedCaseInsensitiveContains(self.query)
        }
    }

    private func agentName(_ id: String) -> String {
        self.model.agents.first { $0.id == id }?.name ?? id
    }

    private func row(_ target: ShareTarget, title: String, subtitle: String?, systemImage: String) -> some View {
        Button {
            self.model.target = target
            self.dismiss()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(title).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer()
                if self.model.target == target {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Loads the host's items, then shows `ShareView`. Shared by the iOS and macOS controllers.
struct ShareRoot: View {
    let items: [NSExtensionItem]
    let onCancel: () -> Void
    let onDone: () -> Void
    @State private var model = ShareModel()
    @State private var loading = true

    var body: some View {
        ShareView(model: self.model, isLoadingContent: self.loading, onCancel: self.onCancel, onDone: self.onDone)
            .task {
                let content = await SharedContentLoader.load(self.items)
                self.model.setContent(content)
                self.loading = false
            }
    }
}
