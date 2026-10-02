import PincerKit
import SwiftUI

/// Shared lifecycle for Gateway Settings notices. Callers keep their existing visual treatment;
/// this banner owns the per-notice announcement and timeout task.
struct SettingsNoticeBanner<Content: View>: View {
    let id: UUID
    let text: String
    let severity: SettingsNoticeSeverity
    let announces: Bool
    let dismiss: @MainActor () -> Void
    let wait: @MainActor (Duration) async -> Void
    let announce: @MainActor (String) -> Void
    let content: Content
    var showsDismissButton = true

    init(id: UUID, text: String, severity: SettingsNoticeSeverity, announces: Bool,
         showsDismissButton: Bool = true,
         dismiss: @escaping @MainActor () -> Void,
         wait: @escaping @MainActor (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) },
         announce: @escaping @MainActor (String) -> Void = { AccessibilityAnnouncer.announce($0) },
         @ViewBuilder content: () -> Content)
    {
        self.id = id
        self.text = text
        self.severity = severity
        self.announces = announces
        self.showsDismissButton = showsDismissButton
        self.dismiss = dismiss
        self.wait = wait
        self.announce = announce
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            self.content
            if self.showsDismissButton {
                Spacer(minLength: Theme.Spacing.md)
                Button(action: self.dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Dismiss"))
                .keyboardShortcut(.cancelAction)
            }
        }
        .task(id: self.id) {
            if self.announces { self.announce(self.text) }
            guard SettingsNoticePolicy.shouldAutoDismiss(self.severity) else { return }
            await self.wait(.seconds(4))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }
}
