import CoreGraphics
import PincerKit

@MainActor
func runComposerSizingChecks() {
    check(ComposerSizing.cappedEstimateThreshold == 20000, "composer capped-estimate threshold is 20,000 UTF-16 units")
    check(!ComposerSizing.usesCappedEstimate(utf16Count: 20000) && ComposerSizing.usesCappedEstimate(utf16Count: 20001),
          "drafts skip layout only above the threshold")
    check(ComposerSizing.cap(lineHeight: 16, maxLines: 12) == 192 && ComposerSizing.cap(lineHeight: 15.4, maxLines: 12) == 185,
          "composer cap is the rounded-up line height times max lines")
    check(ComposerSizing.cap(lineHeight: 16, maxLines: 0) == 16 && ComposerSizing.cap(lineHeight: 16, maxLines: 1) == 16,
          "composer cap never drops below one line")
    check(ComposerSizing.clampedHeight(0, lineHeight: 16, maxLines: 12) == 16
          && ComposerSizing.clampedHeight(48.2, lineHeight: 16, maxLines: 12) == 49
          && ComposerSizing.clampedHeight(10_000, lineHeight: 16, maxLines: 12) == 192,
          "measured composer height is clamped between one line and the cap, rounded up")
    check(ComposerSizing.clampedHeight(.nan, lineHeight: 16, maxLines: 12) == 16
          && ComposerSizing.clampedHeight(.infinity, lineHeight: 16, maxLines: 12) == 16,
          "non-finite composer measurements fall back to one line")
}
