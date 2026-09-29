import CoreGraphics
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
struct SVGRasterizerTests {
    private let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><rect width="400" height="200" fill="red"/></svg>"#.utf8)

    @Test func rasterizesToFitBounds() async {
        let fitted = await SVGRasterizer.rasterize(self.svg, fitting: CGSize(width: 3000, height: 900))
        #expect(fitted?.width == 1800 && fitted?.height == 900)
        let thumbnail = await SVGRasterizer.rasterize(self.svg)
        #expect(thumbnail?.width == 1200 && thumbnail?.height == 600)
    }

    @Test func installedProviderServesTheKitHook() async {
        SVGRasterizer.install()
        let image = await SVGRasterization.rasterize(self.svg)
        #expect(image?.width == 1200 && image?.height == 600)
    }
}
