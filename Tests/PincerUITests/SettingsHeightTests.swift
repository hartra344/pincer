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
