#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

/// #285: every macOS Settings tab must fit the screen and scroll, instead of growing past it.
@MainActor
@Suite("Settings window height", .serialized)
struct SettingsHeightTests {
    @Test func attachedWindowDisplayChangeUpdatesTheExistingTabCap() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        var visibleHeight: CGFloat = 900
        let host = NSHostingView(rootView: SettingsForm(
            sections: SettingsForm.Section.generalTab,
            visibleScreenHeightProvider: { _ in visibleHeight })
            .environment(app).frame(width: 520))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        let shortCap = SettingsHeightCap.limit(visibleScreenHeight: 600)
        #expect(host.fittingSize.height > shortCap + 1, "the fixture must actually exceed the shorter display's cap")

        visibleHeight = 600
        let unrelated = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: unrelated)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(host.fittingSize.height > shortCap + 1, "a different window's screen event must not resize this tab")
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= shortCap + 1,
                "moving the existing Settings window to a shorter display must update its cap")
        visibleHeight = 900
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > shortCap + 1,
                "a visible-frame change can restore the same tab's larger height")
    }

    @Test func explicitHeightOverrideDoesNotReadOrFollowDisplayEvents() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        var reads = 0
        let host = NSHostingView(rootView: SettingsForm(
            sections: SettingsForm.Section.generalTab, maxHeight: 400,
            visibleScreenHeightProvider: { _ in reads += 1; return 900 })
            .environment(AppModel(defaults: scratch.defaults)).frame(width: 520))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        #expect(reads == 0)
        #expect(host.fittingSize.height <= 401)
    }

    static func height(of sections: [SettingsForm.Section], maxHeight: CGFloat, app: AppModel) -> CGFloat {
        let host = NSHostingView(rootView: SettingsForm(sections: sections, maxHeight: maxHeight)
            .environment(app)
            .frame(width: 520))
        host.layout()
        return host.fittingSize.height
    }

    @Test func everySectionIsOnATab() {
        #expect(Set(SettingsForm.Section.macTabs.joined()) == Set(SettingsForm.Section.available))
    }

    @Test func noTabGrowsPastAShortScreen() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        // A short display: 600pt visible leaves 460pt for the tab's content.
        let cap = SettingsHeightCap.limit(visibleScreenHeight: 600)
        for tab in SettingsForm.Section.macTabs {
            let height = Self.height(of: tab, maxHeight: cap, app: app)
            #expect(height <= cap + 1, "tab \(tab) is \(height)pt, past the \(cap)pt cap")
            #expect(height > 0)
        }
    }

    @Test func shortTabsStayCompact() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let short = Self.height(of: SettingsForm.Section.notificationsTab, maxHeight: 10_000, app: app)
        let tall = Self.height(of: SettingsForm.Section.generalTab, maxHeight: 10_000, app: app)
        #expect(short < tall, "Notifications (\(short)pt) should hug its content, not fill the cap")
        #expect(short < SettingsHeightCap.comfortableMax)
    }

    @Test func capAlwaysLeavesRoomForTheWindowChrome() {
        for visible in [500.0, 600, 768, 900, 1400] {
            let cap = SettingsHeightCap.limit(visibleScreenHeight: visible)
            #expect(cap + SettingsHeightCap.windowChrome <= max(visible, SettingsHeightCap.minimum + SettingsHeightCap.windowChrome))
            #expect(cap <= SettingsHeightCap.comfortableMax)
        }
    }
}
#endif
