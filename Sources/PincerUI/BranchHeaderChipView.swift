import PincerKit
import SwiftUI

/// "Branch 2 of 3" in the chat header while the inline switcher is scrolled out of view (#449).
/// Opens the branch menu; "Show Fork Point" scrolls back to where the branches fork.
struct BranchHeaderChipView: View {
    let chat: ChatStore?

    var body: some View {
        if let chat, let chip = chat.branchHeaderChip {
            Menu {
                ForEach(chip.entries, id: \.leafEntryId) { entry in
                    Button {
                        if !entry.isActive { Task { await chat.switchBranch(to: entry.leafEntryId) } }
                    } label: {
                        if entry.isActive {
                            Label(entry.title, systemImage: "checkmark")
                        } else {
                            Text(entry.title)
                        }
                    }
                    .disabled(!chip.canSwitch && !entry.isActive)
                }
                Divider()
                Button(L("Show Fork Point"), systemImage: "arrow.up.to.line") { chat.showForkPoint() }
            } label: {
                Label(chip.label, systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Shows this chat’s branches"))
            .accessibilityLabel(chip.label)
            .accessibilityHint(L("Shows this chat’s branches"))
        }
    }
}
