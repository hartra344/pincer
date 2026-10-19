import CoreGraphics
import Foundation
import SwiftUI
@testable import PincerKit
import Testing
@testable import PincerUI

@MainActor
private final class CallLog {
    var text = ""
    var events: [String] = []
}

@MainActor
private func makeComposerParent(_ log: CallLog, text: String = "", caret: CaretRequest? = nil, focus: Int = 0) -> PlatformComposerTextView {
    PlatformComposerTextView(
        text: Binding(get: { log.text }, set: { log.text = $0 }), maxLines: 5, isEditable: true, menuActive: false,
        escapeActive: false, canSubmit: true, focusRequest: focus, onSubmit: {}, onCommandSubmit: nil, onMedia: { _ in },
        onKey: { _ in false }, onCaretAtEnd: { log.events.append("end:\($0)") },
        onMarkedTextChange: { log.events.append("marked:\($0)") },
        onSelectionChange: { log.events.append("selection:\($0.location),\($0.length)") },
        onFocusChange: { _ in }, caretRequest: caret, autoFocus: { true })
}

@MainActor
@Suite("Shared platform helpers")
struct SharedPlatformHelpersTests {
    private func controller(_ scratch: ScratchDefaults) -> (TranscriptListController, TranscriptListControllerTests.FakeHost) {
        let (controller, host, _) = TranscriptListControllerTests().make(scratch)
        return (controller, host)
    }

    // MARK: A

    @Test func contentInsetsAddVerticalInsetAndClampNegatives() {
        let inset = TranscriptLayout.verticalInset
        let plain = TranscriptListController.contentInsets(top: 10, bottom: 20)
        #expect(plain.top == inset + 10)
        #expect(plain.bottom == inset + 20)
        let clamped = TranscriptListController.contentInsets(top: -5, bottom: -1)
        #expect(clamped.top == inset)
        #expect(clamped.bottom == inset)
    }

    @Test func insetsChangedUsesAHalfPointThreshold() {
        #expect(!TranscriptListController.insetsChanged(from: (10, 10), to: (10, 10)))
        #expect(!TranscriptListController.insetsChanged(from: (10, 10), to: (10.5, 9.5)))
        #expect(TranscriptListController.insetsChanged(from: (10, 10), to: (10.6, 10)))
        #expect(TranscriptListController.insetsChanged(from: (10, 10), to: (10, 9.4)))
    }

    // MARK: B

