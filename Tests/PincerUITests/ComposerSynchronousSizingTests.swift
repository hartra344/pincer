import Foundation
import Observation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
private final class ComposerSizingFixture {
    var text = ""
    var width: CGFloat = 360
}

@MainActor
private struct ComposerSizingHost: View {
    @Bindable var fixture: ComposerSizingFixture
    var body: some View {
        ComposerTextView(
            placeholder: "Message", text: self.$fixture.text, maxLines: 12,
            onSubmit: {}, onMedia: { _ in }, autoFocus: { false })
            .frame(width: self.fixture.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private let sizingMaxLines = 12
private let wrapSentence = "The quick brown fox jumps over the lazy dog while the composer keeps measuring every word it is given today."

private func repeated(_ line: String, count: Int) -> String {
    Array(repeating: line, count: count).joined(separator: "\n")
}

#if os(macOS)
@MainActor
private final class SizingRig {
    let fixture = ComposerSizingFixture()
    let host: NSHostingView<ComposerSizingHost>
    let window: NSWindow

    init(text: String = "") {
        self.fixture.text = text
        self.host = NSHostingView(rootView: ComposerSizingHost(fixture: self.fixture))
        self.host.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        self.window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 700),
                               styleMask: [.titled], backing: .buffered, defer: false)
        self.window.isReleasedWhenClosed = false
        self.window.contentView = self.host
        self.window.orderFront(nil)
    }

    deinit { MainActor.assumeIsolated { self.window.close() } }

    var native: ComposerNSTextView? { Self.find(in: self.host) }
    var height: CGFloat { self.native?.enclosingScrollView?.frame.height ?? -1 }
    func layout() { self.host.layoutSubtreeIfNeeded() }

    private static func find(in view: NSView) -> ComposerNSTextView? {
        if let found = view as? ComposerNSTextView { return found }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }
    static func lines(_ n: Int) -> CGFloat {
        ComposerSizing.clampedHeight(lineHeight * CGFloat(n), lineHeight: lineHeight, maxLines: sizingMaxLines)
    }
    static func wrapped(_ text: String, width: CGFloat) -> CGFloat {
        let rect = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ComposerSizing.clampedHeight(rect.height, lineHeight: lineHeight, maxLines: sizingMaxLines)
    }
}

@MainActor
@Suite("Composer synchronous sizing (AppKit)", .serialized)
struct ComposerSynchronousSizingAppKitTests {
    private func settle(_ rig: SizingRig) throws {
        rig.layout()
        _ = try #require(rig.native, "the hosted composer creates its native text view")
    }

    @Test func draftRestoreSizesInFirstPass() throws {
        let rig = SizingRig(text: "a\nb\nc\nd")
        try settle(rig)
        #expect(abs(rig.height - SizingRig.lines(4)) <= 1, "height \(rig.height)")
    }

