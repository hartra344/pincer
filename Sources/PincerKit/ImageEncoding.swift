import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared Core Graphics / ImageIO plumbing: one-image encoding and 8-bit device-RGB bitmap contexts.
/// Pure and thread-agnostic; callers run it off the main thread where it matters.
public enum ImageEncoding {
    /// `image` encoded as a single-image `type` file, or nil when the destination can't be created
    /// or finalizing fails. `properties` go to `CGImageDestinationAddImage` unchanged.
    public static func data(_ image: CGImage, type: UTType, properties: [CFString: Any]? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// `image` encoded with `kCGImageDestinationLossyCompressionQuality` set to `quality`.
    public static func data(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        data(image, type: type, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    /// A `width` × `height` pixel bitmap context: 8 bits per component, device RGB, row bytes picked
    /// by Core Graphics, alpha laid out as `alpha`.
    public static func bitmapContext(width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue)
    }
}
