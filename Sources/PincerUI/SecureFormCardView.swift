import PincerKit
import SwiftUI

/// A Gateway-verified secure sign-in request (`question.kind == .secureForm`): the operator fills
/// masked fields that go straight to the Gateway's own form fill, never to the agent or transcript.
/// See `SECURE_FORM_UI_SPEC.md` for the design this implements.
struct SecureFormCardView: View {
    let prompt: QuestionPrompt
    /// Other prompts waiting behind this one in the same chat.
    let queued: Int
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.appTheme) private var theme
    @State private var draft = SecureFormDraft()
    @State private var isSending = false
    @State private var isSent = false
    @State private var errorText: String?
    @FocusState private var focus: String?

    private static let corner: CGFloat = 18

    private var form: SecureFormQuestion? { self.prompt.secureForm }
    private var answers: [String: String]? { self.draft.answers(for: self.prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            if let form = self.form {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    self.originLine(form)
                    Text("Pincer sends these values only to the Gateway's verified sign-in form. The agent never sees them.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if self.isSent {
                        self.sentNotice
                    } else {
                        ForEach(form.fields, id: \.fieldId) { field in
                            self.fieldRow(field)
                        }
                    }
                    if let errorText = self.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.md)
                if !self.isSent {
                    self.footer
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .padding(.horizontal, Theme.Spacing.row)
        .padding(.top, Theme.Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Secure sign-in request from the agent"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "lock.shield.fill")
                .font(.callout)
                .foregroundStyle(self.theme.accent)
            Text("Secure sign-in", bundle: .module)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            if self.queued > 0 {
                Text("+\(self.queued) more", bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.row)
        .padding(.bottom, 4)
    }

    private func originLine(_ form: SecureFormQuestion) -> some View {
        Label(form.origin, systemImage: "globe")
            .font(.title3.weight(.semibold))
            .textSelection(.enabled)
    }

    // MARK: Fields

    private func fieldRow(_ field: SecureFormQuestion.Field) -> some View {
        let text = Binding(
            get: { self.draft.text(for: field) },
            set: { self.draft.setText($0, for: field); self.errorText = nil })
        return VStack(alignment: .leading, spacing: 4) {
            Text(self.label(for: field.role))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SecureField(self.label(for: field.role), text: text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused(self.$focus, equals: field.fieldId)
                .disabled(self.isSending)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private func label(for role: SecureFormQuestion.FieldRole) -> String {
        switch role {
        case .username: L("Username")
        case .password: L("Password")
        case .otp: L("One-time code")
        case .email: L("Email")
        case let .other(raw): raw.isEmpty ? L("Value") : raw
        }
    }

    private var sentNotice: some View {
        Label(L("Fields were filled on the Gateway. Review the page before submitting there."), systemImage: "checkmark.shield.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.lg) {
            if let expiresAt = self.prompt.expiresAt {
                Text(expiresAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(L("Time left to answer"))
            }
            Spacer()
            Button(L("Skip")) { self.skip() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(self.isSending)
                .help(L("Leave the page untouched"))
            Button {
                self.submit()
            } label: {
                if self.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("Submit"))
                }
            }
            .glassProminentButton()
            .tint(self.theme.accent)
            .disabled(self.isSending || self.answers == nil)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.row)
    }

    // MARK: Actions

    private func submit() {
        guard !self.isSending, let answers = self.answers else { return }
        self.isSending = true
        self.errorText = nil
        Task {
            let error = await self.gateway.answerSecureForm(self.prompt, answers: answers)
            self.isSending = false
            if error == nil {
                withAnimation { self.isSent = true }
            } else {
                self.errorText = error
            }
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