    @Test func typingNewlinesGrowsInOnePass() throws {
        let rig = SizingRig(text: "hello")
        try settle(rig)
        #expect(abs(rig.height - SizingRig.lines(1)) <= 1)
        rig.fixture.text = "hello\n"
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(2)) <= 1, "trailing newline counts: \(rig.height)")
        rig.fixture.text = "hello\nworld"
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(2)) <= 1)
        rig.fixture.text = "hello\nworld\n!"
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(3)) <= 1)
    }

    @Test func wrappingSizesInOnePass() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = wrapSentence
        rig.layout()
        let expected = SizingRig.wrapped(wrapSentence, width: 360)
        #expect(expected > SizingRig.lines(1), "fixture sentence wraps")
        #expect(abs(rig.height - expected) <= 1, "height \(rig.height), expected \(expected)")
    }

    @Test func pasteCapsInOnePass() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = repeated("pasted line", count: 40)
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(sizingMaxLines)) <= 1, "height \(rig.height)")
    }

    @Test func pathologicalPasteCapsImmediately() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = String(repeating: "x", count: 30_000)
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(sizingMaxLines)) <= 1, "height \(rig.height)")
    }

    @Test func widthChangeResizesInOnePass() throws {
        let rig = SizingRig(text: wrapSentence)
        try settle(rig)
        #expect(abs(rig.height - SizingRig.wrapped(wrapSentence, width: 360)) <= 1)
        rig.fixture.width = 200
        rig.layout()
        let narrow = SizingRig.wrapped(wrapSentence, width: 200)
        #expect(narrow > SizingRig.wrapped(wrapSentence, width: 360))
        #expect(abs(rig.height - narrow) <= 1, "height \(rig.height), expected \(narrow)")
        rig.fixture.width = 360
        rig.layout()
        #expect(abs(rig.height - SizingRig.wrapped(wrapSentence, width: 360)) <= 1)
    }

    /// With no trailing newline there is no extra line fragment, so a wide single line must stay one line.
    @Test func wideSingleLineStaysOneLine() throws {
        let rig = SizingRig()
        rig.fixture.width = 608
        try settle(rig)
        let line = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over"
        for count in [66, 70, line.count] {
            rig.fixture.text = String(line.prefix(count))
            rig.layout()
            #expect(abs(rig.height - SizingRig.lines(1)) <= 1, "\(count) chars: height \(rig.height)")
        }
        let three = repeated(String(line.prefix(77)), count: 3)
        rig.fixture.text = three
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(3)) <= 1, "three lines: height \(rig.height)")
        rig.fixture.text = three + "\n"
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(4)) <= 1, "trailing newline: height \(rig.height)")
    }

    @Test func clearingReturnsToOneLine() throws {
        let rig = SizingRig(text: repeated("line", count: 6))
        try settle(rig)
        #expect(abs(rig.height - SizingRig.lines(6)) <= 1)
        rig.fixture.text = ""
        rig.layout()
        #expect(abs(rig.height - SizingRig.lines(1)) <= 1, "height \(rig.height)")
    }

    @Test func synchronousMeasurementStaysWithinBudget() throws {
        let rig = SizingRig()
        try settle(rig)
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 4)
        let draft = Array(repeating: paragraph, count: 16).joined(separator: "\n\n")
        #expect(draft.utf16.count > 3_500 && draft.utf16.count < ComposerSizing.cappedEstimateThreshold)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            rig.fixture.text = draft
            rig.layout()
        }
        #expect(abs(rig.height - SizingRig.lines(sizingMaxLines)) <= 1)
        #expect(elapsed < PerfBudget.limit(.milliseconds(16)), "type + one layout pass took \(elapsed)")
    }
}
#elseif os(iOS)
@MainActor
private final class SizingRig {
    let fixture = ComposerSizingFixture()
    let controller: UIHostingController<ComposerSizingHost>
    let window: UIWindow

    init(text: String = "") {
        self.fixture.text = text
        self.controller = UIHostingController(rootView: ComposerSizingHost(fixture: self.fixture))
        self.window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        self.window.rootViewController = self.controller
        self.window.makeKeyAndVisible()
    }

    deinit { MainActor.assumeIsolated { self.window.isHidden = true } }

    var native: ComposerUITextView? { Self.find(in: self.controller.view) }
    var height: CGFloat { self.native?.frame.height ?? -1 }
    func layout() {
        self.controller.view.setNeedsLayout()
        self.controller.view.layoutIfNeeded()
    }

