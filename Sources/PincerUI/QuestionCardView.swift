import PincerKit
import SwiftUI

/// An agent's `ask_user` prompt, floating above the composer like the Control UI's question card.
/// Shows one question at a time; Submit sends every answer together with `question.resolve`.
struct QuestionCardView: View {
    let prompt: QuestionPrompt
    /// Other prompts waiting behind this one in the same chat.
    let queued: Int
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = QuestionDraft()
    @State private var page = 0
    @State private var isExpanded = true
    @State private var isSending = false
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case card, freeText }
    private static let corner: CGFloat = 18
    private static let maxBodyHeight: CGFloat = 360

    private var question: AgentQuestion { self.prompt.questions[min(self.page, self.prompt.questions.count - 1)] }
    private var isLastPage: Bool { self.page >= self.prompt.questions.count - 1 }
    private var answers: [String: [String]]? { self.draft.answers(for: self.prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            if self.isExpanded {
                ScrollView {
                    self.questionBody
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.maxBodyHeight)
                .fixedSize(horizontal: false, vertical: true)
                self.footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .focusable()
        .focusEffectDisabled()
        .focused(self.$focus, equals: .card)
        // Number keys only work once the user has clicked into the card, so a card that appears
        // while they're typing in the composer never takes their keystrokes.
        .onKeyPress(phases: .down) { press in self.handleKey(press) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from the agent")
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(self.reduceMotion ? nil : .snappy) { self.isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.callout)
                    .foregroundStyle(self.theme.accent)
                Text(self.isExpanded ? self.headerTitle : self.question.question)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if self.queued > 0 {
                    Text("+\(self.queued) more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("\(self.page + 1)/\(self.prompt.questions.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(self.isExpanded ? 0 : 180))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, self.isExpanded ? 4 : 14)
        .accessibilityHint(self.isExpanded ? "Collapse question" : "Expand question")
    }

    private var headerTitle: String {
        let header = self.question.header.trimmingCharacters(in: .whitespaces)
        return header.isEmpty ? "Question" : header
    }

    // MARK: Body

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.question.question)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 4)
            if let url = self.question.url {
                Link(destination: url) {
                    Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
            if let store = self.question.secretStoreName {
                Label("Saved to the Gateway's secret store as \(store)", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(self.question.options.enumerated()), id: \.offset) { index, option in
                self.optionRow(option, number: index + 1)
            }
            if self.question.allowsFreeText {
                self.freeTextRow(number: self.question.options.count + 1)
            }
            if let errorText = self.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func optionRow(_ option: AgentQuestion.Option, number: Int) -> some View {
        let selected = self.draft.isSelected(option.label, in: self.question)
        return Button {
            self.draft.toggle(option.label, in: self.question)
            self.errorText = nil
            self.focus = .card
        } label: {
            HStack(spacing: 12) {
                self.marker(selected: selected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = option.description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                self.numberHint(number)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.rowBackground(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(self.isSending)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(option.description ?? "")
    }

    private func freeTextRow(number: Int) -> some View {
        let text = Binding(
            get: { self.draft.text(for: self.question) },
            set: { self.draft.setText($0, for: self.question); self.errorText = nil })
        let hasText = !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 12) {
            Image(systemName: hasText ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundStyle(hasText ? self.theme.accent : .secondary)
            Group {
                if self.question.isSecret {
                    SecureField("Type your answer", text: text)
                } else {
                    TextField(self.question.options.isEmpty ? "Type your answer" : "Type your own answer here",
                              text: text, axis: .vertical)
                        .lineLimit(1...5)
                }
            }
            .textFieldStyle(.plain)
            .font(.body)
            .focused(self.$focus, equals: .freeText)
            .onSubmit { self.submitOrAdvance() }
            .disabled(self.isSending)
            Spacer(minLength: 8)
            self.numberHint(number)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(self.rowBackground(selected: hasText))
        .contentShape(Rectangle())
        .onTapGesture { self.focus = .freeText }
    }

    private func marker(selected: Bool) -> some View {
        let symbol = self.question.multiSelect
            ? (selected ? "checkmark.square.fill" : "square")
            : (selected ? "largecircle.fill.circle" : "circle")
        return Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(selected ? self.theme.accent : .secondary)
    }

    private func numberHint(_ number: Int) -> some View {
        Text("\(number)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? self.theme.accent.opacity(0.14) : Color.primary.opacity(0.05))
            .strokeBorder(selected ? self.theme.accent.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let expiresAt = self.prompt.expiresAt {
                Text(expiresAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Time left to answer")
            }
            Spacer()
            Button("Skip") { self.skip() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(self.isSending)
                .help("Tell the agent you'd rather not answer")
            if self.page > 0 {
                Button("Back") { self.page -= 1 }
                    .glassButton()
                    .disabled(self.isSending)
            }
            Button {
                self.submitOrAdvance()
            } label: {
                if self.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(self.isLastPage ? "Submit" : "Next")
                }
            }
            .glassProminentButton()
            .tint(self.theme.accent)
            .disabled(self.isSending || (self.isLastPage ? self.answers == nil : self.draft.values(for: self.question) == nil))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    // MARK: Actions

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard self.focus == .card, self.isExpanded, !self.isSending, press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .ignored
        }
        if press.key == .return {
            self.submitOrAdvance()
            return .handled
        }
        guard let number = Int(press.characters), number >= 1 else { return .ignored }
        if self.draft.toggle(number: number, in: self.question) {
            self.errorText = nil
            return .handled
        }
        if self.question.allowsFreeText, number == self.question.options.count + 1 {
            self.focus = .freeText
            return .handled
        }
        return .ignored
    }

    private func submitOrAdvance() {
        guard !self.isSending else { return }
        if !self.isLastPage {
            guard self.draft.values(for: self.question) != nil else { return }
            self.page += 1
            self.focus = .card
            return
        }
        guard let answers = self.answers else {
            // Jump to the first question still missing an answer.
            if let missing = self.prompt.questions.firstIndex(where: { self.draft.values(for: $0) == nil }) {
                self.page = missing
            }
            return
        }
        self.isSending = true
        self.errorText = nil
        Task {
            let error = await self.gateway.answerQuestion(self.prompt, answers: answers)
            self.isSending = false
            self.errorText = error
        }
    }

    private func skip() {
        self.isSending = true
        self.errorText = nil
        Task {
            let error = await self.gateway.skipQuestion(self.prompt)
            self.isSending = false
            self.errorText = error
        }
    }
}

/// The oldest pending question for a chat, re-evaluated every few seconds so expired ones leave.
/// Without `operator.questions`, explains how to get it while the agent waits on `ask_user`.
struct PendingQuestionCard: View {
    let chat: ChatStore
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let pending = self.gateway.pendingQuestions(for: self.chat.sessionKey, at: context.date)
            if let prompt = pending.first {
                QuestionCardView(prompt: prompt, queued: pending.count - 1)
                    .id(prompt.id)
            } else if self.gateway.hello != nil, !self.gateway.canAnswerQuestions, self.isAskingUser {
                QuestionAccessHint(requestId: self.gateway.hello?.scopeUpgradeRequestId)
            }
        }
    }

    private var isAskingUser: Bool {
        guard self.chat.isRunning, case let .assistant(turn)? = self.chat.entries.last else { return false }
        return turn.tools.contains { $0.name == "ask_user" && $0.isRunning }
    }
}

/// Shown instead of a question card when this device may not answer questions yet.
struct QuestionAccessHint: View {
    let requestId: String?
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.appTheme) private var theme

    private var command: String { "openclaw devices approve \(self.requestId ?? "<requestId>")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The agent is waiting for your answer", systemImage: "questionmark.bubble.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(self.theme.accent)
            Text("This device isn't allowed to answer questions yet. Approve its request on the Gateway host, then try again. You can also answer in the Control UI or the channel the chat came from.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(self.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer(minLength: 8)
                Button("Try Again") { self.gateway.retryQuestionAccess() }
                    .glassButton()
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
