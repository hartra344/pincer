import CoreGraphics
import Foundation
import SwiftUI
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class HelperLog {
    var text = ""
    var events: [String] = []
}

@MainActor
private func helperComposerParent(_ log: HelperLog, caret: CaretRequest? = nil, focus: Int = 0) -> PlatformComposerTextView {
    PlatformComposerTextView(
        text: Binding(get: { log.text }, set: { log.text = $0 }), maxLines: 5, isEditable: true, menuActive: false,
        escapeActive: false, canSubmit: true, focusRequest: focus, onSubmit: {}, onCommandSubmit: nil, onMedia: { _ in },
        onKey: { _ in false }, onCaretAtEnd: { log.events.append("end:\($0)") },
        onMarkedTextChange: { log.events.append("marked:\($0)") },
        onSelectionChange: { log.events.append("selection:\($0.location),\($0.length)") },
        onFocusChange: { _ in }, caretRequest: caret, autoFocus: { true })
}

/// #1047: the AppKit/UIKit code moved into shared helpers keeps its behaviour.
@MainActor
func runSharedPlatformHelperChecks() {
    // A: insets
    let inset = TranscriptLayout.verticalInset
    let insets = TranscriptListController.contentInsets(top: -3, bottom: 8)
    check(insets.top == inset && insets.bottom == inset + 8, "contentInsets adds the vertical inset and clamps negatives")
    check(!TranscriptListController.insetsChanged(from: (10, 10), to: (10.5, 9.5)), "insetsChanged ignores half-point moves")
    check(TranscriptListController.insetsChanged(from: (10, 10), to: (10, 10.6)), "insetsChanged sees larger moves")

    // B: layoutCorrectingHeight
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let stub = makeStubTranscript(defaults: defaults, rowCount: 3, windowed: false)
    let (controller, host, rows) = (stub.controller, stub.host, stub.rows)
    _ = controller.accept(rows, contextChanged: false)
    _ = controller.measure([0, 1, 2], width: host.layoutWidth, deadline: nil)
    let laidOut = controller.layoutCorrectingHeight(controller.rows[1], width: host.layoutWidth)
    let rowID = controller.rows[1].id
    check(laidOut.id == rowID && abs((controller.heights[rowID]?.value ?? -1) - max(1, laidOut.height)) <= 0.5,
          "layoutCorrectingHeight records the laid-out height")

    // C: rotors
    let rotors = TranscriptNavKind.rotors
    check(rotors.map(\.kind) == [.message, .reply, .user, .tool], "rotors list kinds in order")
    check(rotors.map(\.name) == ["Messages", "Replies", "Your Messages", "Tool Calls"], "rotors carry their names")

    // D: cell state
    let content = TranscriptRowView(frame: .zero)
    var state = TranscriptCellState()
    var layout = TranscriptRowLayout(id: "r", width: 200)
    layout.height = 40
    layout.serial = 7
    check(state.apply(layout, actions: controller.renderer, to: content), "cell state applies a new serial")
    check(!state.apply(layout, actions: controller.renderer, to: content), "cell state skips a repeated serial")
    layout.height = 55
    check(!state.apply(layout, actions: controller.renderer, to: content)
          && content.frame == CGRect(x: 0, y: 0, width: 200, height: 55), "cell state still updates the frame")
    layout.serial = 8
    check(state.apply(layout, actions: controller.renderer, to: content), "cell state applies the next serial")

    // E: enclosingRow
    let outer = TranscriptRowView(frame: .zero)
    let leaf = PView(frame: .zero)
    outer.addSubview(leaf)
    check(leaf.enclosingRow === outer && outer.enclosingRow == nil, "enclosingRow finds the ancestor row, never self")

    // F: syntax colors
    typealias Colors = TranscriptSyntaxColors
    check(Colors.packed(Colors.RGBA(red: 1, green: 0, blue: 0, alpha: 1)) == 0xFF0000, "packed red")
    check(Colors.packed(Colors.rgba(0x336699)) == 0x336699, "rgba round-trips through packed")
    check(Colors.composite(Colors.RGBA(red: 1, green: 1, blue: 1, alpha: 0.5), over: 0) == 0x808080, "half white over black")
    check(Colors.composite(Colors.RGBA(red: 1, green: 0, blue: 0, alpha: 0), over: 0x123456) == 0x123456, "alpha 0 keeps background")

    // G: composer coordinator
    let log = HelperLog()
    log.text = "abc"
    let base = ComposerCoordinatorBase(helperComposerParent(log, caret: CaretRequest(offset: 1, serial: 1)))
    check(base.takeCaret(CaretRequest(offset: 1, serial: 1), length: 3) == nil, "initial caret request is not applied")
    check(base.takeCaret(CaretRequest(offset: 99, serial: 2), length: 3) == 3, "caret request clamps and applies once")
    check(base.takeCaret(CaretRequest(offset: 1, serial: 2), length: 3) == nil, "caret serial is taken once")
    base.parent = helperComposerParent(log)
    let stale = base.pendingEdit(viewText: "x")
    check(stale.text == "abc" && stale.selection == NSRange(location: 3, length: 0), "pendingEdit pushes parent text")
    let same = base.pendingEdit(viewText: "abc")
    check(same.text == nil && same.selection == nil, "pendingEdit is idle when text matches")
    base.reportCaret(NSRange(location: 3, length: 0), length: 3, hasMarkedText: true)
    check(log.events == ["marked:true", "end:true"], "reportCaret order")
    log.events = []
    base.reportCaret(NSRange(location: 0, length: 0), length: nil, hasMarkedText: false)
    check(log.events == ["marked:false", "end:false"], "reportCaret with unknown length")
    let focused = helperComposerParent(log, focus: 1)
    check(!base.takeFocusRequest(), "no focus request initially")
    base.parent = focused
    check(base.takeFocusRequest() && !base.takeFocusRequest(), "focus request fires once")

    // H: safe subscript
    let values = [1, 2, 3]
    check(values[safe: 2] == 3 && values[safe: 3] == nil && values[safe: -1] == nil, "safe subscript bounds")
}
