import PincerKit
import SwiftUI

/// Icon-only branch menu in the chat header, shown whenever the chat has more than one branch (#449).
/// Reads only `branches`, `isRunning` and the switch permission, so it never touches the transcript.
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
                if let reason = chip.disabledReason {
                    Section {
                        Button(reason) {}.disabled(true)
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .menuIndicator(.hidden)
            .help(chip.label)
            .accessibilityLabel(chip.label)
        }
    }
}
