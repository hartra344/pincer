import Testing
@testable import PincerUI

struct WorkspaceTitlePreferenceTests {
    @Test func sheetTitleRouting() {
        #expect(WorkspaceTitlePreference.sheetTitle(isWorkspace: true, workspaceTitle: nil) == "Browser")
        #expect(WorkspaceTitlePreference.sheetTitle(isWorkspace: true, workspaceTitle: "Files") == "Files")
        #expect(WorkspaceTitlePreference.sheetTitle(isWorkspace: false, workspaceTitle: "Files") == "Runs")
    }

    @Test func reduceKeepsLatestNonNil() {
        var value: String? = "Browser"
        WorkspaceTitlePreference.reduce(value: &value, nextValue: { nil })
        #expect(value == "Browser")
        WorkspaceTitlePreference.reduce(value: &value, nextValue: { "Files" })
        #expect(value == "Files")
    }
}
