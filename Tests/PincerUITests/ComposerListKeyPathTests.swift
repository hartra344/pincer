#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class ListFixture { var text = "" }

/// #1072: list Tab / Shift-Tab / Enter driven through the real AppKit text view delegate.
@MainActor
@Suite("Composer list key path", .serialized)
struct ComposerListKeyPathTests {
    private func makeView(_ fixture: ListFixture) throws -> (NSWindow, ComposerNSTextView) {
        let host = NSHostingView(rootView: ComposerTextView(
            placeholder: "Message", text: Binding(get: { fixture.text }, set: { fixture.text = $0 }), menuActive: false,
            onSubmit: {}, onMedia: { _ in }, onKey: { _ in false }, autoFocus: { false })
            .frame(width: 300, height: 120))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layout()
        func find(_ v: NSView) -> ComposerNSTextView? {
            (v as? ComposerNSTextView) ?? v.subviews.lazy.compactMap(find).first
        }
        let tv = try #require(find(host))
        #expect(window.makeFirstResponder(tv))
        return (window, tv)
    }

    private func command(_ tv: NSTextView, _ selector: Selector) -> Bool {
        tv.delegate?.textView?(tv, doCommandBy: selector) ?? false
    }

    private func set(_ tv: NSTextView, _ text: String) {
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    @Test func tabRestartsOrderedSublist() throws {
        let (window, tv) = try makeView(ListFixture())
        defer { window.close() }
        self.set(tv, "1. a\n2. b\n3. c")
        #expect(self.command(tv, #selector(NSResponder.insertTab(_:))))
        #expect(tv.string == "1. a\n2. b\n   1. c")
        #expect(tv.selectedRange() == NSRange(location: (tv.string as NSString).length, length: 0))
    }

    @Test func backtabRenumbersAgainstParent() throws {
        let (window, tv) = try makeView(ListFixture())
        defer { window.close() }
        self.set(tv, "1. a\n   1. b\n   2. c")
        #expect(self.command(tv, #selector(NSResponder.insertBacktab(_:))))
        #expect(tv.string == "1. a\n   1. b\n2. c")
    }

    /// A hardware Return with `flags`, routed the way AppKit's standard key bindings do:
    /// ⌥↩ → insertNewlineIgnoringFieldEditor:, otherwise insertNewline:.
    private func pressReturn(_ tv: ComposerNSTextView, flags: NSEvent.ModifierFlags) -> Bool {
        tv.currentModifierFlags = { flags }
        defer { tv.currentModifierFlags = { [] } }
        let selector = flags.contains(.option)
            ? #selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)) : #selector(NSResponder.insertNewline(_:))
        return self.command(tv, selector)
    }

    @Test(arguments: [NSEvent.ModifierFlags.shift, .option])
    func returnContinuesBulletList(_ flags: NSEvent.ModifierFlags) throws {
        let (window, tv) = try makeView(ListFixture())
        defer { window.close() }
        self.set(tv, "* one")
        #expect(self.pressReturn(tv, flags: flags))
        #expect(tv.string == "* one\n* ")
    }

    /// The user's bug 1: leaving a list with an empty item must clear the marker, not leave a literal `*`.
    @Test(arguments: [NSEvent.ModifierFlags.shift, .option])
    func returnOnEmptyBulletExitsList(_ flags: NSEvent.ModifierFlags) throws {
        let (window, tv) = try makeView(ListFixture())
        defer { window.close() }
        self.set(tv, "* one\n* two\n* ")
        #expect(self.pressReturn(tv, flags: flags))
        #expect(tv.string == "* one\n* two\n")
        tv.insertText("after", replacementRange: tv.selectedRange())
        #expect(tv.string == "* one\n* two\nafter")
    }

    @Test(arguments: [NSEvent.ModifierFlags.shift, .option])
    func returnOnEmptyNestedItemOutdents(_ flags: NSEvent.ModifierFlags) throws {
        let (window, tv) = try makeView(ListFixture())
        defer { window.close() }
        self.set(tv, "1. a\n   1. b\n   2. ")
        #expect(self.pressReturn(tv, flags: flags))
        #expect(tv.string == "1. a\n   1. b\n2. ")
        #expect(tv.selectedRange() == NSRange(location: (tv.string as NSString).length, length: 0))
    }
}
#else
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class ListFixture { var text = "" }

/// #1072: the iOS paths. Return goes through the real `UITextViewDelegate`; Tab and Shift-Tab go through the
/// hardware-keyboard `indentKey:` command the text view registers in `keyCommands`.
@MainActor
@Suite("Composer list key path", .serialized)
struct ComposerListKeyPathTests {
    private func makeView(_ fixture: ListFixture) throws -> (UIWindow, ComposerUITextView) {
        let controller = UIHostingController(rootView: ComposerTextView(
            placeholder: "Message", text: Binding(get: { fixture.text }, set: { fixture.text = $0 }), menuActive: false,
            onSubmit: {}, onMedia: { _ in }, onKey: { _ in false }, autoFocus: { false })
            .frame(width: 300, height: 120))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        func find(_ v: UIView) -> ComposerUITextView? {
            (v as? ComposerUITextView) ?? v.subviews.lazy.compactMap(find).first
        }
        return (window, try #require(find(controller.view)))
    }

        /// Seeds the binding before hosting so a later SwiftUI update can't reset the view's text.
    private func makeView(_ text: String) throws -> (UIWindow, ComposerUITextView) {
        let fixture = ListFixture()
        fixture.text = text
        let (window, tv) = try self.makeView(fixture)
        #expect(tv.text == text)
        tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return (window, tv)
    }

    private func returnKey(_ tv: UITextView) {
        let allowed = tv.delegate?.textView?(tv, shouldChangeTextIn: tv.selectedRange, replacementText: "\n") ?? true
        #expect(!allowed, "the delegate applies the list edit itself")
    }

    private func tab(_ tv: ComposerUITextView, shift: Bool) throws {
        // Like UIKit: the first matching command whose action the view can perform wins (menuKey also binds Tab).
        let command = try #require(tv.keyCommands?.first { command in
            guard command.input == "\t", command.modifierFlags == (shift ? .shift : []), let action = command.action else { return false }
            return tv.canPerformAction(action, withSender: command)
        })
        let action = try #require(command.action)
        tv.perform(action, with: command)
    }

