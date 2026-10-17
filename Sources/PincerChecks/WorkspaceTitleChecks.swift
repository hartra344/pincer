import Foundation
#if DEBUG && os(macOS)
@testable import PincerUI

// #1026: the Browser panel reports its title as a preference and only the compact sheet's bar applies it,
// so the title can't stay on the chat's navigation bar after the panel closes.
@MainActor
func runWorkspaceTitleChecks() {
    typealias P = WorkspaceTitlePreference
    check(P.sheetTitle(isWorkspace: true, workspaceTitle: nil) == "Browser", "sheet title falls back to Browser before the panel reports one")
    check(P.sheetTitle(isWorkspace: true, workspaceTitle: "Files") == "Files", "sheet title follows the selected tab")
    check(P.sheetTitle(isWorkspace: false, workspaceTitle: "Files") == "Runs", "the Runs panel ignores the workspace title")
    check(P.defaultValue == nil, "no title is reported until the panel is present")
    var value: String? = "Browser"
    P.reduce(value: &value, nextValue: { nil })
    check(value == "Browser", "a missing next title keeps the current one")
    P.reduce(value: &value, nextValue: { "Files" })
    check(value == "Files", "the latest reported title wins")
}
#else
@MainActor
func runWorkspaceTitleChecks() {}
#endif
