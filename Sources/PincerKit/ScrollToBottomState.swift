import CoreGraphics

/// When the chat's scroll-to-bottom button shows, and whether messages arrived below while the
/// reader was scrolled up. The transcript list reports its position after every scroll and update.
///
/// The button appears once the reader is more than half a screen from the latest message, and
/// hides only once they're back within the stick-to-bottom distance, so it doesn't flicker at the
/// edge of either threshold.
public struct ScrollToBottomState: Equatable, Sendable {
    /// Within this distance of the end the list follows new content (`TranscriptLayout.stickToBottomDistance`).
    public static let defaultStickDistance: CGFloat = 80

    public private(set) var isVisible = false
    /// A new last row arrived while the button was showing.
    public private(set) var hasNewMessages = false
    private var lastRowId: String?

    public init() {}

    /// How far from the bottom the button appears, for a viewport of `viewport` points.
    public static func showDistance(viewport: CGFloat, stickDistance: CGFloat = defaultStickDistance) -> CGFloat {
        max(stickDistance, viewport / 2)
    }

    /// - Parameters:
    ///   - distance: How far the viewport's bottom edge is above the end of the content.
    ///   - viewport: The visible height, without the chrome floating over the list.
    ///   - lastRowId: The id of the transcript's last row.
    public mutating func update(distance: CGFloat, viewport: CGFloat, lastRowId: String?,
                                stickDistance: CGFloat = defaultStickDistance) {
        let previousLast = self.lastRowId
        self.lastRowId = lastRowId
        if viewport <= 0 || lastRowId == nil || distance <= stickDistance {
            self.isVisible = false
        } else if distance > Self.showDistance(viewport: viewport, stickDistance: stickDistance) {
            self.isVisible = true
        }
        if !self.isVisible {
            self.hasNewMessages = false
        } else if let previousLast, previousLast != lastRowId {
            self.hasNewMessages = true
        }
    }
}
