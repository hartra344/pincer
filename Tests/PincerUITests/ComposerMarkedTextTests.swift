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
private final class ComposerMarkedTextFixture {
    var text = ""
    var menuActive = false
}

@MainActor
private struct ComposerMarkedTextHost: View {
    @Bindable var fixture: ComposerMarkedTextFixture

    var body: some View {
        ComposerTextView(
            placeholder: "Message", text: self.$fixture.text, menuActive: self.fixture.menuActive,
            onSubmit: {}, onMedia: { _ in }, autoFocus: { false })
            .frame(width: 240, height: 50)
    }
}

/// IME composition (Chinese/Japanese/Korean input) goes through `setMarkedText` and commits through
/// `insertText` + `unmarkText`, paths that some IMEs never surface as `didChangeText`/`textDidChange`.
/// The composer must keep the SwiftUI binding following the view during composition, and a SwiftUI
/// re-render must not reset the field from the (older) binding and tear the composition down.
@MainActor
@Suite("Composer marked text", .serialized)
struct ComposerMarkedTextTests {
    @Test func compositionSurvivesRendersAndCommits() async throws {
        let fixture = ComposerMarkedTextFixture()
        let host = NSHostingView(rootView: ComposerMarkedTextHost(fixture: fixture))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 50)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 240, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layout()
        defer { window.close() }

        let textView = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerNSTextView }.first)
        #expect(window.makeFirstResponder(textView), "the composer accepts keyboard focus")

        // Type "ni" through the input client path, exactly as a pinyin IME does.
        textView.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText(), "the marked range is live")
        #expect(fixture.text == "ni", "the binding follows the composition as it grows")

        // Any SwiftUI re-render while composing (menu toggle, timer, store publish…) must not
        // reset the field from the stale binding; pre-fix this wiped the composition on every keystroke.
        fixture.menuActive = true
        host.layout()
        #expect(textView.string == "ni", "a re-render keeps the marked text in the view")
        #expect(textView.hasMarkedText(), "a re-render does not end the composition")
        fixture.menuActive = false
        host.layout()

        // Commit "你" over the marked range and end the composition, as the IME does.
        textView.insertText("你", replacementRange: NSRange(location: 0, length: 2))
        textView.unmarkText()
        #expect(!textView.hasMarkedText())
        #expect(textView.string == "你", "the committed text lands in the view")
        #expect(fixture.text == "你", "the binding sees the committed text")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
#endif
