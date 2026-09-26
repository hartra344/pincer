import PincerKit
import SwiftUI

/// A ring in the composer showing how full the session's context window is. It turns orange, then
/// red, as the window fills, and opens a popover with the numbers and a "Compact Now" action.
struct ContextMeter: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @State private var showing = false

    var body: some View {
        let usage = self.gateway.contextUsage(for: self.chat.sessionKey)
        if let usage {
            Button { self.showing.toggle() } label: {
                ContextRing(usage: usage, compacting: self.chat.compaction?.isRunning == true)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: Composer.controlHeight)
            .help("Context: \(usage.summary) tokens (\(usage.percentLabel))")
            .accessibilityLabel("Context window")
            .accessibilityValue("\(usage.percentLabel) full, \(usage.summary) tokens")
            .popover(isPresented: self.$showing, arrowEdge: .top) {
                ContextMeterPopover(chat: self.chat)
                    .presentationCompactAdaptation(.popover)
            }
            .onChange(of: self.showing) { _, showing in
                if !showing { self.chat.clearCompaction() }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

extension ContextUsage.Level {
    var tint: Color {
        switch self {
        case .normal: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct ContextRing: View {
    let usage: ContextUsage
    let compacting: Bool

    var body: some View {
        let tint = self.usage.level.tint
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, Double(self.usage.percent) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if self.compacting {
                ProgressView().controlSize(.mini)
            } else if self.usage.level != .normal {
                Text("\(self.usage.percent)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 20, height: 20)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .animation(.snappy, value: self.usage.percent)
    }
}

/// A linear bar (macOS's `ProgressView` ignores the tint) coloured by how full the window is.
private struct ContextBar: View {
    let usage: ContextUsage

    var body: some View {
        let tint = self.usage.level == .normal ? Color.accentColor : self.usage.level.tint
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(proxy.size.height, proxy.size.width * min(self.usage.ratio, 1)))
                }
            }
            .frame(height: 6)
            .animation(.snappy, value: self.usage.percent)
            .accessibilityHidden(true)
    }
}

struct ContextMeterPopover: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway
    @State private var instructions = ""

    var body: some View {
        let row = self.gateway.sessions[self.chat.sessionKey]
        let usage = self.gateway.contextUsage(for: self.chat.sessionKey)
        VStack(alignment: .leading, spacing: 12) {
            if let usage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(usage.isPromptBudget ? "Prompt Budget" : "Context Window").font(.headline)
                        Spacer(minLength: 12)
                        Text("\(usage.summary) · \(usage.percentLabel)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(usage.level == .normal ? .secondary : usage.level.tint)
                    }
                    ContextBar(usage: usage)
                    if usage.level != .normal {
                        Label(usage.level == .critical
                              ? "Almost full. The agent will compact on its own soon; compact now to choose what it keeps."
                              : "Filling up. Compacting summarizes older messages to free room.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(usage.level.tint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if usage.isApproximate {
                        Text("Estimated from before the last run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let row, row.inputTokens != nil || row.outputTokens != nil {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow {
                        Text("Last run").foregroundStyle(.secondary)
                        Text("In \(row.inputTokens.map(TokenCount.format) ?? "–")")
                        Text("Out \(row.outputTokens.map(TokenCount.format) ?? "–")")
                    }
                }
                .font(.caption.monospacedDigit())
            }
            Divider()
            self.compactSection
        }
        .padding(14)
        .frame(width: 320)
        // `/compact` finishes after the run ends, so clear the instructions once the result lands.
        .onChange(of: self.chat.compaction) { _, state in
            if case .finished = state { self.instructions = "" }
        }
    }

    @ViewBuilder private var compactSection: some View {
        let state = self.chat.compaction
        let running = state?.isRunning == true
        VStack(alignment: .leading, spacing: 8) {
            TextField("Instructions (optional)", text: self.$instructions, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(running)
                .onSubmit(self.compact)
            HStack(spacing: 8) {
                Button(action: self.compact) {
                    Label("Compact Now", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .glassProminentButton()
                .disabled(!self.canCompact)
                if let state {
                    if running { ProgressView().controlSize(.small) }
                    Text(state.message)
                        .font(.callout)
                        .foregroundStyle(Self.color(for: state))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if self.chat.isRunning, !running {
                Text("Wait for the current run to finish.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canCompact: Bool {
        self.gateway.state.isConnected && !self.chat.isRunning && self.chat.compaction?.isRunning != true
    }

    private func compact() {
        guard self.canCompact else { return }
        let instructions = self.instructions
        Task { await self.chat.compact(instructions: instructions) }
    }

    private static func color(for state: CompactionState) -> Color {
        switch state {
        case .running, .skipped: .secondary
        case .finished: .green
        case .failed: .red
        }
    }
}
