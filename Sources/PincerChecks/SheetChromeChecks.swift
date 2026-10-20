#if os(macOS)
import AppKit
#endif
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
    #if os(macOS)
    func size<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
    let content = Text(verbatim: "Saved").frame(width: 120, height: 20)
    let inline = content
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .glassSurface(in: Capsule())
        .padding(.bottom, Theme.Spacing.section)
    check(size(content.bottomToastChrome()) == size(inline), "bottomToastChrome matches the inline toast composition")
    #endif
}
