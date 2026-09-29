import PincerKit
import SwiftUI

/// "Branch 2 of 3 ‹ ›" above the composer when the chat's history has other paths (from an edit or rewind).
/// The label is a menu of every branch; the arrows step through them in the same order.
struct BranchSwitcher: View {
    let branches: [SessionBranch]
    let onSwitch: (SessionBranch) -> Void
    @Environment(\.appTheme) private var theme

    private var activeIndex: Int { self.branches.firstIndex(where: \.active) ?? 0 }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(self.theme.accent)
                .accessibilityHidden(true)
            self.step("chevron.left", label: L("Previous branch"), offset: -1)
            Menu {
                ForEach(self.branches) { branch in
                    let title = [branch.title, L("\(String(branch.messageCount)) messages")].joined(separator: " · ")
                    Button {
                        self.onSwitch(branch)
                    } label: {
                        if branch.active {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: title)
                        }
                    }
                }
            } label: {
                Text("Branch \(self.activeIndex + 1) of \(self.branches.count)", bundle: .module)
                    .font(.caption)
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityHint(Text("Choose a branch", bundle: .module))
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
        .help(target?.title ?? label)
        .accessibilityLabel(label)
    }
}
