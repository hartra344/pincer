import Testing
@testable import PincerKit

@Suite("Sidebar split action visibility")
struct SidebarSplitActionPolicyTests {
    @Test func platformAndWidthDetermineWhetherSplitActionIsAvailable() {
        #expect(!SidebarSplitActionPolicy.shouldOffer(supportsSplitView: true, isCompactWidth: true),
                "a compact iPad cannot present the split view action")
        #expect(SidebarSplitActionPolicy.shouldOffer(supportsSplitView: true, isCompactWidth: false),
                "a regular iPad and macOS can offer split view")
        #expect(!SidebarSplitActionPolicy.shouldOffer(supportsSplitView: false, isCompactWidth: true),
                "iPhone does not offer split view")
    }
}
