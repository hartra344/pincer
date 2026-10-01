import ActivityKit
import PincerKit
import SwiftUI
import WidgetKit

@main
struct PincerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RunLiveActivity()
    }
}

/// The Lock Screen card and Dynamic Island for a running agent turn: what it's doing, how long it has
/// run, whether it waits for you, and how it ended. Tapping opens the chat.
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PincerRunAttributes.self) { context in
            RunLockScreenView(identity: context.attributes.identity, state: context.state)
                .padding(16)
                .widgetURL(context.attributes.identity.url)
        } dynamicIsland: { context in
            let identity = context.attributes.identity
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RunSymbol(phase: state.phase).font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunTimer(state: state).font(.title3).frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(identity.displayName).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(state.status).font(.subheadline).lineLimit(1)
                }
            } compactLeading: {
                RunSymbol(phase: state.phase)
            } compactTrailing: {
                RunTimer(state: state).frame(maxWidth: 52)
            } minimal: {
                RunSymbol(phase: state.phase)
            }
            .widgetURL(identity.url)
        }
    }
}

private struct RunLockScreenView: View {
    let identity: RunActivityIdentity
    let state: RunActivityState

    var body: some View {
        HStack(spacing: 12) {
            RunSymbol(phase: self.state.phase).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.identity.displayName).font(.headline).lineLimit(1)
                if self.identity.chatTitle != self.identity.agentName {
                    Text(self.identity.chatTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(self.state.status).font(.subheadline).lineLimit(1)
            }
            Spacer(minLength: 8)
            RunTimer(state: self.state).font(.title3)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A symbol for the turn's phase.
private struct RunSymbol: View {
    let phase: RunActivityState.Phase

    var body: some View {
        Image(systemName: self.symbol).foregroundStyle(self.tint)
    }

    private var symbol: String {
        switch self.phase {
        case .thinking: "ellipsis.bubble"
        case .replying: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .compacting: "arrow.triangle.2.circlepath"
        case .awaitingApproval: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    private var tint: Color {
        switch self.phase {
        case .awaitingApproval: .orange
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
        case .thinking, .replying, .tool, .compacting: .accentColor
        }
    }
}

/// How long the turn has run: counts up on its own while it runs, and stops where it ended.
private struct RunTimer: View {
    let state: RunActivityState

    var body: some View {
        if let end = self.state.endedAt {
            Text(timerInterval: self.state.startedAt ... max(end, self.state.startedAt), pauseTime: end, countsDown: false)
                .monospacedDigit()
        } else {
            Text(timerInterval: self.state.startedAt ... .distantFuture, countsDown: false)
                .monospacedDigit()
        }
    }
}

private extension RunActivityIdentity {
    /// The agent's name, with its emoji when it has one.
    var displayName: String {
        self.emoji.map { "\($0) \(self.agentName)" } ?? self.agentName
    }
}
