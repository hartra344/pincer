import PincerKit
import SwiftUI

/// One lane per run of the chat and its helpers, on a shared time axis.
struct RunTimelineView: View {
    let rootKey: String
    let tree: SubagentTree
    /// Session whose latest run is highlighted and scrolled to.
    let focusedSession: String

    @Environment(GatewayStore.self) private var gateway
    @State private var selectedSpan: SpanSelection?

    struct SpanSelection: Hashable {
        let runId: String
        let spanId: Int
    }

    enum Entry: Identifiable {
        case lane(RunLane, title: String)
        case placeholder(SubagentNode, title: String)

        var id: String {
            switch self {
            case let .lane(lane, _): "run-\(lane.runId)"
            case let .placeholder(node, _): "node-\(node.key)"
            }
        }
    }

    var body: some View {
        let timeline = self.gateway.runTimeline
        let entries = self.entries(timeline)
        // Disconnected, a running lane's outcome is unknown: it stops at its last event.
        let connected = self.gateway.state.isConnected
        let live = connected && entries.contains { if case let .lane(lane, _) = $0 { lane.isRunning } else { false } }
        let focusId = timeline.latestLane(sessionKey: self.focusedSession).map { "run-\($0.runId)" }
            ?? "node-\(self.focusedSession)"
        if entries.isEmpty {
            ContentUnavailableView(L("No runs captured yet"), systemImage: "chart.bar.xaxis",
                                   description: Text("Runs appear here as they stream. Only live runs are recorded.", bundle: .module))
                .frame(maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: live ? 1 : 30, paused: !live && !connected)) { context in
                let now = context.date
                let axis = Self.axis(entries, now: now, connected: connected)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(entries) { entry in
                                self.row(entry, axis: axis, now: now, connected: connected,
                                         isFocused: entry.id == focusId)
                                    .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear { proxy.scrollTo(focusId, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry, axis: ClosedRange<Date>, now: Date, connected: Bool, isFocused: Bool) -> some View {
        switch entry {
        case let .lane(lane, title):
            RunLaneView(lane: lane, title: title, axis: axis, now: connected || !lane.isRunning ? now : lane.lastEventAt,
                        isConnected: connected, isFocused: isFocused, selection: self.$selectedSpan,
                        open: lane.sessionKey.map { key in { self.gateway.selectedKey = key } })
        case let .placeholder(node, title):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    RunStatusLabel(status: node.status)
                    Text(title).lineLimit(1)
                    Spacer()
                    if let duration = node.duration(now: now) {
                        Text(RunDuration.format(duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("Activity not captured — only live runs are recorded", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .modifier(OpenRunGestures(open: { self.gateway.selectedKey = node.key }))
        }
    }

    private func title(for key: String) -> String { self.gateway.runTitle(key) }

    private func entries(_ timeline: RunTimeline) -> [Entry] {
        var entries: [Entry] = timeline.lanes(sessionKey: self.rootKey).reversed()
            .map { .lane($0, title: self.title(for: self.rootKey)) }
        for node in self.tree.flattened {
            let lanes = timeline.lanes(sessionKey: node.key)
            let title = self.title(for: node.key)
            if lanes.isEmpty {
                entries.append(.placeholder(node, title: title))
            } else {
                entries += lanes.reversed().map { .lane($0, title: title) }
            }
        }
        return entries
    }

    private static func axis(_ entries: [Entry], now: Date, connected: Bool) -> ClosedRange<Date> {
        var start: Date?
        var end: Date?
        for entry in entries {
            guard case let .lane(lane, _) = entry else { continue }
            start = min(start ?? lane.startedAt, lane.startedAt)
            let laneEnd = lane.isRunning && connected ? now : (lane.endedAt ?? lane.lastEventAt)
            end = max(end ?? laneEnd, laneEnd)
        }
        guard let start, let end else { return now...now.addingTimeInterval(1) }
        return start...max(end, start.addingTimeInterval(1))
    }
}

private struct RunLaneView: View {
    let lane: RunLane
    let title: String
    let axis: ClosedRange<Date>
    let now: Date
    let isConnected: Bool
    let isFocused: Bool
    @Binding var selection: RunTimelineView.SpanSelection?
    /// Opens the run's session; nil when the run's session isn't known.
    let open: (() -> Void)?

    private var isLive: Bool { self.lane.isRunning && self.isConnected }

    var body: some View {
        let status = self.lane.isRunning && !self.isConnected ? .unknown : SubagentStatus(self.lane.status)
        let duration = RunDuration.format(self.lane.duration(now: self.now))
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RunStatusLabel(status: status)
                Text(self.title).lineLimit(1).fontWeight(self.isFocused ? .semibold : .regular)
                Spacer(minLength: 4)
                Text(duration).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(self.title), \(status.label), \(duration)")
            .modifier(OpenRunGestures(open: self.open))
            GeometryReader { geometry in
                let spans = self.lane.spans(axisStart: self.axis.lowerBound, axisEnd: self.axis.upperBound,
                                            width: geometry.size.width, now: self.now)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.5))
                    ForEach(spans) { span in
                        self.spanView(span, height: geometry.size.height)
                    }
                    if self.isLive {
                        let x = min(geometry.size.width,
                                    self.now.timeIntervalSince(self.axis.lowerBound)
                                        / self.axis.upperBound.timeIntervalSince(self.axis.lowerBound) * geometry.size.width)
                        Rectangle().fill(.tint).frame(width: 1.5, height: geometry.size.height + 4)
                            .offset(x: x - 0.75, y: -2)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 16)
            .padding(.vertical, 2)
            .background(self.isFocused ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
            if self.isConnected, let caption = self.lane.currentActivity {
                Text(LocalizedStringKey(caption)).font(.caption).foregroundStyle(.tint)
            }
            if let detail = self.selectedDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if self.lane.droppedSegments > 0 {
                Text("\(self.lane.droppedSegments) earlier steps not shown", bundle: .module).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var selectedDetail: String? {
        guard let selection, selection.runId == self.lane.runId,
              let segment = self.lane.segments.first(where: { $0.id == selection.spanId }) else { return nil }
        return Self.describe(kind: segment.kind, start: segment.start, end: segment.end ?? self.now,
                             laneStart: self.lane.startedAt, detail: segment.detail, merged: 1)
    }

    @ViewBuilder
    private func spanView(_ span: RunSpan, height: CGFloat) -> some View {
        let description = Self.describe(kind: span.kind, start: span.start, end: span.end,
                                        laneStart: self.lane.startedAt, detail: span.detail, merged: span.mergedCount)
        Group {
            switch span.kind {
            case .error:
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.red)
                    .frame(width: 10, height: height)
                    .offset(x: span.x - 5)
            case .abort:
                Image(systemName: "square.fill").font(.system(size: 8)).foregroundStyle(.gray)
                    .frame(width: 10, height: height)
                    .offset(x: span.x - 5)
            default:
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.color(span))
                    .frame(width: span.width, height: height)
                    .offset(x: span.x)
            }
        }
        .contentShape(Rectangle())
        .help(description)
        .onTapGesture { self.selection = .init(runId: self.lane.runId, spanId: span.id) }
        .accessibilityElement()
        .accessibilityLabel(description)
        .accessibilityAddTraits(.isButton)
    }

    private static func color(_ span: RunSpan) -> Color {
        switch span.kind {
        case .thinking: .purple.opacity(0.35)
        case .tool: span.isError ? .red : .blue
        case .writing: .gray.opacity(0.5)
        case .compaction: .orange.opacity(0.5)
        case .error: .red
        case .abort: .gray
        }
    }

    static func describe(kind: RunSegmentKind, start: Date, end: Date, laneStart: Date, detail: String?,
                         merged: Int) -> String
    {
        let name = switch kind {
        case .thinking: L("Thinking")
        case .writing: L("Writing")
        case let .tool(name): name
        case .compaction: L("Compaction")
        case .error: L("Error")
        case .abort: L("Stopped")
        }
        var parts = [merged > 1 ? L("\(name) + \(merged - 1) more") : name,
                     L("at +\(RunDuration.format(start.timeIntervalSince(laneStart)))")]
        if !kind.isMarker { parts.append(RunDuration.format(end.timeIntervalSince(start))) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// Open on a lane header: double-click on macOS, tap on iOS, and an "Open" context item.
private struct OpenRunGestures: ViewModifier {
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content
                .contentShape(Rectangle())
                #if os(macOS)
                .onTapGesture(count: 2, perform: open)
                #else
                .onTapGesture(perform: open)
                #endif
                .contextMenu {
                    Button(L("Open"), systemImage: "arrow.up.forward.app", action: open)
                }
                .accessibilityAction(named: L("Open"), open)
        } else {
            content
        }
    }
}
