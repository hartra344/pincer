import CoreGraphics
import Testing
@testable import PincerKit

/// #420: when the chat's scroll-to-bottom button shows, and its new-message dot.
@Suite("Scroll-to-bottom button")
struct ScrollToBottomStateTests {
    static let viewport: CGFloat = 600

    func state(at distances: [CGFloat], last: String? = "m1") -> ScrollToBottomState {
        var state = ScrollToBottomState()
        for distance in distances { state.update(distance: distance, viewport: Self.viewport, lastRowId: last) }
        return state
    }

    @Test("hidden at the bottom and within the stick distance")
    func hiddenNearBottom() {
        #expect(!self.state(at: [0]).isVisible)
        #expect(!self.state(at: [ScrollToBottomState.defaultStickDistance]).isVisible)
        #expect(!self.state(at: [-40]).isVisible, "overscroll past the end")
    }

    @Test("shows past half a screen, not before")
    func showsPastHalfAScreen() {
        let threshold = ScrollToBottomState.showDistance(viewport: Self.viewport)
        #expect(threshold == 300)
        #expect(!self.state(at: [threshold]).isVisible)
        #expect(self.state(at: [threshold + 1]).isVisible)
        #expect(self.state(at: [5000]).isVisible)
    }

    @Test("a short viewport still needs more than the stick distance")
    func shortViewport() {
        #expect(ScrollToBottomState.showDistance(viewport: 100) == ScrollToBottomState.defaultStickDistance)
        var state = ScrollToBottomState()
        state.update(distance: 81, viewport: 100, lastRowId: "m1")
        #expect(state.isVisible)
    }

    @Test("hysteresis: once shown, stays until back within the stick distance")
    func hysteresis() {
        #expect(self.state(at: [400, 200]).isVisible, "between the thresholds after showing")
        #expect(!self.state(at: [200]).isVisible, "between the thresholds from the bottom")
        #expect(!self.state(at: [400, 80]).isVisible)
        #expect(!self.state(at: [400, 0]).isVisible)
    }

    @Test("hidden with no rows or no viewport")
    func hiddenWithoutContent() {
        #expect(!self.state(at: [900], last: nil).isVisible)
        var state = self.state(at: [900])
        state.update(distance: 900, viewport: 0, lastRowId: "m1")
        #expect(!state.isVisible)
    }

    @Test("a new last row while scrolled up shows the dot; returning to the bottom clears it")
    func newMessageDot() {
        var state = ScrollToBottomState()
        state.update(distance: 900, viewport: Self.viewport, lastRowId: "m1")
        #expect(state.isVisible && !state.hasNewMessages)
        state.update(distance: 900, viewport: Self.viewport, lastRowId: "m1")
        #expect(!state.hasNewMessages, "streaming into the same row isn't a new message")
        state.update(distance: 1200, viewport: Self.viewport, lastRowId: "m2")
        #expect(state.hasNewMessages)
        state.update(distance: 500, viewport: Self.viewport, lastRowId: "m2")
        #expect(state.hasNewMessages, "stays until the reader reaches the bottom")
        state.update(distance: 0, viewport: Self.viewport, lastRowId: "m2")
        #expect(!state.isVisible && !state.hasNewMessages)
    }

    @Test("messages arriving while at the bottom don't show the dot later")
    func noDotForMessagesSeenAtBottom() {
        var state = ScrollToBottomState()
        state.update(distance: 0, viewport: Self.viewport, lastRowId: "m1")
        state.update(distance: 0, viewport: Self.viewport, lastRowId: "m2")
        state.update(distance: 900, viewport: Self.viewport, lastRowId: "m2")
        #expect(state.isVisible && !state.hasNewMessages)
    }
}