    private static func find(in view: UIView) -> ComposerUITextView? {
        if let found = view as? ComposerUITextView { return found }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    static let font = UIFont.preferredFont(forTextStyle: .body)
    /// The laid-out height of one line, as the composer's floor and cap use it.
    static var lineHeight: CGFloat {
        ceil(NSAttributedString(string: "X", attributes: [.font: font])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }
    /// Vertical text-container insets of the live view, which the iOS height includes.
    var verticalInsets: CGFloat {
        guard let native else { return 0 }
        return native.textContainerInset.top + native.textContainerInset.bottom
    }
    /// UITextView lays lines out taller than `UIFont.lineHeight`, so n lines are measured with TextKit.
    func lines(_ n: Int) -> CGFloat {
        self.wrapped(Array(repeating: "x", count: n).joined(separator: "\n"), width: 10_000)
    }
    func wrapped(_ text: String, width: CGFloat) -> CGFloat {
        let padding = (self.native?.textContainer.lineFragmentPadding ?? 0) * 2
        let insets = (self.native?.textContainerInset.left ?? 0) + (self.native?.textContainerInset.right ?? 0)
        let rect = NSAttributedString(string: text, attributes: [.font: Self.font])
            .boundingRect(with: CGSize(width: width - padding - insets, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return self.verticalInsets + ComposerSizing.clampedHeight(rect.height, lineHeight: Self.lineHeight, maxLines: sizingMaxLines)
    }
}

@MainActor
@Suite("Composer synchronous sizing (UIKit)", .serialized)
struct ComposerSynchronousSizingUIKitTests {
    private func settle(_ rig: SizingRig) throws {
        rig.layout()
        _ = try #require(rig.native, "the hosted composer creates its native text view")
    }

    @Test func draftRestoreSizesInFirstPass() throws {
        let rig = SizingRig(text: "a\nb\nc\nd")
        try settle(rig)
        #expect(abs(rig.height - rig.lines(4)) <= 1, "height \(rig.height)")
    }

    @Test func typingNewlinesGrowsInOnePass() throws {
        let rig = SizingRig(text: "hello")
        try settle(rig)
        #expect(abs(rig.height - rig.lines(1)) <= 1)
        rig.fixture.text = "hello\n"
        rig.layout()
        #expect(abs(rig.height - rig.lines(2)) <= 1, "trailing newline counts: \(rig.height)")
        rig.fixture.text = "hello\nworld"
        rig.layout()
        #expect(abs(rig.height - rig.lines(2)) <= 1)
    }

    @Test func wrappingSizesInOnePass() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = wrapSentence
        rig.layout()
        let expected = rig.wrapped(wrapSentence, width: 360)
        #expect(expected > rig.lines(1), "fixture sentence wraps")
        #expect(abs(rig.height - expected) <= 1, "height \(rig.height), expected \(expected)")
    }

    @Test func pasteCapsInOnePass() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = repeated("pasted line", count: 40)
        rig.layout()
        #expect(abs(rig.height - rig.lines(sizingMaxLines)) <= 1, "height \(rig.height)")
    }

    @Test func firstCharacterKeepsTheEmptyHeight() throws {
        let rig = SizingRig()
        try settle(rig)
        let empty = rig.height
        #expect(abs(empty - SizingRig.lineHeight) <= 1, "empty height \(empty)")
        rig.fixture.text = "a"
        rig.layout()
        #expect(rig.height == empty, "empty \(empty) -> one character \(rig.height)")
    }

    @Test func twelveLinesFitUnclippedAndThirteenCap() throws {
        let rig = SizingRig()
        try settle(rig)
        let cap = ComposerSizing.cap(lineHeight: SizingRig.lineHeight, maxLines: sizingMaxLines)
        let laidOut = rig.wrapped(Array(repeating: "x", count: 12).joined(separator: "\n"), width: 10_000)
        #expect(abs(laidOut - cap) <= 1, "12 laid-out lines \(laidOut) vs cap \(cap)")
        rig.fixture.text = repeated("x", count: 12)
        rig.layout()
        #expect(abs(rig.height - cap) <= 1 && rig.height >= laidOut - 0.01, "12 lines: height \(rig.height), laid out \(laidOut), cap \(cap)")
        rig.fixture.text = repeated("x", count: 13)
        rig.layout()
        #expect(abs(rig.height - cap) <= 1, "13 lines: height \(rig.height), cap \(cap)")
    }

    @Test func pathologicalPasteCapsImmediately() throws {
        let rig = SizingRig()
        try settle(rig)
        rig.fixture.text = String(repeating: "x", count: 30_000)
        rig.layout()
        #expect(abs(rig.height - rig.lines(sizingMaxLines)) <= 1, "height \(rig.height)")
    }

    @Test func widthChangeResizesInOnePass() throws {
        let rig = SizingRig(text: wrapSentence)
        try settle(rig)
        #expect(abs(rig.height - rig.wrapped(wrapSentence, width: 360)) <= 1)
        rig.fixture.width = 200
        rig.layout()
        let narrow = rig.wrapped(wrapSentence, width: 200)
        #expect(narrow > rig.wrapped(wrapSentence, width: 360))
        #expect(abs(rig.height - narrow) <= 1, "height \(rig.height), expected \(narrow)")
        rig.fixture.width = 360
        rig.layout()
        #expect(abs(rig.height - rig.wrapped(wrapSentence, width: 360)) <= 1)
    }

    @Test func clearingReturnsToOneLine() throws {
        let rig = SizingRig(text: repeated("line", count: 6))
        try settle(rig)
        #expect(abs(rig.height - rig.lines(6)) <= 1)
        rig.fixture.text = ""
        rig.layout()
        #expect(abs(rig.height - rig.lines(1)) <= 1, "height \(rig.height)")
    }

    @Test func synchronousMeasurementStaysWithinBudget() throws {
        let rig = SizingRig()
        try settle(rig)
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 4)
        let draft = Array(repeating: paragraph, count: 16).joined(separator: "\n\n")
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            rig.fixture.text = draft
            rig.layout()
        }
        #expect(abs(rig.height - rig.lines(sizingMaxLines)) <= 1)
        #expect(elapsed < PerfBudget.limit(.milliseconds(50)), "type + one layout pass took \(elapsed)")
    }
}
#endif
