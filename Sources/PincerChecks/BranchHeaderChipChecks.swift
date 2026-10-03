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
    check(chat.hasBranchHeaderChip && chat.hasBranchHeaderChip == (chip != nil), "multi-branch toolbar admission matches the actual chip")

    let single = gateway.chat(for: "agent:main:dashboard:trip")
    await single.load()
    await single.refreshBranches()
    check(single.branches.count == 1, "trip loads one actual branch")
    check(!single.hasBranchHeaderChip && single.branchHeaderChip == nil, "single-branch chat admits no empty toolbar slot")

    let selectedBeforeCreate = gateway.selectedKey
    if let key = await gateway.createSession(agentId: "main", label: "Compact toolbar empty chat", category: "Work", select: false) {
        let empty = gateway.chat(for: key)
        await empty.load()
        await empty.refreshBranches()
        check(empty.branches.isEmpty, "new Demo session has no transcript branches")
        check(!empty.hasBranchHeaderChip && empty.branchHeaderChip == nil, "empty chat admits no branch toolbar slot")
        _ = await gateway.sessionManager.delete([key])
        check(gateway.selectedKey == selectedBeforeCreate, "empty-session creation and cleanup preserve the selected chat")
    } else {
        check(false, "creates an actual empty Demo session for toolbar admission")
    }
}

@MainActor
func runDemoCompactBranchToolbarChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("compact toolbar Demo connection", timeout: 25) {
        gateway.state.isConnected && !gateway.sessions.isEmpty
    }
    check(connected, "compact toolbar connects to the seeded Demo Gateway")
    guard connected else { return }
    await runBranchHeaderChipChecks(gateway)
}
