import Testing
@testable import PincerKit

@Suite("Settings content height policy")
struct SettingsContentHeightTests {
    @Test func followsDisplaySpaceAndRecoversAfterMovingBack() {
        #expect(SettingsContentHeight.limit(visibleScreenHeight: 900) == 720)
        #expect(SettingsContentHeight.limit(visibleScreenHeight: 600) == 460)
        #expect(SettingsContentHeight.limit(visibleScreenHeight: 900) == 720)
    }

    @Test func missingDisplayAndSmallScreensKeepExistingBounds() {
        #expect(SettingsContentHeight.limit(visibleScreenHeight: nil) == 720)
        #expect(SettingsContentHeight.limit(visibleScreenHeight: 300) == 240)
        #expect(SettingsContentHeight.limit(visibleScreenHeight: 2000) == 720)
    }
}
