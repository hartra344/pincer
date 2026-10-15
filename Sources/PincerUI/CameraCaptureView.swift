#if os(iOS)
import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// The system camera, for attaching a fresh photo to a message. Hands back the capture as a
/// CGImage plus orientation so encoding happens off the main thread.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: @MainActor (SendableCGImage, CGImagePropertyOrientation) -> Void
    let onCancel: @MainActor () -> Void

    @MainActor static let isAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    /// Access was turned off in Settings; the picker would only show a black screen.
    static var isDenied: Bool { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let cgImage = image.cgImage {
                self.parent.onCapture(SendableCGImage(image: cgImage), CGImagePropertyOrientation(image.imageOrientation))
            } else {
                self.parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            self.parent.onCancel()
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
