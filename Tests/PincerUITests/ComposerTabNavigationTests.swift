#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Observable
private final class ComposerTabFixture {
    var text = ""
    var menuActive = false
    var acceptedSuggestions = 0
}

@MainActor
private final class ComposerNeighborButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

private struct ComposerNeighbor: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSButton {
        ComposerNeighborButton(title: self.title, target: nil, action: nil)
    }
    func updateNSView(_ view: NSButton, context: Context) {}
}

@MainActor
private struct ComposerTabHost: View {
    @Bindable var fixture: ComposerTabFixture

    var body: some View {
        HStack {
            ComposerNeighbor(title: "Before composer").frame(width: 120, height: 32)
            ComposerTextView(
                placeholder: "Message", text: self.$fixture.text, menuActive: self.fixture.menuActive,
                onSubmit: {}, onMedia: { _ in }, onKey: { key in
                    guard key == .tab, self.fixture.menuActive else { return false }
                    self.fixture.acceptedSuggestions += 1
                    return true
                }, autoFocus: { false })
                .frame(width: 240, height: 50)
            ComposerNeighbor(title: "After composer").frame(width: 120, height: 32)
        }
        .padding()
        .frame(width: 700, height: 120)
    }
}

/// A real AppKit text view in an explicit key-view loop. This checks the dispatch path that a
/// pure routing-policy test cannot cover: AppKit must move focus or insert a character in place.
@MainActor
@Suite("Composer Tab navigation", .serialized)
struct ComposerTabNavigationTests {
    @Test func tabMovesFocusAndOptionTabInsertsText() async throws {
        let fixture = ComposerTabFixture()
        let host = NSHostingView(rootView: ComposerTabHost(fixture: fixture))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 120)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layout()
        defer { window.close() }

        let buttons = Self.descendants(of: host).compactMap { $0 as? NSButton }
        let before = try #require(buttons.first { $0.title == "Before composer" })
        let after = try #require(buttons.first { $0.title == "After composer" })
        let textView = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerNSTextView }.first)
        before.nextKeyView = textView
        textView.nextKeyView = after
        after.nextKeyView = before
        #expect(textView.nextValidKeyView === after)

        #expect(window.makeFirstResponder(textView), "the composer accepts keyboard focus")
        Self.sendTab(window, modifiers: [])
        #expect(window.firstResponder === after, "Tab advances to the next key view")

        #expect(window.makeFirstResponder(textView))
        Self.sendTab(window, modifiers: [.shift])
        #expect(window.firstResponder === before, "Shift-Tab moves to the previous key view")

        #expect(window.makeFirstResponder(textView))
        Self.sendTab(window, modifiers: [.option])
        #expect(textView.string == "\t", "Option-Tab inserts a literal tab in the draft")

        fixture.menuActive = true
        host.layout()
        #expect(window.makeFirstResponder(textView))
        Self.sendTab(window, modifiers: [])
        #expect(fixture.acceptedSuggestions == 1, "plain Tab remains the slash-menu acceptance key")
        #expect(window.firstResponder === textView, "accepting a suggestion keeps focus in the composer")

        Self.sendTab(window, modifiers: [.option])
        #expect(textView.string == "\t\t", "Option-Tab inserts text even while suggestions are open")
        #expect(fixture.acceptedSuggestions == 1, "Option-Tab does not accept a suggestion")

        Self.sendTab(window, modifiers: [.shift])
        #expect(fixture.acceptedSuggestions == 1, "Shift-Tab with a menu open is left to AppKit")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }

    private static func sendTab(_ window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ) else { Issue.record("could not create Tab event"); return }
        NSApp.postEvent(event, atStart: true)
        guard let queued = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true) else {
            Issue.record("Tab event was not queued")
            return
        }
        NSApp.sendEvent(queued)
    }
}
#endif
