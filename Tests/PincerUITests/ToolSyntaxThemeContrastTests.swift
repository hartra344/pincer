import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #561: syntax foregrounds need to remain readable over the code background selected in AppTheme.
@MainActor
@Suite("Tool syntax theme contrast", .serialized)
struct ToolSyntaxThemeContrastTests {
    @Test func actualTokenAttributeContrastsWithCustomizedCodeBackground() throws {
        // This isolated snapshot models a supported custom AppTheme background. The current
        // fixed light key color is exactly the same RGB, exposing that syntax colors do not
        // account for the actual surface.
        let codeBackground = try #require(ThemeColor(hex: "0550AE"))
        let theme = AppTheme(preset: .standard, mode: .light, overrides: [.codeBackground: codeBackground])

        let source = #"{"token":1}"#
        let keyToken = try #require(ToolSyntax.jsonTokens(in: source).first { $0.kind == .key })
        let colored = TranscriptSyntaxColors.apply([keyToken], to: NSAttributedString(string: source))
        let foreground = try #require(colored.attribute(.foregroundColor, at: keyToken.range.location,
                                                         effectiveRange: nil) as? PColor,
                                      "the actual JSON key token receives a syntax foreground")
        let background = try #require(theme.platformColor(.codeBackground),
                                      "the snapshot resolves its customized code background")

        let colors = try Self.lightRGBA(foreground: foreground, background: background)
        let contrast = Self.contrast(colors.0, colors.1)
        #expect(contrast >= 4.5,
                "the rendered syntax token should retain normal-text contrast on the active code background; got \(contrast)")
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private static func lightRGBA(foreground: PColor, background: PColor) throws -> (RGB, RGB) {
        #if os(macOS)
        let appearance = try #require(NSAppearance(named: .aqua))
        var colors: (RGB, RGB)?
        appearance.performAsCurrentDrawingAppearance {
            colors = Self.rgb(foreground).flatMap { foreground in
                Self.rgb(background).map { (foreground, $0) }
            }
        }
        return try #require(colors, "both native colors resolve in the light appearance")
        #else
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let foreground = foreground.resolvedColor(with: traits)
        let background = background.resolvedColor(with: traits)
        return (try #require(Self.rgb(foreground)), try #require(Self.rgb(background)))
        #endif
    }

    #if os(macOS)
    private static func rgb(_ color: NSColor) -> RGB? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(Double(red), Double(green), Double(blue))
    }
    #else
    private static func rgb(_ color: UIColor) -> RGB? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGB(Double(red), Double(green), Double(blue))
    }
    #endif

    private static func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        func luminance(_ color: RGB) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
