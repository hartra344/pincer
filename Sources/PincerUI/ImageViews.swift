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
    @State private var exportData: Data?

    var body: some View {
        NavigationStack {
            Group {
                if let image = self.gateway.images.cached(self.ref) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(cgImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(minWidth: 300, maxWidth: CGFloat(image.width), minHeight: 200, maxHeight: CGFloat(image.height))
                    }
                } else {
                    ProgressView()
                }
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
        .frame(minWidth: 520, idealWidth: 900, minHeight: 400, idealHeight: 700)
        #endif
        .task {
            self.exportData = await self.gateway.images.data(for: self.ref, sessionKey: self.sessionKey)
        }
    }
}

struct TransferableImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .image) { $0.data }
    }
}
