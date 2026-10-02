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
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let style = AvatarStyle(creature: .cat)
        let state = AvatarState.thinking
        let accent = CGColor(red: 0.19, green: 0.38, blue: 0.72, alpha: 1)
        let side: CGFloat = 16
        let scale: CGFloat = 2

        NSApp.appearance = dark
        let lightPresentation = MenuBarContent.petImage(style: style, state: state, colorScheme: .light,
                                                        accent: accent, side: side, scale: scale)
        let expectedLight = AvatarArt.still(style, state: state, dark: false, accent: accent, side: side, scale: scale)
        let expectedDark = AvatarArt.still(style, state: state, dark: true, accent: accent, side: side, scale: scale)
        #expect(self.png(lightPresentation) == self.png(expectedLight.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }))
        #expect(self.png(lightPresentation) != self.png(expectedDark.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }))

        NSApp.appearance = light
        let darkPresentation = MenuBarContent.petImage(style: style, state: state, colorScheme: .dark,
                                                       accent: accent, side: side, scale: scale)
        #expect(self.png(darkPresentation) == self.png(expectedDark.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }))
        #expect(self.png(darkPresentation) != self.png(expectedLight.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }))
    }
}
#endif
