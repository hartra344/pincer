#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class TipsBackgroundAction: NSObject {
    var count = 0
    @objc func fire(_ sender: Any?) { self.count += 1 }
}

private final class FocusableTipsButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

private struct TipsBackgroundButton: NSViewRepresentable {
    let action: TipsBackgroundAction
    func makeNSView(context: Context) -> NSButton {
        let button = FocusableTipsButton(title: "Background Send", target: self.action,
                                         action: #selector(TipsBackgroundAction.fire(_:)))
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {}
}

@MainActor
private struct TipsPresentationHost: View {
    let tips: TipsModel
    let backgroundAction: TipsBackgroundAction

    var body: some View {
        TipsBackgroundButton(action: self.backgroundAction)
            .frame(width: 140, height: 32)
            .modifier(TipsPresentation(tips: self.tips, isCompact: false))
            .frame(width: 520, height: 420)
    }
}

/// The existing full-window Tips surface must own keyboard focus like a native sheet, so Return,
/// Escape and VoiceOver navigation cannot operate controls behind the card.
@MainActor
@Suite("Tips native presentation", .serialized)
struct TipsPresentationTests {
    @Test func tipsTakeKeyboardOwnershipAndReturnDismissesWithoutActivatingBackground() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        let background = TipsBackgroundAction()
        let host = NSHostingView(rootView: TipsPresentationHost(tips: tips, backgroundAction: background))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layout()
        defer { window.close() }

        let backgroundButton = try #require(Self.descendants(of: host).compactMap { $0 as? NSButton }
            .first { $0.title == "Background Send" })
        #expect(window.makeFirstResponder(backgroundButton), "the background button has focus before Tips appear")
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPresented)

        let presented = await eventually(timeout: .seconds(10)) { window.attachedSheet != nil }
        #expect(presented, "Tips are presented in an attached native sheet")
        guard presented, let sheet = window.attachedSheet else { return }
        #expect(sheet.isKeyWindow, "the sheet owns keyboard focus")
        #expect(NSApp.keyWindow === sheet, "key events are routed to Tips rather than the composer behind it")

        let imagePath = Self.writeSheetSnapshot(sheet)
        print("Tips native sheet snapshot: \(imagePath)")

        Self.sendKey(keyCode: 36, characters: "\r")
        let dismissed = await eventually(timeout: .seconds(10)) { window.attachedSheet == nil }
        #expect(dismissed, "Return invokes the sheet's Got It default action")
        #expect(tips.hasSeen && scratch.defaults.bool(forKey: SetupTips.seenKey), "dismissing Tips records that they were seen")
        #expect(background.count == 0, "Return never activates the default action behind the sheet")
    }

    @Test func escapeDismissesTheSheetAndRecordsTheTips() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        let background = TipsBackgroundAction()
        let host = NSHostingView(rootView: TipsPresentationHost(tips: tips, backgroundAction: background))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layout()
        defer { window.close() }

        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        let presented = await eventually(timeout: .seconds(10)) { window.attachedSheet != nil }
        #expect(presented, "Tips are presented in an attached native sheet")
        guard presented else { return }

        Self.sendKey(keyCode: 53, characters: "\u{1b}")
        let dismissed = await eventually(timeout: .seconds(10)) { window.attachedSheet == nil }
        #expect(dismissed, "Escape dismisses the tips sheet")
        #expect(tips.hasSeen && scratch.defaults.bool(forKey: SetupTips.seenKey), "Escape records that Tips were seen")
        #expect(background.count == 0, "Escape does not activate the control behind Tips")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }

    private static func sendKey(keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { Issue.record("could not create key event"); return }
        NSApp.sendEvent(event)
    }

    private static func writeSheetSnapshot(_ sheet: NSWindow) -> String {
        guard let view = sheet.contentView,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: max(Int(view.bounds.width), 1), pixelsHigh: max(Int(view.bounds.height), 1),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return "(sheet snapshot unavailable)" }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-tips-sheet-\(UUID().uuidString).png")
        guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: path)) != nil else {
            return "(sheet snapshot write failed)"
        }
        return path.path
    }
}
#endif
