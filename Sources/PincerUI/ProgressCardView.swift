import PincerKit
import SwiftUI

/// The agent's task checklist (`progress_card`), floating above the composer like the Control UI's
/// "Task progress" card. Collapses to the current step; expands to the note and every step.
struct ProgressCardView: View {
    let chat: ChatStore
    let card: ProgressCard
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    @State private var isDismissing = false
    @State private var detailsHeight: CGFloat = 0

    private static let corner: CGFloat = 18
    private static let maxDetailsHeight: CGFloat = 260

    /// An in-progress step only spins while a run can still advance it.
    private var isRunning: Bool { self.chat.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            if self.isExpanded {
                Divider().padding(.horizontal, 12)
                self.scrollingDetails
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(self.reduceMotion ? nil : .snappy) { self.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    self.summaryMarker
                    Text(self.isExpanded ? "Task progress" : self.summaryText)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if !self.card.steps.isEmpty {
                        Text(self.isExpanded
                            ? "\(self.card.completedCount) of \(self.card.steps.count) done"
                            : "\(self.card.currentPosition)/\(self.card.steps.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(self.isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.accessibilitySummary)
            .accessibilityHint(self.isExpanded ? "Collapse task progress" : "Expand task progress")
            if self.card.isComplete {
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(self.isDismissing)
                .help("Dismiss progress card")
                .accessibilityLabel("Dismiss progress card")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let markdown = self.card.markdown {
                Text(Self.attributed(markdown))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !self.card.steps.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(self.card.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            self.marker(for: step.status)
                                .frame(width: 16)
                            Text(step.text)
                                .font(.callout)
                                .foregroundStyle(step.status == .pending ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(step.text), \(self.statusLabel(step.status))")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.detailsHeight = $0 }
    }

    /// Long plans scroll inside the card instead of pushing the transcript away.
    private var scrollingDetails: some View {
        ScrollView {
            self.details
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(self.detailsHeight, 1), Self.maxDetailsHeight))
    }

    private var summaryText: String {
        self.card.currentStep?.text ?? self.card.markdownSummary ?? "Task progress"
    }

    @ViewBuilder private var summaryMarker: some View {
        if self.card.isComplete {
            self.marker(for: .completed)
        } else if let status = self.card.currentStep?.status {
            self.marker(for: status)
        } else {
            Image(systemName: "list.bullet.clipboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func marker(for status: ProgressCard.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(self.theme.accent)
        case .inProgress where self.isRunning:
            ProgressView()
                .controlSize(.mini)
                .tint(self.theme.accent)
        case .inProgress:
            Image(systemName: "pause.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .pending:
            Image(systemName: "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func statusLabel(_ status: ProgressCard.Status) -> String {
        switch status {
        case .completed: "completed"
        case .inProgress: self.isRunning ? "in progress" : "paused"
        case .pending: "pending"
        }
    }

    private var accessibilitySummary: String {
        guard let step = self.card.currentStep else { return "Task progress, \(self.summaryText)" }
        return "Task progress, \(self.card.completedCount) of \(self.card.steps.count) done, "
            + "\(self.statusLabel(step.status)): \(step.text)"
    }

    private func dismiss() {
        self.isDismissing = true
        Task {
            await self.chat.dismissProgressCard()
            self.isDismissing = false
        }
    }

    private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(markdown)
    }
}
