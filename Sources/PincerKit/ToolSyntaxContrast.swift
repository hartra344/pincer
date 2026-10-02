import Foundation

/// Bounded sRGB contrast adjustment for the five syntax token colors used in tool cards.
public enum ToolSyntaxContrast {
    /// Returns the WCAG contrast ratio for two packed 0xRRGGBB sRGB colors.
    public static func ratio(foreground: UInt32, background: UInt32) -> Double {
        let a = Self.luminance(foreground)
        let b = Self.luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Retains a readable palette color, otherwise shifts it toward the better black/white endpoint.
    /// A high-contrast target can be impossible on mid-tones; in that case this returns the endpoint
    /// with the greatest achievable contrast instead of claiming the target was met.
    public static func foreground(_ foreground: UInt32, on background: UInt32, increased: Bool = false) -> UInt32 {
        let target = increased ? 7.0 : 4.5
        guard Self.ratio(foreground: foreground, background: background) < target else { return foreground }

        let black: UInt32 = 0x000000
        let white: UInt32 = 0xFFFFFF
        let endpoint = Self.ratio(foreground: black, background: background)
            >= Self.ratio(foreground: white, background: background) ? black : white
        guard Self.ratio(foreground: endpoint, background: background) >= target else { return endpoint }

        var low = 0.0
        var high = 1.0
        // Fixed work per token kind; monotone sRGB interpolation approaches the chosen endpoint.
        for _ in 0..<20 {
            let middle = (low + high) / 2
            let candidate = Self.interpolate(foreground, endpoint, fraction: middle)
            if Self.ratio(foreground: candidate, background: background) >= target {
                high = middle
            } else {
                low = middle
            }
        }
        let candidate = Self.interpolate(foreground, endpoint, fraction: high)
        guard Self.ratio(foreground: candidate, background: background) < target else { return candidate }
        let roundedUp = Self.interpolate(foreground, endpoint, fraction: min(1, high + 0.01))
        return Self.ratio(foreground: roundedUp, background: background) >= target ? roundedUp : endpoint
    }

    private static func luminance(_ color: UInt32) -> Double {
        let red = Double((color >> 16) & 0xFF) / 255
        let green = Double((color >> 8) & 0xFF) / 255
        let blue = Double(color & 0xFF) / 255
        return 0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func interpolate(_ start: UInt32, _ end: UInt32, fraction: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((start >> shift) & 0xFF)
            let b = Double((end >> shift) & 0xFF)
            return UInt32((a + (b - a) * fraction).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}
