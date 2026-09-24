import PincerKit
import SwiftUI

struct ChatView: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @AppStorage("pincer.reasoningHintDismissed") private var hintDismissed = false
    @State private var edges = ScrollEdges(fitsOnScreen: false, atBottom: true)
    @State private var position = ScrollPosition(edge: .bottom)
    /// Live offset/height, kept outside SwiftUI state so scrolling doesn't re-render the view.
    @State private var metrics = ScrollMetrics()

    private var row: SessionRow? { self.gateway.sessions[self.chat.sessionKey] }
    private var agent: AgentSummary { self.gateway.agent(self.row?.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "main") }

    var body: some View {
        VStack(spacing: 0) {
            ApprovalsBanner(sessionKey: self.chat.sessionKey)
            self.transcript
            if let error = self.chat.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { Task { await self.chat.load(force: true) } }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            self.reasoningHint
            Composer(chat: self.chat, placeholder: "Message #\(self.row?.title ?? "chat")")
        }
        .navigationTitle(self.row?.title ?? SessionKey.agentId(from: self.chat.sessionKey) ?? "Chat")
        #if os(macOS)
        .navigationSubtitle(self.subtitle)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { self.toolbar }
        .task(id: self.chat.sessionKey) {
            self.metrics.forgetRows()
            await self.chat.load()
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
        if self.chat.isLoading, self.chat.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if self.chat.entries.isEmpty {
            ContentUnavailableView {
                Label("Say hello to \(self.agent.name)", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Messages you send here go straight to your Gateway as the owner.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if self.chat.hasMoreHistory {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    ForEach(self.chat.entries) { entry in
                        self.row(for: entry)
                            .id(entry.id)
                            // Content-space position: changes only on layout (rows inserted or
                            // re-measured), never while scrolling, so this stays cheap.
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .named(Self.contentSpace)).minY
                            } action: { y in
                                guard let target = self.metrics.rowMoved(entry.id, to: y) else { return }
                                self.position.scrollTo(y: target + self.metrics.last.insetTop)
                            }
                            .onDisappear { self.metrics.forgetRow(entry.id) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12)
                .coordinateSpace(.named(Self.contentSpace))
            }
            .scrollPosition(self.$position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Pin to the bottom edge when content grows, so older history streaming in above (and
            // rows settling their real height while scrolling up) doesn't move what you're reading.
            // Only a live reply growing below you while you read back uses the top edge instead.
            .defaultScrollAnchor(self.pinnedToTop ? .top : .bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
                ScrollEdges(
                    fitsOnScreen: geometry.contentSize.height <= geometry.containerSize.height,
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120)
            } action: { _, edges in
                self.edges = edges
            }
            .onScrollGeometryChange(for: ScrollMetrics.Sample.self) { geometry in
                .init(offset: geometry.contentOffset.y, height: geometry.contentSize.height,
                      container: geometry.containerSize.height, insetTop: geometry.contentInsets.top)
            } action: { _, sample in
                if let target = self.metrics.restoreTarget(for: sample) {
                    self.position.scrollTo(y: target + sample.insetTop)
                }
                self.metrics.last = sample
            }
            .onChange(of: self.chat.entries.first?.id) { oldFirst, _ in
                // Older rows landed above from the background backfill. This runs before
                // layout, so `metrics.last` is still the pre-prepend geometry to restore to.
                guard let oldFirst, !self.edges.fitsOnScreen,
                      self.chat.entries.dropFirst().contains(where: { $0.id == oldFirst })
                else { return }
                self.metrics.resetAnchor()
                self.metrics.beginRestore()
            }
            .onChange(of: self.chat.entries.last) { _, _ in
                if self.edges.atBottom { self.position.scrollTo(edge: .bottom) }
            }
        }
    }

    private var pinnedToTop: Bool {
        !self.edges.atBottom && !self.chat.isLoadingOlder && self.chat.isRunning
    }

    private nonisolated static let contentSpace = "transcript"

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry {
        case let .user(item):
            // Equatable rows skip re-rendering when the transcript changes elsewhere (a new message,
            // a streaming reply, older history arriving), so only rows whose content changed redraw.
            UserMessageRow(item: item, sessionKey: self.chat.sessionKey).equatable()
        case let .assistant(turn):
            AssistantTurnRow(turn: turn, agent: self.agent, sessionKey: self.chat.sessionKey).equatable()
        case let .marker(_, label):
            MarkerRow(label: label).equatable()
        }
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
                Button("Turn on") {
                    Task { await self.gateway.patch(self.chat.sessionKey, ["reasoningLevel": "on"]) }
                }
                .buttonStyle(.borderless)
                Text("or send `/reasoning on`").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    self.hintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.purple.opacity(0.08))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let row {
                Menu {
                    Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin") {
                        Task { await self.gateway.patch(row.key, ["pinned": .bool(!row.isPinned)]) }
                    }
                    ReasoningMenu(row: row)
                    Divider()
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await self.chat.load(force: true) }
                    }
                    Button("Copy Session Key", systemImage: "key") { Clipboard.copy(row.key) }
                } label: {
                    Label("Session", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

struct ReasoningMenu: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Menu("Show Thinking", systemImage: "brain") {
            ForEach([("on", "Save & show"), ("stream", "Live only"), ("off", "Off")], id: \.0) { value, label in
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
            VStack(spacing: 0) {
                ForEach(approvals) { approval in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(self.gateway.agent(approval.agentId ?? "main").name) wants to run a command")
                                .font(.callout.weight(.semibold))
                            Text(approval.command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                            if let cwd = approval.cwd {
                                Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let warning = approval.warning {
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        HStack {
                            Button("Deny", role: .destructive) {
                                Task { await self.gateway.resolveApproval(approval, decision: "deny") }
                            }
                            Menu("Allow") {
                                Button("Allow Once") { Task { await self.gateway.resolveApproval(approval, decision: "allow-once") } }
                                Button("Always Allow") { Task { await self.gateway.resolveApproval(approval, decision: "allow-always") } }
                            } primaryAction: {
                                Task { await self.gateway.resolveApproval(approval, decision: "allow-once") }
                            }
                            .fixedSize()
                        }
                    }
                    .padding(12)
                    Divider()
                }
            }
            .background(.orange.opacity(0.1))
        }
    }
}

private final class ScrollMetrics {
    struct Sample: Equatable {
        var offset: CGFloat
        var height: CGFloat
        var container: CGFloat
        var insetTop: CGFloat
    }

    var last = Sample(offset: 0, height: 0, container: 0, insetTop: 0)
    private var distanceFromBottom: CGFloat?
    private var restoreUntil = Date.distantPast
    /// Last laid-out content-space y of each row, the row being held in place during a restore, and
    /// the (row y, content offset) pair that put it where the reader saw it.
    private var rowY: [String: CGFloat] = [:]
    private var anchorId: String?
    private var hold: (y: CGFloat, offset: CGFloat)?
    private var anchorLocked = false

    private var restoring: Bool { Date.now < self.restoreUntil }

    func forgetRows() {
        self.rowY.removeAll()
        self.resetAnchor()
    }

    /// LazyVStack unloaded the row, so its last position will go stale.
    func forgetRow(_ id: String) {
        if id != self.anchorId { self.rowY[id] = nil }
    }

    func resetAnchor() {
        self.anchorId = nil
        self.hold = nil
        self.anchorLocked = false
    }

    /// Called right after rows were prepended, before SwiftUI lays them out.
    func beginRestore() {
        self.restoreUntil = .now.addingTimeInterval(0.8)
        // Coarse: keep the distance from the bottom (lands within a row, since off-screen rows only
        // have estimated heights). Fine: pin the row at the top of the viewport once it's laid out.
        self.distanceFromBottom = self.last.height - self.last.offset
        let viewportTop = self.last.offset + self.last.insetTop
        if let (id, y) = self.rowY.min(by: { abs($0.value - viewportTop) < abs($1.value - viewportTop) }) {
            self.anchorId = id
            self.hold = (y, self.last.offset)
        }
        self.anchorLocked = false
    }

    /// A row moved in content space (rows above it were inserted or re-measured).
    func rowMoved(_ id: String, to y: CGFloat) -> CGFloat? {
        self.rowY[id] = y
        guard id == self.anchorId, self.restoring, let hold = self.hold else { return nil }
        let target = hold.offset + (y - hold.y)
        if !self.anchorLocked {
            // Positions reported while the row is still off-screen are LazyVStack estimates.
            guard abs(target - self.last.offset) < self.last.container else { return nil }
            self.anchorLocked = true
            self.distanceFromBottom = nil
        }
        return abs(target - self.last.offset) > 0.5 ? target : nil
    }

    /// While a restore is settling, returns the content offset that keeps the reader's distance from
    /// the bottom constant as heights change; plain scrolling just moves the anchor along.
    func restoreTarget(for sample: Sample) -> CGFloat? {
        if self.anchorLocked {
            // Any scroll (ours landing or the reader's) re-bases the pair; layout moves are handled
            // by `anchorMoved`.
            if !self.restoring {
                self.resetAnchor()
            } else if sample.offset != self.last.offset, let id = self.anchorId, let y = self.rowY[id] {
                self.hold = (y, sample.offset)
            }
            return nil
        }
        guard let distance = self.distanceFromBottom else { return nil }
        guard self.restoring else {
            self.distanceFromBottom = nil
            return nil
        }
        guard sample.height != self.last.height else {
            self.distanceFromBottom = sample.height - sample.offset
            return nil
        }
        let target = sample.height - distance
        return abs(sample.offset - target) > 1 ? target : nil
    }
}

private struct ScrollEdges: Equatable {
    var fitsOnScreen: Bool
    var atBottom: Bool
}