    @Test func tabRestartsOrderedSublist() throws {
        let (window, tv) = try self.makeView("1. a\n2. b\n3. c")
        defer { window.isHidden = true }
        try self.tab(tv, shift: false)
        #expect(tv.text == "1. a\n2. b\n   1. c")
        #expect(tv.selectedRange == NSRange(location: (tv.text as NSString).length, length: 0))
    }

    @Test func backtabRenumbersAgainstParent() throws {
        let (window, tv) = try self.makeView("1. a\n   1. b\n   2. c")
        defer { window.isHidden = true }
        try self.tab(tv, shift: true)
        #expect(tv.text == "1. a\n   1. b\n2. c")
    }

    /// ⇧↩ and ⌥↩ aren't claimed by key commands, so like the on-screen keyboard they reach the delegate as "\n".
    @Test func returnContinuesBulletList() throws {
        let (window, tv) = try self.makeView("* one")
        defer { window.isHidden = true }
        self.returnKey(tv)
        #expect(tv.text == "* one\n* ")
    }

    /// The user's bug 1: leaving a list with an empty item must clear the marker, not leave a literal `*`.
    @Test func returnOnEmptyBulletExitsList() throws {
        let (window, tv) = try self.makeView("* one\n* two\n* ")
        defer { window.isHidden = true }
        self.returnKey(tv)
        #expect(tv.text == "* one\n* two\n")
    }

    @Test func returnOnEmptyNestedItemOutdents() throws {
        let (window, tv) = try self.makeView("1. a\n   1. b\n   2. ")
        defer { window.isHidden = true }
        self.returnKey(tv)
        #expect(tv.text == "1. a\n   1. b\n2. ")
        #expect(tv.selectedRange == NSRange(location: (tv.text as NSString).length, length: 0))
    }
}
#endif
