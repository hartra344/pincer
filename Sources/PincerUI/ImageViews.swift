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
    /// Full-resolution decode, owned by the sheet so cache eviction can't blank it.
    @State private var fullImage: CGImage?

    private var isVector: Bool { self.exportData.map(SVGRasterizer.isSVG) ?? false }

    /// Never upscale past the image's own pixels. A thumbnail that was itself downsampled says nothing
    /// about the original size, so it fits the sheet until the full image replaces it.
    private func capsAtPixelSize(_ image: CGImage) -> Bool {
        if self.isVector { return false }
        if self.fullImage != nil { return true }
        return max(image.width, image.height) < ArtifactImageLoader.transcriptMaxPixel - 2
    }

    var body: some View {
        NavigationStack {
            Group {
                // The transcript thumbnail stands in until the full-resolution image arrives.
                if let image = self.vectorImage ?? self.fullImage ?? self.gateway.images.cached(self.ref) {
                    let capped = self.capsAtPixelSize(image)
                    Image(cgImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: capped ? CGFloat(image.width) / self.displayScale : .infinity,
                            maxHeight: capped ? CGFloat(image.height) / self.displayScale : .infinity)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if self.gateway.images.hasFailed(self.ref) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
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
                    Button(L("Done")) { self.dismiss() }
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
        // Re-runs if the thumbnail is evicted or purged while the sheet is open.
        .task(id: self.gateway.images.images[self.ref.cacheKey] == nil) {
            self.gateway.images.load(self.ref, sessionKey: self.sessionKey)
        }
        .onDisappear { self.gateway.images.releaseData(for: self.ref) }
        .task {
            self.exportData = await self.gateway.images.data(for: self.ref, sessionKey: self.sessionKey)
            guard !self.isVector else { return }
            self.fullImage = await self.gateway.images.fullImage(self.ref, sessionKey: self.sessionKey)
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
