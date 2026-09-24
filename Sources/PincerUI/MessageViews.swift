import PincerKit
import SwiftUI

struct UserMessageRow: View, Equatable {
    let item: ChatItem
    let sessionKey: String

    var body: some View {
        MessageScaffold(
            avatar: Avatar(text: Owner.initials, color: .blue),
            name: Owner.displayName,
            badge: self.item.via.map { "via \($0)" },
            timestamp: self.item.timestamp,
            isPending: self.item.isPending)
        {
            VStack(alignment: .leading, spacing: 8) {
                let text = self.item.plainText
                if !text.isEmpty { MarkdownText(source: text) }
                let images = self.item.blocks.compactMap { block -> ImageRef? in
                    if case let .image(ref) = block { return ref }
                    return nil
                }
                if !images.isEmpty { ImageGrid(images: images, sessionKey: self.sessionKey) }
                ForEach(self.fileNames, id: \.self) { FileChip(name: $0) }
            }
        }
        .contextMenu {
            Button("Copy Text") { Clipboard.copy(self.item.plainText) }
        }
    }

    private var fileNames: [String] {
        self.item.blocks.compactMap { block in
            if case let .file(name, _) = block { return name }
            return nil
        }
    }
}

struct AssistantTurnRow: View, Equatable {
    let turn: AssistantTurn
    let agent: AgentSummary
    let sessionKey: String
    @AppStorage("pincer.expandThinking") private var expandThinking = false
    @AppStorage("pincer.showTools") private var showTools = true

    // Settings changes still redraw through their own storage observation.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.agent == rhs.agent && lhs.sessionKey == rhs.sessionKey
    }

    var body: some View {
        MessageScaffold(
            avatar: Avatar(text: String(self.agent.name.prefix(1)).uppercased(), emoji: self.agent.emoji, color: Theme.accent),
            name: self.agent.name,
            badge: nil,
            timestamp: self.turn.timestamp,
            isPending: false)
        {
            VStack(alignment: .leading, spacing: 8) {
                if !self.turn.thinking.isEmpty {
                    ThinkingView(text: self.turn.thinking.joined(separator: "\n\n"),
                                 isStreaming: self.turn.isStreaming && self.turn.text.isEmpty,
                                 startExpanded: self.expandThinking)
                }
                if self.showTools, !self.turn.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(self.turn.tools) { ToolCard(tool: $0) }
                    }
                }
                if !self.turn.text.isEmpty {
                    MarkdownText(source: self.turn.body)
                        .foregroundStyle(self.turn.isError ? .red : .primary)
                }
                if !self.turn.images.isEmpty {
                    ImageGrid(images: self.turn.images, sessionKey: self.sessionKey)
                }
                ForEach(self.turn.files, id: \.self) { FileChip(name: $0) }
                if self.turn.isStreaming, self.turn.text.isEmpty, self.turn.thinking.isEmpty, self.turn.tools.allSatisfy({ !$0.isRunning }) {
                    TypingIndicator()
                }
            }
        }
        .contextMenu {
            Button("Copy Reply") { Clipboard.copy(self.turn.body) }
            if !self.turn.thinking.isEmpty {
                Button("Copy Thinking") { Clipboard.copy(self.turn.thinking.joined(separator: "\n\n")) }
            }
        }
    }
}

struct MessageScaffold<Avatar: View, Content: View>: View {
    let avatar: Avatar
    let name: String
    let badge: String?
    let timestamp: Date?
    let isPending: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            self.avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.name).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let timestamp {
                        Text(timestamp.chatTimestamp).font(.caption).foregroundStyle(.tertiary)
                    }
                    if self.isPending {
                        ProgressView().controlSize(.mini)
                    }
                }
                self.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .opacity(self.isPending ? 0.7 : 1)
    }
}

struct ThinkingView: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded: Bool

    init(text: String, isStreaming: Bool, startExpanded: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        self._expanded = State(initialValue: startExpanded || isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { self.expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                    Text(self.isStreaming ? "Thinking…" : "Thinking")
                        .font(.callout.weight(.medium))
                    if self.isStreaming {
                        ProgressView().controlSize(.mini)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(self.expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.expanded ? "Hide thinking" : "Show thinking")

            if self.expanded {
                Text(self.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

struct ToolCard: View {
    let tool: ToolActivity
    @State private var expanded = false
    @Environment(GatewayStore.self) private var gateway

    /// Subagent run this tool call started, so the run can be opened from where it happened.
    private var spawnedRun: SessionRow? {
        if let key = self.tool.spawnedSessionKey, let row = self.gateway.sessions[key] { return row }
        guard let label = self.tool.spawnLabel else { return nil }
        return self.gateway.sessions.values.first { $0.isSubagent && $0.raw["label"]?.text == label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) { self.expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        self.statusIcon
                        Text(self.tool.name).font(.callout.monospaced().weight(.medium))
                        if let summary = self.summary {
                            Text(summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(self.expanded ? 90 : 0))
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, self.spawnedRun == nil ? 10 : 6)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let run = self.spawnedRun {
                    Button {
                        self.gateway.selectedKey = run.key
                    } label: {
                        Label("Open run", systemImage: "sparkles").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open “\(run.title)” to see what this helper did")
                    .padding(.trailing, 10)
                }
            }

            if self.expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let arguments = self.tool.arguments, !arguments.isEmpty {
                        self.section("Input", arguments)
                    }
                    if let result = self.tool.result, !result.isEmpty {
                        self.section(self.tool.isError ? "Error" : "Output", result)
                    } else if self.tool.isRunning {
                        Text("Running…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(self.tool.isError ? AnyShapeStyle(.red.opacity(0.5)) : AnyShapeStyle(.quaternary)))
        .frame(maxWidth: 640, alignment: .leading)
    }

    @ViewBuilder private var statusIcon: some View {
        if self.tool.isRunning {
            ProgressView().controlSize(.small)
        } else if self.tool.isError {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: Self.symbol(for: self.tool.name)).foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(body.count > 20000 ? String(body.prefix(20000)) + "\n…" : body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
    }

    private var summary: String? { self.tool.summary }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("exec") || lower.contains("bash") || lower.contains("shell") || lower.contains("process") { return "terminal" }
        if lower.contains("read") || lower.contains("view") { return "doc.text" }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") { return "pencil" }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") || lower.contains("browser") { return "globe" }
        if lower.contains("image") || lower.contains("canvas") { return "photo" }
        if lower.contains("session") || lower.contains("spawn") || lower.contains("agent") { return "person.2" }
        if lower.contains("memory") { return "brain.head.profile" }
        if lower.contains("message") || lower.contains("send") { return "paperplane" }
        return "wrench.and.screwdriver"
    }
}

struct FileChip: View {
    let name: String

    var body: some View {
        Label(self.name, systemImage: "paperclip")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * max(0, sin(self.phase - Double(index) * 0.8)))
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { self.phase = .pi * 2 }
        }
        .accessibilityLabel("Working")
    }
}

struct MarkerRow: View, Equatable {
    let label: String

    var body: some View {
        HStack {
            VStack { Divider() }
            Label(self.label, systemImage: self.label.hasPrefix("Context") || self.label.hasPrefix("Compacting") ? "archivebox" : "sparkle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(self.label.hasPrefix("Context") ? "Earlier messages were summarized for the agent. They're still shown here." : "")
            VStack { Divider() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
