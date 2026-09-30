import Foundation
import PincerKit

/// #449: the "Branch N of M" header chip for the demo garden chat (three branches).
@MainActor
func runBranchHeaderChipChecks(_ gateway: GatewayStore) async {
    print("Branch header chip (demo)")
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    await chat.refreshBranches()
    check(chat.branches.count == 3, "garden chat has three branches (\(chat.branches.count))")
    chat.setBranchAnchorVisible(true)
    check(chat.branchHeaderChip == nil, "chip hides while the fork point is on screen")
    chat.setBranchAnchorVisible(false)
    let number = chat.activeBranchNumber ?? 0
    check(chat.branchHeaderChip?.label == "Branch \(number) of 3" && chat.branchHeaderChip?.entries.count == 3,
          "chip reports the active branch when the fork point is off screen (\(chat.branchHeaderChip?.label ?? "nil"))")
    check(chat.branchHeaderChip?.entries.filter(\.isActive).count == 1, "exactly one branch is checked")
}
