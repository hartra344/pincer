#if os(macOS)
import AppKit
import CoreGraphics
import PincerKit
import Testing
@testable import PincerUI

/// #516: the menu's still pet must use the presentation's scheme even when Pincer's app theme is fixed.
@MainActor
@Suite("Menu bar avatar appearance", .serialized)
struct MenuBarAvatarAppearanceTests {
    private func png(_ image: NSImage?) -> Data? {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @Test func renderedPetMatchesPresentationSchemeInsteadOfApplicationAppearance() throws {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let style = AvatarStyle(creature: .cat)
        let state = AvatarState.thinking
        let accent = CGColor(red: 0.19, green: 0.38, blue: 0.72, alpha: 1)
        let side: CGFloat = 16
        let scale: CGFloat = 2

        application.appearance = dark
        let lightPresentation = try #require(MenuBarContent.petImage(style: style, state: state, colorScheme: .light,
                                                                     accent: accent, side: side, scale: scale))
        let expectedLight = try #require(AvatarArt.still(style, state: state, dark: false, accent: accent, side: side, scale: scale))
        let expectedDark = try #require(AvatarArt.still(style, state: state, dark: true, accent: accent, side: side, scale: scale))
        let lightPNG = try #require(self.png(lightPresentation))
        let expectedLightPNG = try #require(self.png(NSImage(cgImage: expectedLight, size: NSSize(width: side, height: side))))
        let expectedDarkPNG = try #require(self.png(NSImage(cgImage: expectedDark, size: NSSize(width: side, height: side))))
        #expect(lightPNG == expectedLightPNG)
        #expect(lightPNG != expectedDarkPNG)

        application.appearance = light
        let darkPresentation = try #require(MenuBarContent.petImage(style: style, state: state, colorScheme: .dark,
                                                                    accent: accent, side: side, scale: scale))
        let darkPNG = try #require(self.png(darkPresentation))
        #expect(darkPNG == expectedDarkPNG)
        #expect(darkPNG != expectedLightPNG)
    }
}
#endif
