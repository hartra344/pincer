import PincerKit
import SwiftUI
@testable import PincerUI

@MainActor
func runSheetChromeChecks() {
    check(SheetCancelToolbarItem {}.title == L("Cancel"), "SheetCancelToolbarItem defaults to Cancel")
    check(SheetDoneToolbarItem {}.title == L("Done"), "SheetDoneToolbarItem defaults to Done")
    check(SheetCancelToolbarItem(title: L("Close")) {}.title == L("Close"), "SheetCancelToolbarItem takes a custom title")
    var runs = 0
    SheetCancelToolbarItem { runs += 1 }.action()
    SheetDoneToolbarItem { runs += 1 }.action()
    check(runs == 2, "sheet toolbar items run their actions")
    check(ChatCardChrome(cornerRadius: 18).cornerRadius == 18, "ChatCardChrome keeps its corner radius")
}
