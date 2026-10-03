import CoreGraphics
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
struct SVGRasterizerTests {
    private let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"><rect width="400" height="200" fill="red"/></svg>"#.utf8)

    #if os(iOS)
    private actor StartGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !self.isOpen else { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }

        func open() {
            self.isOpen = true
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    #endif

    @Test func rasterizesToFitBounds() async {
        let fitted = await SVGRasterizer.rasterize(self.svg, fitting: CGSize(width: 3000, height: 900))
        #expect(fitted?.width == 1800 && fitted?.height == 900)
        #expect(Self.centerPixelIsRed(fitted), "the returned bitmap contains the rendered SVG, not only its expected size")
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
    @Test func cancellationBeforeRasterizationStartsReturnsNil() async {
        let gate = StartGate()
        let task = Task {
            await gate.wait()
            return await SVGRasterizer.rasterize(self.svg)
        }
        task.cancel()
        await gate.open()

        #expect(await task.value == nil)
    }
    #endif

    private static func centerPixelIsRed(_ image: CGImage?) -> Bool {
        guard let image, image.bitsPerPixel >= 32, let bytes = image.dataProvider?.data as Data? else { return false }
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * bytesPerPixel
        guard offset + 3 < bytes.count else { return false }
        return bytes[offset] > 200 && bytes[offset + 1] < 50 && bytes[offset + 2] < 50 && bytes[offset + 3] > 200
    }
}
