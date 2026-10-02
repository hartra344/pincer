import SwiftUI
import Testing
@testable import PincerUI

#if os(macOS)
import AppKit

@MainActor
@Suite("Logged Out badge contrast")
struct LoggedOutBadgeContrastTests {
    @Test func loggedOutCalloutTextMeetsContrastOnFormSurfaces() throws {
        try Self.verifyContrast()
    }

    static func verifyContrast() throws {
        let foreground = ChannelStatusPage.color(.loggedOut)
        let surfaces: [(String, NSColor)] = [("window", .windowBackgroundColor), ("control", .controlBackgroundColor)]
        for (appearanceName, scheme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var resolvedText: RGBA?
            var resolvedSurfaces: [RGBA?] = []
            appearance.performAsCurrentDrawingAppearance {
                resolvedText = Self.rgba(NSColor(foreground))
                resolvedSurfaces = surfaces.map { Self.rgba($0.1) }
            }
            let text = try #require(resolvedText)
            for (index, surfaceInfo) in surfaces.enumerated() {
                let surface = try #require(resolvedSurfaces[index])
                let ratio = Self.contrast(Self.composite(text, over: surface), surface)
                print("#171 Logged Out contrast: macOS \(scheme) \(surfaceInfo.0)=\(ratio)")
                #expect(ratio >= 4.5,
                        "Logged Out callout text has normal-text contrast on the \(scheme) \(surfaceInfo.0) surface")
            }
        }
    }

    private typealias RGBA = (red: Double, green: Double, blue: Double, alpha: Double)

    private static func rgba(_ color: NSColor) -> RGBA? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    private static func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return ((foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
                (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
                (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
                alpha)
    }

    private static func contrast(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        func luminance(_ color: RGBA) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
#elseif os(iOS)
import UIKit

@MainActor
@Suite("Logged Out badge contrast")
struct LoggedOutBadgeContrastTests {
    @Test func loggedOutCalloutTextMeetsContrastOnFormSurfaces() throws {
        try Self.verifyContrast()
    }

    static func verifyContrast() throws {
        let foreground = ChannelStatusPage.color(.loggedOut)
        let surfaces: [(String, UIColor)] = [("grouped", .systemGroupedBackground),
                                             ("secondary grouped", .secondarySystemGroupedBackground)]
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let text = try #require(Self.rgba(UIColor(foreground).resolvedColor(with: traits)))
            for (surfaceName, background) in surfaces {
                let surface = try #require(Self.rgba(background.resolvedColor(with: traits)))
                let ratio = Self.contrast(Self.composite(text, over: surface), surface)
                print("#171 Logged Out contrast: iOS \(name) \(surfaceName)=\(ratio)")
                #expect(ratio >= 4.5,
                        "Logged Out callout text has normal-text contrast on the \(name) \(surfaceName) surface")
            }
        }
    }

    private typealias RGBA = (red: Double, green: Double, blue: Double, alpha: Double)

    private static func rgba(_ color: UIColor) -> RGBA? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    private static func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return ((foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
                (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
                (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
                alpha)
    }

    private static func contrast(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        func luminance(_ color: RGBA) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
#endif
