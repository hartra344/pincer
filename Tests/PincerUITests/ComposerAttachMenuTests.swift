import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PincerKit
@testable import PincerUI

/// #971: one adaptive + attach menu — camera, photos and files on iOS; files and Photos on the Mac.
struct ComposerAttachMenuTests {
    @Test func iOSOffersCameraPhotosAndFiles() {
        #expect(ComposerAttachMenu.options(platform: .iOS, cameraAvailable: true)
            == [.takePhoto, .photoLibrary, .chooseFile, .pasteImage])
    }

    @Test func iOSHidesTakePhotoWithoutACamera() {
        let options = ComposerAttachMenu.options(platform: .iOS, cameraAvailable: false)
        #expect(!options.contains(.takePhoto))
        #expect(options.first == .photoLibrary)
    }

    @Test func macOffersFilesAndPhotosOnly() {
        #expect(ComposerAttachMenu.options(platform: .macOS, cameraAvailable: true) == [.chooseFile, .photoLibrary])
        #expect(ComposerAttachMenu.options(platform: .macOS, cameraAvailable: false) == [.chooseFile, .photoLibrary])
    }

    @Test func titlesFollowThePlatform() {
        #expect(ComposerAttachMenu.title(.photoLibrary, platform: .macOS) == "Photos…")
        #expect(ComposerAttachMenu.title(.photoLibrary, platform: .iOS) == "Photo Library")
        #expect(ComposerAttachMenu.title(.takePhoto, platform: .iOS) == "Take Photo")
        #expect(ComposerAttachMenu.title(.chooseFile, platform: .macOS) == "Choose File…")
        #expect(ComposerAttachMenu.maxPhotoSelection == 6)
    }

    @Test func capturedPhotoEncodesToJPEGKeepingOrientation() async throws {
        let image = try #require(Self.image(width: 40, height: 20))
        let data = try #require(await CapturedPhotoEncoder.encode(SendableCGImage(image: image), orientation: .right))
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]), "a JPEG")
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? UInt32 == CGImagePropertyOrientation.right.rawValue)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
    }

    @MainActor
    @Test func capturedPhotoJoinsTheAttachmentPipeline() async throws {
        let image = try #require(Self.image(width: 64, height: 48))
        let data = try #require(await CapturedPhotoEncoder.encode(SendableCGImage(image: image), orientation: .up))
        var added: [OutgoingAttachment] = []
        var problems: [String?] = []
        let ingest = AttachmentIngest(limits: UploadLimits(policy: nil), add: { added.append($0) }, report: { problems.append($0) })
        ingest.addImage(data, name: CapturedPhotoEncoder.fileName)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while added.isEmpty, !problems.contains(where: { $0 != nil }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attachment = try #require(added.first)
        #expect(attachment.mimeType == "image/jpeg")
        #expect(problems.allSatisfy { $0 == nil })
    }

    static func image(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
