import PincerKit
import SwiftUI

/// Status symbol plus its text, so status never rides on color alone.
struct RunStatusLabel: View {
    let status: SubagentStatus
    var showsText = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                switch self.status {
                case .running:
                    ProgressView().controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .error:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .aborted:
                    Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
                case .unknown:
                    Image(systemName: "questionmark.circle").foregroundStyle(.gray)
                case .idle:
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            if self.showsText {
                Text(self.status.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.status.label)
    }
}

extension SubagentStatus {
    init(_ lane: RunLaneStatus) {
        switch lane {
        case .running: self = .running
        case .done: self = .done
        case .error: self = .error
        case .aborted: self = .aborted
        }
    }
}

@MainActor
enum RunsFormat {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relative(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 5 ? L("just now") : self.relative.localizedString(for: date, relativeTo: now)
    }
}

/// The helper sessions the chat spawned, nested, with live status. Opening one selects it,
/// the same as a transcript's "Open run" button.
struct SubagentTreeView: View {
    let rootKey: String
    let tree: SubagentTree
    let showTimeline: (SubagentNode) -> Void

    @Environment(GatewayStore.self) private var gateway
    @State private var collapsed: Set<String> = []
    @State private var selection: String?

    var body: some View {
        let visible = Self.visibleNodes(self.tree.children, collapsed: self.collapsed)
        let timeline = self.gateway.runTimeline
        VStack(alignment: .leading, spacing: 0) {
            if let parent = self.gateway.parentSessionKey(of: self.rootKey) {
                Button {
                    self.open(parent)
                } label: {
                    Label(L("Parent: \(self.gateway.runTitle(parent))"),
                          systemImage: "arrow.up")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if self.tree.isEmpty {
                ContentUnavailableView(L("No helper runs yet"), systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("When this agent delegates work, its helpers appear here.", bundle: .module))
                    .frame(maxHeight: .infinity)
            } else {
                TimelineView(.animation(minimumInterval: self.tree.runningCount > 0 ? 1 : 30)) { context in
                    List(selection: self.$selection) {
                        ForEach(visible) { node in
                            SubagentRowView(
                                node: node,
                                title: self.gateway.runTitle(node.key),
                                agentName: self.gateway.agent(node.agentId).name,
                                caption: node.status == .running ? timeline.latestLane(sessionKey: node.key)?.currentActivity : nil,
                                lastEvent: timeline.lastEventAt(sessionKey: node.key),
                                now: context.date,
                                isCollapsed: self.collapsed.contains(node.key),
                                toggle: { self.toggle(node.key) })
                                .tag(node.key)
                        }
                    }
                    .listStyle(.plain)
                }
                .contextMenu(forSelectionType: String.self) { keys in
                    if let key = keys.first, let node = self.tree.node(key) {
                        Button(L("Open"), systemImage: "arrow.up.forward.app") { self.open(key) }
                        Button(L("Show Timeline"), systemImage: "chart.bar.xaxis") { self.showTimeline(node) }
                        Button(L("Copy Session Key"), systemImage: "key") { Clipboard.copy(key) }
                    }
                } primaryAction: { keys in
                    if let key = keys.first { self.open(key) }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if self.collapsed.contains(key) { self.collapsed.remove(key) } else { self.collapsed.insert(key) }
    }

    /// Same path as the transcript's "Open run": selecting a hidden helper doesn't change
    /// whether helpers show in the sidebar.
    private func open(_ key: String) {
        self.gateway.selectedKey = key
    }

    static func visibleNodes(_ nodes: [SubagentNode], collapsed: Set<String>) -> [SubagentNode] {
        var out: [SubagentNode] = []
        func walk(_ nodes: [SubagentNode]) {
            for node in nodes {
                out.append(node)
                if !collapsed.contains(node.key) { walk(node.children) }
            }
        }
        walk(nodes)
        return out
    }
}

private struct SubagentRowView: View {
    let node: SubagentNode
    let title: String
    let agentName: String
    let caption: String?
    let lastEvent: Date?
    let now: Date
    let isCollapsed: Bool
    let toggle: () -> Void

    private var lastActive: Date? {
        [self.lastEvent, self.node.lastActivity].compactMap { $0 }.max()
    }

    var body: some View {
        let duration = self.node.duration(now: self.now).map(RunDuration.format)
        let lastActive = self.lastActive.map { RunsFormat.relative($0, now: self.now) }
        HStack(alignment: .top, spacing: 6) {
            Group {
                if self.node.children.isEmpty {
                    Color.clear
                } else {
                    Button(action: self.toggle) {
                        Image(systemName: self.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(self.isCollapsed ? L("Expand") : L("Collapse"))
                }
            }
            .frame(width: 12, height: 16)
            RunStatusLabel(status: self.node.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(self.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if let duration { Text(duration).monospacedDigit().foregroundStyle(.secondary) }
                }
                Text([self.agentName, self.node.status.label, lastActive.map { L("active \($0)") }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let caption {
                    Text(LocalizedStringKey(caption)).font(.caption).foregroundStyle(.tint).lineLimit(1)
                } else if self.node.status == .error, let error = self.node.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .padding(.leading, CGFloat(self.node.depth - 1) * 14)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([self.title, self.agentName, self.node.status.label, duration,
                             lastActive.map { L("last active \($0)") }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityActions {
            if !self.node.children.isEmpty {
                Button(self.isCollapsed ? L("Expand") : L("Collapse"), action: self.toggle)
            }
        }
    }
}
