import SwiftUI
import Testing
@testable import PincerUI

#if os(macOS)
import AppKit

@MainActor
@Suite("Logged Out badge contrast")
struct LoggedOutBadgeContrastTests {
    @Test func loggedOutCalloutTextMeetsContrastOnFormSurfaces() throws {
        let foreground = ChannelStatusPage.color(.loggedOut)
        for (name, appearance) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let resolvedAppearance = try #require(NSAppearance(named: name))
            let text = try Self.rgb(NSColor(foreground).resolvedColor(with: resolvedAppearance))
            for background in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
                let surface = try Self.rgb(background.resolvedColor(with: resolvedAppearance))
                #expect(Self.contrast(text, surface) >= 4.5,
                         "Logged Out callout text has normal-text contrast on the \(name.rawValue) \(background) surface")
            }
        }
    }

    private static func rgb(_ color: NSColor) throws -> (Double, Double, Double) {
        let color = try #require(color.usingColorSpace(.sRGB))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (Double(red), Double(green), Double(blue))
    }

    private static func contrast(_ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)) -> Double {
        func luminance(_ color: (Double, Double, Double)) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.0) + 0.7152 * channel(color.1) + 0.0722 * channel(color.2)
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
        let foreground = ChannelStatusPage.color(.loggedOut)
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let text = try Self.rgb(UIColor(foreground).resolvedColor(with: traits))
            for background in [UIColor.systemGroupedBackground, .secondarySystemGroupedBackground] {
                let surface = try Self.rgb(background.resolvedColor(with: traits))
                #expect(Self.contrast(text, surface) >= 4.5,
                         "Logged Out callout text has normal-text contrast on the \(name) \(background) surface")
            }
        }
    }

    private static func rgb(_ color: UIColor) throws -> (Double, Double, Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (Double(red), Double(green), Double(blue))
    }

    private static func contrast(_ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)) -> Double {
        func luminance(_ color: (Double, Double, Double)) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.0) + 0.7152 * channel(color.1) + 0.0722 * channel(color.2)
        }
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
#endif