    @Test func layoutCorrectingHeightRecordsTheLaidOutHeight() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, host) = self.controller(scratch)
        _ = controller.accept(TranscriptListControllerTests.rows(0..<3), contextChanged: false)
        let width = host.layoutWidth
        _ = controller.measure([0, 1, 2], width: width, deadline: nil)
        let row = controller.rows[1]
        let layout = controller.layoutCorrectingHeight(row, width: width)
        #expect(layout.id == row.id)
        #expect(layout.width == width)
        #expect(abs((controller.heights[row.id]?.value ?? -1) - max(1, layout.height)) <= 0.5)
        #expect(controller.heights[row.id]?.width == width)
    }

    // MARK: C

    @Test func rotorsListKindsInOrder() {
        let rotors = TranscriptNavKind.rotors
        #expect(rotors.map(\.kind) == [.message, .reply, .user, .tool])
        #expect(rotors.map(\.name) == ["Messages", "Replies", "Your Messages", "Tool Calls"])
    }

    // MARK: D / E

    @Test func cellStateAppliesEachSerialOnce() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _) = self.controller(scratch)
        let renderer = controller.renderer
        let content = TranscriptRowView(frame: .zero)
        var state = TranscriptCellState()
        #expect(state.actions == nil)

        var layout = TranscriptRowLayout(id: "r", width: 200)
        layout.height = 40
        layout.serial = 7
        let applied1 = state.apply(layout, actions: renderer, to: content)
        #expect(applied1)
        #expect(content.frame == CGRect(x: 0, y: 0, width: 200, height: 40))
        #expect(state.actions === renderer)
        #expect(content.layout?.serial == 7)

        let applied2 = state.apply(layout, actions: renderer, to: content)
        #expect(!applied2)

        var resized = layout
        resized.height = 55
        let applied3 = state.apply(resized, actions: renderer, to: content)
        #expect(!applied3)
        #expect(content.frame == CGRect(x: 0, y: 0, width: 200, height: 55))
        #expect(content.layout?.serial == 7)

        var next = resized
        next.serial = 8
        let applied4 = state.apply(next, actions: renderer, to: content)
        #expect(applied4)
        #expect(content.layout?.serial == 8)
    }

    @Test func enclosingRowFindsNearestAncestorExcludingSelf() {
        let outer = TranscriptRowView(frame: .zero)
        let inner = TranscriptRowView(frame: .zero)
        let middle = PView(frame: .zero)
        let leaf = PView(frame: .zero)
        outer.addSubview(inner)
        inner.addSubview(middle)
        middle.addSubview(leaf)
        #expect(leaf.enclosingRow === inner)
        #expect(middle.enclosingRow === inner)
        #expect(inner.enclosingRow === outer)
        #expect(outer.enclosingRow == nil)
        #expect(PView(frame: .zero).enclosingRow == nil)
    }

    // MARK: F

    @Test func syntaxColorPackingAndCompositing() {
        typealias C = TranscriptSyntaxColors
        #expect(C.packed(C.RGBA(red: 1, green: 0, blue: 0, alpha: 1)) == 0xFF0000)
        #expect(C.packed(C.RGBA(red: 2, green: -1, blue: 0.5, alpha: 1)) == 0xFF0080)
        let unpacked = C.rgba(0x336699)
        #expect(unpacked.alpha == 1)
        #expect(C.packed(unpacked) == 0x336699)
        let white = C.RGBA(red: 1, green: 1, blue: 1, alpha: 0.5)
        #expect(C.composite(white, over: 0x000000) == 0x808080)
        #expect(C.composite(C.RGBA(red: 1, green: 0, blue: 0, alpha: 0), over: 0x123456) == 0x123456)
        #expect(C.composite(C.RGBA(red: 1, green: 0, blue: 0, alpha: 1), over: 0x123456) == 0xFF0000)
    }

    // MARK: G

    @Test func takeCaretAppliesEachSerialOnceAndClamps() {
        let log = CallLog()
        let base = ComposerCoordinatorBase(makeComposerParent(log, caret: CaretRequest(offset: 3, serial: 1)))
        #expect(base.caretSerial == 1)
        #expect(base.takeCaret(CaretRequest(offset: 3, serial: 1), length: 10) == nil)
        #expect(base.takeCaret(nil, length: 10) == nil)
        #expect(base.takeCaret(CaretRequest(offset: 99, serial: 2), length: 10) == 10)
        #expect(base.takeCaret(CaretRequest(offset: 4, serial: 2), length: 10) == nil)
        #expect(base.takeCaret(CaretRequest(offset: -4, serial: 3), length: 10) == 0)
    }

    @Test func pendingEditPushesParentTextAndCaret() {
        let log = CallLog()
        log.text = "héllo 👋"
        let length = (log.text as NSString).length
        let base = ComposerCoordinatorBase(makeComposerParent(log))
        let edit = base.pendingEdit(viewText: "stale")
        #expect(edit.text == log.text)
        #expect(edit.selection == NSRange(location: length, length: 0))

        base.parent = makeComposerParent(log, caret: CaretRequest(offset: 2, serial: 5))
        let withCaret = base.pendingEdit(viewText: "stale")
        #expect(withCaret.text == log.text)
        #expect(withCaret.selection == NSRange(location: 2, length: 0))
    }

    @Test func pendingEditWithMatchingTextOnlyReportsCaret() {
        let log = CallLog()
        log.text = "abc"
        let base = ComposerCoordinatorBase(makeComposerParent(log))
        let idle = base.pendingEdit(viewText: "abc")
        #expect(idle.text == nil)
        #expect(idle.selection == nil)

        base.parent = makeComposerParent(log, caret: CaretRequest(offset: 1, serial: 9))
        let caret = base.pendingEdit(viewText: "abc")
        #expect(caret.text == nil)
        #expect(caret.selection == NSRange(location: 1, length: 0))
        #expect(base.pendingEdit(viewText: "abc").selection == nil)
    }

    @Test func reportCaretOrdersMarkedTextBeforeCaretAtEnd() {
        let log = CallLog()
        let base = ComposerCoordinatorBase(makeComposerParent(log))
        base.reportCaret(NSRange(location: 4, length: 0), length: 4, hasMarkedText: true)
        base.reportCaret(NSRange(location: 4, length: 1), length: 4, hasMarkedText: false)
        base.reportCaret(NSRange(location: 0, length: 0), length: nil, hasMarkedText: false)
        #expect(log.events == ["marked:true", "end:true", "marked:false", "end:false", "marked:false", "end:false"])
    }

    @Test func takeFocusRequestFiresOncePerChange() {
        let log = CallLog()
        let base = ComposerCoordinatorBase(makeComposerParent(log))
        #expect(!base.takeFocusRequest())
        base.parent = makeComposerParent(log, focus: 1)
        #expect(base.takeFocusRequest())
        #expect(!base.takeFocusRequest())
    }

    // MARK: H

    @Test func safeSubscriptReturnsNilOutOfRange() {
        let values = [1, 2, 3]
        #expect(values[safe: 0] == 1)
        #expect(values[safe: 2] == 3)
        #expect(values[safe: 3] == nil)
        #expect(values[safe: -1] == nil)
        #expect([Int]()[safe: 0] == nil)
    }
}
