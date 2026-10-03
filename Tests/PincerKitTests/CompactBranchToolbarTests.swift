import Foundation
import Testing
@testable import PincerKit

@Suite("Compact branch toolbar admission")
struct CompactBranchToolbarTests {
    @Test(arguments: [0, 1, 2, 3])
    func admissionMatchesActualChipAcrossPermissionsAndActivity(_ count: Int) {
        let branches = (0..<count).map {
            SessionBranch(leafEntryId: "leaf-\($0)", headline: "Branch \($0)", messageCount: $0 + 1, active: $0 == 0)
        }
        for access in [false, true] {
            for running in [false, true] {
                let chip = BranchHeaderChip(branches: branches, hasAccess: access, isRunning: running)
                #expect(BranchHeaderChip.shows(branchCount: count) == (chip != nil))
                #expect((chip != nil) == (count > 1))
                if let chip { #expect(chip.entries.count == count) }
            }
        }
    }

    @MainActor @Test
    func actualStoreAdmissionFollowsBranchChanges() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Toolbar admission", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "compact-toolbar", agentId: nil, gateway: gateway, headless: true)
        for count in [0, 1, 3, 1, 0] {
            chat.branches = (0..<count).map {
                SessionBranch(leafEntryId: "leaf-\($0)", headline: "Branch \($0)", messageCount: 1, active: $0 == 0)
            }
            #expect(chat.hasBranchHeaderChip == (chat.branchHeaderChip != nil))
            #expect(chat.hasBranchHeaderChip == (count > 1))
        }
    }
}
