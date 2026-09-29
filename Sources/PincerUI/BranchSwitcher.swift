import PincerKit
import SwiftUI

/// "Branch 2 of 3 ‹ ›" above the composer when the chat's history has other paths (from an edit or rewind).
struct BranchSwitcher: View {
    let branches: [SessionBranch]
    let onSwitch: (SessionBranch) -> Void
    @Environment(\.appTheme) private var theme

    private var activeIndex: Int { self.branches.firstIndex(where: \.active) ?? 0 }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(self.theme.accent)
            self.step("chevron.left", label: L("Previous branch"), offset: -1)
            Text("Branch \(self.activeIndex + 1) of \(self.branches.count)", bundle: .module)
                .font(.caption)
                .monospacedDigit()
            self.step("chevron.right", label: L("Next branch"), offset: 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .accessibilityElement(children: .contain)
    }

    private func step(_ symbol: String, label: String, offset: Int) -> some View {
        let target = self.branches.indices.contains(self.activeIndex + offset) ? self.branches[self.activeIndex + offset] : nil
        return Button {
            if let target { self.onSwitch(target) }
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(target?.headline ?? label)
        .accessibilityLabel(label)
    }
}
