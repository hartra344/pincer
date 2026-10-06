import CoreGraphics

/// Height rules for the composer's native text field, which measures itself on the main
/// thread in the same layout pass as the text change.
public enum ComposerSizing {
    /// Above this many UTF-16 units the field skips layout and reports its full capped height.
    /// That is exact unless one capped line holds more than `threshold / maxLines` characters
    /// (about 1,700 at 12 lines), which no real composer width reaches.
    public static let cappedEstimateThreshold = 20000

    public static func usesCappedEstimate(utf16Count: Int) -> Bool {
        utf16Count > self.cappedEstimateThreshold
    }

    /// The tallest the field grows before it scrolls.
    public static func cap(lineHeight: CGFloat, maxLines: Int) -> CGFloat {
        ceil(lineHeight * CGFloat(max(1, maxLines)))
    }

    /// A measured text height clamped to between one line and `maxLines` lines, rounded up to whole points.
    public static func clampedHeight(_ measured: CGFloat, lineHeight: CGFloat, maxLines: Int) -> CGFloat {
        let measured = measured.isFinite ? measured : 0
        return min(ceil(max(lineHeight, measured)), self.cap(lineHeight: lineHeight, maxLines: maxLines))
    }
}
