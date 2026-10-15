import CoreGraphics
import Foundation
import ImageIO
@testable import PincerKit
#if DEBUG
@testable import PincerUI

// #971: the + button is one adaptive attach menu. iOS: Take Photo (when there's a camera),
// Photo Library, Choose File…; the Mac: Choose File… and Photos…. A camera capture is encoded
// off the main thread and goes through the same preparation pipeline as picked photos.

@MainActor
func runComposerAttachMenuChecks() async {
    check(ComposerAttachMenu.options(platform: .iOS, cameraAvailable: true).prefix(3) == [.takePhoto, .photoLibrary, .chooseFile],
          "iOS + menu offers Take Photo, Photo Library, Choose File… in that order")
    check(!ComposerAttachMenu.options(platform: .iOS, cameraAvailable: false).contains(.takePhoto),
          "iOS + menu hides Take Photo without a camera (Simulator)")
    check(ComposerAttachMenu.options(platform: .macOS, cameraAvailable: true) == [.chooseFile, .photoLibrary],
          "Mac + menu offers Choose File… and Photos…, never the camera")
    check(ComposerAttachMenu.title(.photoLibrary, platform: .macOS) == "Photos…", "Mac labels the library Photos…")

    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let image = context?.makeImage() else { check(false, "made a capture fixture"); return }
    let data = await CapturedPhotoEncoder.encode(SendableCGImage(image: image), orientation: .left)
    check(data?.starts(with: [0xFF, 0xD8, 0xFF]) == true, "a camera capture encodes to JPEG")
    let orientation = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyOrientation] as? UInt32
    check(orientation == CGImagePropertyOrientation.left.rawValue, "the capture keeps its orientation")
}

/// Demo: a captured photo lands in a demo chat's draft through the composer's own ingest.
@MainActor
func runDemoComposerAttachMenuChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("demo for the attach menu") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for the attach menu connected")
    guard connected else { return }
    let chat = gateway.chat(for: "agent:main:main")
    check(ComposerAttachmentIngest.canAttach(chat: chat, gateway: gateway), "the + menu is enabled in the demo")
    let context = CGContext(data: nil, width: 48, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let image = context?.makeImage(),
          let data = await CapturedPhotoEncoder.encode(SendableCGImage(image: image), orientation: .up)
    else { check(false, "encoded a capture"); return }
    ComposerAttachmentIngest.make(chat: chat, gateway: gateway).addImage(data, name: CapturedPhotoEncoder.fileName)
    let attached = await waitFor("captured photo attached", timeout: 20) { chat.draft.attachments.contains { $0.mimeType == "image/jpeg" } }
    check(attached, "a camera capture is attached to the demo chat's draft")
    check(chat.draftAttachmentPreparationCount == 0, "preparation finishes after the capture is attached")
}
#else
@MainActor func runComposerAttachMenuChecks() async {}
@MainActor func runDemoComposerAttachMenuChecks() async {}
#endif
