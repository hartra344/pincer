import PincerKit
import SwiftUI

/// The bottom capsule toast shared by Devices and Pairing Requests. Dismissal (button, timeout or
/// tap) only clears the notice if it is still the one being shown.
struct SettingsNoticeToast: View {
    let id: UUID
    let text: String
    let severity: SettingsNoticeSeverity
    let isCurrent: @MainActor () -> Bool
    let clear: @MainActor () -> Void

    private func dismissIfCurrent() {
        guard self.isCurrent() else { return }
        withAnimation { self.clear() }
    }

    var body: some View {
        SettingsNoticeBanner(id: self.id, text: self.text, severity: self.severity,
                             announces: true, dismiss: { self.dismissIfCurrent() }) {
            Text(self.text).font(.callout).multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .glassSurface(in: Capsule())
        .padding(.horizontal)
        .padding(.bottom, Theme.Spacing.section)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onTapGesture { self.dismissIfCurrent() }
    }
}
