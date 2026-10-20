import CoreGraphics
import Foundation
import ImageIO
import PincerKit
import UniformTypeIdentifiers

/// One entry in the composer's **+** attach menu.
enum ComposerAttachOption: String, CaseIterable, Identifiable, Sendable {
    case takePhoto
    case photoLibrary
    case chooseFile
    case pasteImage

    var id: String { self.rawValue }

    var systemImage: String {
        switch self {
        case .takePhoto: "camera"
        case .photoLibrary: "photo.on.rectangle"
        case .chooseFile: "doc"
        case .pasteImage: "doc.on.clipboard"
        }
    }
}

/// What the **+** button offers on each platform: iOS gets the camera (when there is one), the photo
/// library and files; the Mac gets files and the Photos library.
enum ComposerAttachMenu {
    enum Platform: Sendable { case iOS, macOS }

    static var current: Platform {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }

    /// How many photos one pick from the library may add.
    static let maxPhotoSelection = 6

    static func options(platform: Platform, cameraAvailable: Bool) -> [ComposerAttachOption] {
        switch platform {
        case .iOS: (cameraAvailable ? [.takePhoto] : []) + [.photoLibrary, .chooseFile, .pasteImage]
        case .macOS: [.chooseFile, .photoLibrary]
        }
    }

    static func title(_ option: ComposerAttachOption, platform: Platform) -> String {
        switch option {
        case .takePhoto: L("Take Photo")
        case .photoLibrary: platform == .macOS ? L("Photos…") : L("Photo Library")
        case .chooseFile: L("Choose File…")
        case .pasteImage: L("Paste Image")
        }
    }
}

/// Encodes a camera capture to JPEG for the attachment pipeline. Runs off the main thread.
enum CapturedPhotoEncoder {
    static let fileName = "Photo.jpg"

    nonisolated static func jpeg(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, quality: Double = 0.9) -> Data? {
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation.rawValue,
        ]
        return ImageEncoding.data(image, type: .jpeg, properties: properties)
    }

    /// Encodes on a detached task so the shutter dismissal never waits on JPEG compression.
    nonisolated static func encode(_ image: SendableCGImage, orientation: CGImagePropertyOrientation) async -> Data? {
        await Task.detached(priority: .userInitiated) { Self.jpeg(image.image, orientation: orientation) }.value
    }
}

/// CGImage is immutable and thread-safe; this lets a capture cross into the encoder's task.
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}
