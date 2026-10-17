import Testing
@testable import PincerUI

struct WorkspaceTitlePreferenceTests {
    @Test func sheetTitleRouting() {
        #expect(WorkspaceTitlePreference.sheetTitle(panel: .workspace, workspaceTitle: nil) == "Browser")
        #expect(WorkspaceTitlePreference.sheetTitle(panel: .workspace, workspaceTitle: "Files") == "Files")
        #expect(WorkspaceTitlePreference.sheetTitle(panel: .runs, workspaceTitle: "Files") == "Runs")
        #expect(WorkspaceTitlePreference.sheetTitle(panel: .portals, workspaceTitle: "Files") == "Portals")
    }

    @Test func reduceKeepsLatestNonNil() {
        var value: String? = "Browser"
        WorkspaceTitlePreference.reduce(value: &value, nextValue: { nil })
        #expect(value == "Browser")
        WorkspaceTitlePreference.reduce(value: &value, nextValue: { "Files" })
        #expect(value == "Files")
    }
}
