import Testing
@testable import PincerUI

/// The Runs toolbar button on a compact iPhone shows only while the panel is open or helpers are running (#180).
@Suite("Runs toolbar visibility")
struct RunsToolbarVisibilityTests {
    @Test func regularWidthAlwaysShows() {
        for presented in [false, true] {
            for running in [0, 3] {
                #expect(RunsToolbarVisibility.shows(isCompact: false, isPresented: presented, running: running))
            }
        }
    }

    @Test func compactShowsOnlyWhenPresentedOrRunning() {
        #expect(!RunsToolbarVisibility.shows(isCompact: true, isPresented: false, running: 0))
        #expect(RunsToolbarVisibility.shows(isCompact: true, isPresented: true, running: 0))
        #expect(RunsToolbarVisibility.shows(isCompact: true, isPresented: false, running: 1))
        #expect(RunsToolbarVisibility.shows(isCompact: true, isPresented: true, running: 2))
    }
}
