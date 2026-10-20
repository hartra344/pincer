import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The demo's `browser` tool call and its `controlUi.linkPreview` answer, mirrored by
/// `mock-gateway/link-preview.mjs`. The PNGs are drawn on first request, off the main thread.
extension DemoGateway {
    static let browserPageURL = "https://www.marriott.com/reservation/availabilitySearch.mi?destinationAddress.city=Lisbon&fromDate=11%2F14%2F2026&toDate=11%2F17%2F2026"
    static let browserPageTitle = "Find & Book Hotels in Lisbon | Marriott Bonvoy"
    static let browserNavigateCall = "call_demo_browser_navigate"
    static let browserShotCall = "call_demo_browser_shot"
    static let browserTab: [String: JSONValue] = ["targetId": "DEMO7A1C0F3B", "profile": "openclaw", "target": "host"]

    static var browserTabDetails: JSONValue {
        var tab = browserTab
        tab["url"] = .string(browserPageURL)
        tab["title"] = .string(browserPageTitle)
        return ["browserTab": .object(tab)]
    }

    static func linkPreviewResult(_ params: JSONValue) -> JSONValue {
        guard params["url"]?.string == browserPageURL else { return [:] }
        return [
            "title": .string(browserPageTitle),
            "description": "Compare rates for 3 nights in Lisbon, 14 to 17 November.",
            "imageDataUrl": .string(pngDataURL(width: 191, height: 100) { x, y in
                (150 + x / 4, 40 + y, 60 + y / 2)
            }),
            "faviconDataUrl": .string(pngDataURL(width: 16, height: 16) { x, y in
                (x + y) % 4 < 2 ? (176, 38, 63) : (255, 255, 255)
            }),
        ]
    }

    private static func pngDataURL(width: Int, height: Int, pixel: (Int, Int) -> (Int, Int, Int)) -> String {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, r))
                bytes[i + 1] = UInt8(min(255, g))
                bytes[i + 2] = UInt8(min(255, b))
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let out = ImageEncoding.data(image, type: .png)
        else { return "" }
        return "data:image/png;base64," + out.base64EncodedString()
    }
}
