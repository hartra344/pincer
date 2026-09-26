import PincerKit
import SwiftUI

extension ImageRef: Identifiable {
    public var id: String { self.cacheKey }
}

struct ImagePreview: View {
    let ref: ImageRef
    let sessionKey: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var exportData: Data?
    /// Vector images are re-rendered at exactly the preview's pixel size, only while it's open.
    @State private var vectorImage: CGImage?
    @State private var pixelBounds: CGSize = .zero

    private var isVector: Bool { self.exportData.map(SVGRasterizer.isSVG) ?? false }

    var body: some View {
        NavigationStack {
            Group {
                if let image = self.vectorImage ?? self.gateway.images.cached(self.ref) {
                    Image(cgImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: self.isVector ? .infinity : CGFloat(image.width),
                            maxHeight: self.isVector ? .infinity : CGFloat(image.height))
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: max(proxy.size.width - 24, 0), height: max(proxy.size.height - 24, 0))
            } action: { self.pixelBounds = CGSize(width: ($0.width * self.displayScale).rounded(), height: ($0.height * self.displayScale).rounded()) }
            .task(id: VectorRequest(bounds: self.pixelBounds, hasData: self.isVector)) {
                guard self.isVector, let data = self.exportData else { return }
                // Live window resizes fire continuously; render once they settle.
                try? await Task.sleep(for: .milliseconds(self.vectorImage == nil ? 0 : 150))
                guard !Task.isCancelled, let image = await SVGRasterizer.rasterize(data, fitting: self.pixelBounds) else { return }
                self.vectorImage = image
            }
            .navigationTitle(self.ref.alt ?? "Image")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { self.dismiss() }
                }
                if let exportData {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: TransferableImage(data: exportData),
                            preview: SharePreview(self.ref.alt ?? "Image"))
                    }
                }
            }
        }
        #if os(macOS)
        .frame(
            minWidth: 520, idealWidth: Self.idealSize.width, maxWidth: .infinity,
            minHeight: 400, idealHeight: Self.idealSize.height, maxHeight: .infinity)
        .presentationSizing(.fitted)
        #endif
        .task {
            self.exportData = await self.gateway.images.data(for: self.ref, sessionKey: self.sessionKey)
        }
    }

    #if os(macOS)
    /// Most of the screen, so the image isn't squeezed into a small sheet.
    private static var idealSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: (screen.width * 0.85).rounded(), height: (screen.height * 0.85).rounded())
    }
    #endif
}

private struct VectorRequest: Equatable {
    let bounds: CGSize
    let hasData: Bool
}

struct TransferableImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .image) { $0.data }
    }
}
