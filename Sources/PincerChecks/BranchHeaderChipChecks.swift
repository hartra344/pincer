import Foundation
import PincerKit

/// #449: the "Branch N of M" header control for the demo garden chat (three seeded branches, more once earlier checks fork it).
@MainActor
func runBranchHeaderChipChecks(_ gateway: GatewayStore) async {
    print("Branch header chip (demo)")
    let chat = gateway.chat(for: "agent:main:dashboard:garden")
    await chat.load()
    await chat.refreshBranches()
    let count = chat.branches.count
    check(count >= 3, "garden chat has its seeded branches (\(count))")
    let chip = chat.branchHeaderChip
    let number = chat.activeBranchNumber ?? 0
    check(chip != nil && chip?.label == "Branch \(number) of \(count)", "chip is shown and names the active branch (\(chip?.label ?? "nil"))")
    check((chip?.entries.count ?? 0) >= 3 && chip?.entries.count == count, "chip lists every branch")
    check(chip?.entries.filter(\.isActive).count == 1, "exactly one branch is checked")
}
