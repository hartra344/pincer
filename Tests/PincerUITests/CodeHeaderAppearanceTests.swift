#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #264: an unchanged Copy title used to keep its child view's old theme pixels. Appearance
/// invalidation must reach the independently drawn header buttons on a reused code card.
@MainActor
@Suite("Code header appearance", .serialized)
struct CodeHeaderAppearanceTests {
    @Test func unchangedCodeHeaderRedrawsButtonsWithoutResettingCopiedState() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let defaults = UserDefaults.standard
        let accentKey = ThemeRole.accent.storageKey
        let previousAccent = defaults.object(forKey: accentKey)
        defer {
            if let previousAccent { defaults.set(previousAccent, forKey: accentKey) }
            else { defaults.removeObject(forKey: accentKey) }
            AppTheme.invalidateCache()
        }
        defaults.set("CC3300", forKey: accentKey)
        AppTheme.invalidateCache()
        let initialTheme = AppTheme.current
        #expect(initialTheme.value(.accent) == ThemeColor(hex: "CC3300"))
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:code:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "code", name: "Code"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let renderer = TranscriptRenderer(context: context)
        var turn = AssistantTurn(id: "html-reply", timestamp: Date(timeIntervalSince1970: 1))
        let source = "<h1>Preview me</h1>"
        turn.text = ["```html\n\(source)\n```"]
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: 700)
        let row = TranscriptRowView(frame: CGRect(x: 0, y: 0, width: 700, height: layout.height))
        row.apply(layout, actions: renderer)
        let code = try #require(row.subviews.compactMap { $0 as? TranscriptCodeView }.first)
        let buttons = code.subviews.compactMap { $0 as? TranscriptLabelButton }.filter { !$0.isHidden }
        let copy = try #require(buttons.first { $0.accessibilityText == L("Copy") })
        let preview = try #require(buttons.first { $0.accessibilityText == L("Preview") })
        #expect(code.extraCopyItems.first?.text == source)
        let copyLayer = try #require(copy.layer)
        let previewLayer = try #require(preview.layer)
        copyLayer.displayIfNeeded()
        previewLayer.displayIfNeeded()
        #expect(!copyLayer.needsDisplay() && !previewLayer.needsDisplay())

        // Both content and titles are identical on the next configuration. A theme event must
        // update the child buttons' cached drawing, since redrawing only the parent keeps old pixels.
        defaults.set("008844", forKey: accentKey)
        AppTheme.invalidateCache()
        let changedTheme = AppTheme.current
        #expect(changedTheme.value(.accent) == ThemeColor(hex: "008844"))
        #expect(changedTheme != initialTheme, "the test must activate a distinct theme before checking redraw")
        row.apply(layout, actions: renderer)
        #expect(copyLayer.needsDisplay() && previewLayer.needsDisplay(), "both buttons must invalidate their cached tint")
        #expect(copy.accessibilityText == L("Copy") && preview.accessibilityText == L("Preview"))

        copyLayer.displayIfNeeded()
        previewLayer.displayIfNeeded()
        // This is the same feedback state the real Copy action displays, without writing to
        // the user's pasteboard. A tint refresh must preserve it until its own reset fires.
        copy.set(title: L("Copied"), symbol: "checkmark")
        copyLayer.displayIfNeeded()
        previewLayer.displayIfNeeded()
        defaults.set("3344CC", forKey: accentKey)
        AppTheme.invalidateCache()
        let copiedTheme = AppTheme.current
        #expect(copiedTheme.value(.accent) == ThemeColor(hex: "3344CC"))
        #expect(copiedTheme != changedTheme, "the test must activate another distinct theme before checking redraw")
        row.apply(layout, actions: renderer)
        #expect(copyLayer.needsDisplay() && previewLayer.needsDisplay())
        #expect(copy.accessibilityText == L("Copied"), "refreshing tint must not reset copy feedback")
        #expect(code.extraCopyItems.first?.text == source, "theme changes preserve the exact copy payload")
    }
}
#endif
