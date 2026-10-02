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
@Suite(.serialized)
struct APIKeyVisibilityTests {
    @Observable final class Editor {
        var text = "test_MiXeD+/=:@."
        var disabled = false
        var submissions = 0
    }

    struct Content: View {
        @Bindable var editor: Editor
        var body: some View {
            APIKeyField(title: "API key", prompt: "Paste API key", text: self.$editor.text,
                        onSubmit: { self.editor.submissions += 1 })
                .disabled(self.editor.disabled)
                .padding()
        }
    }

    #if os(macOS)
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }

    @Test func nativeEditorOffersShowAndHideWithoutChangingKey() async throws {
        _ = NSApplication.shared
        let editor = Editor()
        let host = NSHostingView(rootView: Content(editor: editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let offered = await eventually(timeout: .seconds(2)) {
            host.layoutSubtreeIfNeeded()
            return Self.descendants(host).contains { ($0 as? NSButton)?.identifier?.rawValue == "api-key-visibility" }
        }
        try #require(offered, "API-key input needs an accessible native show/hide control")
        let button = try #require(Self.descendants(host).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "api-key-visibility" })
        #expect(button.isEnabled)
        #expect(Self.descendants(host).contains { $0 is NSSecureTextField })
        let secure = try #require(Self.descendants(host).compactMap { $0 as? NSSecureTextField }.first)
        #expect(!secure.isHidden)
        try #require(await eventually {
            host.layoutSubtreeIfNeeded()
            return secure.frame.width > 0 && button.frame.width > 0
        }, "The native fixture has laid out its input and visibility control")
        let maskedFrame = secure.frame
        #expect(abs(maskedFrame.maxX + 6 - button.frame.minX) < 1,
                "The masked field uses the full input slot without a hidden-field gap: \(maskedFrame), \(button.frame)")
        try #require(window.makeFirstResponder(secure), "the fixture can focus the secure editor")
        secure.selectText(nil)
        let secureEditor = try #require(secure.currentEditor())
        secureEditor.selectedRange = NSRange(location: 4, length: 3)
        let revealLabel = button.accessibilityLabel()
        button.performClick(nil)
        let revealed = await eventually {
            Self.descendants(host).compactMap { $0 as? NSTextField }.contains {
                !($0 is NSSecureTextField) && !$0.isHidden && $0.isEditable && $0.stringValue == editor.text
            }
        }
        #expect(revealed, "Show displays the actual key text in a plain editor")
        #expect(editor.text == "test_MiXeD+/=:@.")
        let plain = try #require(Self.descendants(host).compactMap { $0 as? NSTextField }.first {
            !($0 is NSSecureTextField) && !$0.isHidden && $0.isEditable && $0.stringValue == editor.text
        })
        try #require(await eventually {
            host.layoutSubtreeIfNeeded()
            return plain.frame.width > 0
        })
        #expect(abs(plain.frame.width - maskedFrame.width) < 1
                && abs(plain.frame.minX - maskedFrame.minX) < 1,
                "Reveal keeps the same full-width input slot")
        #expect(!(plain.cell is NSSecureTextFieldCell), "Reveal uses a plain cell rather than suppressing secure-field bullets")
        let plainEditor = try #require(plain.currentEditor() as? NSTextView)
        #expect(!plainEditor.isAutomaticSpellingCorrectionEnabled && !plainEditor.isAutomaticTextReplacementEnabled,
                "Revealing an API key must not allow spelling or text replacement to change its bytes")
        #expect(!plainEditor.isAutomaticQuoteSubstitutionEnabled && !plainEditor.isAutomaticDashSubstitutionEnabled)
        #expect(plain.currentEditor()?.selectedRange == NSRange(location: 4, length: 3),
                "Reveal preserves focus and the editor selection")
        #expect(button.accessibilityLabel() != revealLabel)
        button.performClick(nil)
        let hidden = await eventually {
            Self.descendants(host).compactMap { $0 as? NSSecureTextField }.contains { !$0.isHidden && $0.stringValue == editor.text }
        }
        #expect(hidden)
        #expect(secure.currentEditor()?.selectedRange == NSRange(location: 4, length: 3),
                "Hide restores focus and selection to the secure editor")
        #expect(button.accessibilityLabel() == revealLabel)
        #expect(editor.submissions == 0, "Show/hide never submits the key")
        let action = try #require(secure.action)
        #expect(secure.sendAction(action, to: secure.target))
        #expect(editor.submissions == 1, "Return submission still reaches the original callback")
        editor.disabled = true
        #expect(await eventually { !button.isEnabled })
    }
    #else
    static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }

    static func click(_ button: UIButton) -> Int {
        var count = 0
        for target in button.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in button.actions(forTarget: object, forControlEvent: .touchUpInside) ?? [] {
                _ = object.perform(NSSelectorFromString(action), with: button)
                count += 1
            }
        }
        return count
    }

    func nativeEditorOffersShowAndHideWithoutChangingKey() async throws {
        let editor = Editor()
        let host = UIHostingController(rootView: Content(editor: editor))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 250))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let offered = await eventually(timeout: .seconds(2)) {
            host.view.layoutIfNeeded()
            return Self.descendants(host.view).contains { ($0 as? UIButton)?.accessibilityIdentifier == "api-key-visibility" }
        }
        try #require(offered, "API-key input needs an accessible native show/hide control")
        let button = try #require(Self.descendants(host.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "api-key-visibility" })
        let field = try #require(Self.descendants(host.view).compactMap { $0 as? UITextField }.first)
        #expect(field.accessibilityLabel == "API key" && !field.superview!.isAccessibilityElement,
                "The input and eye retain separate native accessibility elements")
        #expect(field.isSecureTextEntry)
        let start = try #require(field.position(from: field.beginningOfDocument, offset: 4))
        let end = try #require(field.position(from: start, offset: 3))
        field.selectedTextRange = field.textRange(from: start, to: end)
        let label = button.accessibilityLabel
        #expect(Self.click(button) > 0)
        #expect(await eventually { !field.isSecureTextEntry })
        #expect(field.text == editor.text && editor.text == "test_MiXeD+/=:@.")
        #expect(field.textContentType == .oneTimeCode && field.passwordRules == nil)
        #expect(field.autocapitalizationType == .none && field.autocorrectionType == .no)
        let revealedSelection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: revealedSelection.start) == 4
                && field.offset(from: revealedSelection.start, to: revealedSelection.end) == 3)
        #expect(button.accessibilityLabel != label)
        #expect(Self.click(button) > 0)
        #expect(await eventually { field.isSecureTextEntry })
        let hiddenSelection = try #require(field.selectedTextRange)
        #expect(field.offset(from: field.beginningOfDocument, to: hiddenSelection.start) == 4
                && field.offset(from: hiddenSelection.start, to: hiddenSelection.end) == 3)
        #expect(button.accessibilityLabel == label)
        #expect(Self.descendants(host.view).compactMap { $0 as? UITextField }.first === field)
        #expect(editor.submissions == 0, "Show/hide never submits the key")
        try #require(field.becomeFirstResponder(), "the UIKit fixture can focus the input to expose its clear affordance")
        host.view.layoutIfNeeded()
        let clear = try #require(Self.descendants(field).compactMap { $0 as? UIButton }
            .first { $0 !== button && !$0.isHidden }, "the eye control preserves a visible clear button while editing")
        #expect(!field.convert(clear.bounds, from: clear).intersects(field.convert(button.bounds, from: button)),
                "the clear and visibility targets do not overlap")
        #expect(clear.isEnabled && field.clearButtonMode == .whileEditing)
        // This package test runner has no UIApplicationMain. Verify native clear geometry above,
        // then deliver the editingChanged state produced by clearing through the real target.
        field.text = ""
        var editingTargets = 0
        for target in field.allTargets {
            guard let object = target.base as? NSObject else { continue }
            for action in field.actions(forTarget: object, forControlEvent: .editingChanged) ?? [] {
                _ = object.perform(NSSelectorFromString(action), with: field)
                editingTargets += 1
            }
        }
        #expect(editingTargets > 0)
        #expect(await eventually { field.text?.isEmpty == true && editor.text.isEmpty },
                "the native editing target clears the actual bound draft")
        _ = field.delegate?.textFieldShouldReturn?(field)
        #expect(editor.submissions == 1)
        editor.disabled = true
        #expect(await eventually { !field.isEnabled && !button.isEnabled })
    }
    #endif
}

#if os(iOS)
extension TranscriptUIKitHostedTests {
    @Test func apiKeyVisibilityKeepsTheNativeBindingAndInputTraits() async throws {
        try await APIKeyVisibilityTests().nativeEditorOffersShowAndHideWithoutChangingKey()
    }
}
#endif
