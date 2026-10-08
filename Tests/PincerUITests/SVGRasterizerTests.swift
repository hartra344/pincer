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
        #expect(Self.centerPixelIsRed(fitted), "the bitmap holds the rendered SVG, not just the right size")
        let thumbnail = await SVGRasterizer.rasterize(self.svg)
        #expect(thumbnail?.width == 1200 && thumbnail?.height == 600)
        #expect(Self.centerPixelIsRed(thumbnail))
    }

    @Test func installedProviderServesTheKitHook() async {
        SVGRasterizer.install()
        let image = await SVGRasterization.rasterize(self.svg)
        #expect(image?.width == 1200 && image?.height == 600)
        #expect(Self.centerPixelIsRed(image))
    }

    #if os(iOS)
    /// Cancelling once WebKit has the page (the continuation is set synchronously before the first
    /// suspension) stops the load and returns nil instead of snapshotting.
    @Test func cancellingAnInFlightRenderReturnsNil() async {
        let task = Task { @MainActor in await SVGRasterizer.rasterize(self.svg) }
        await Task.yield()
        task.cancel()
        #expect(await task.value == nil)
    }
    #endif

    private static func centerPixelIsRed(_ image: CGImage?) -> Bool {
        guard let image, image.bitsPerPixel == 32, let data = image.dataProvider?.data as Data? else { return false }
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        guard offset + 3 < data.count else { return false }
        return data[offset] > 200 && data[offset + 1] < 50 && data[offset + 2] < 50 && data[offset + 3] > 200
    }
}
