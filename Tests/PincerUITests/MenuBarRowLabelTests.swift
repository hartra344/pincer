#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Suite("Menu bar row label")
struct MenuBarRowLabelTests {
    @Test func petAndTextOnlyRowsReserveTheSameLeadingColumn() throws {
        let pet = NSImage(size: NSSize(width: 16, height: 16))
        let withPet = try Self.renderedSize(MenuBarRowLabel(title: "home-lab · Claw", petImage: pet))
        let withoutPet = try Self.renderedSize(MenuBarRowLabel(title: "home-lab · Claw", petImage: nil))

        #expect(withoutPet.width == withPet.width)
    }

    private static func renderedSize<Content: View>(_ content: Content) throws -> CGSize {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "SwiftUI should render the menu row label")
        return CGSize(width: image.width, height: image.height)
    }
}
#endif
