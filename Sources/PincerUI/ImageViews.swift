import PincerKit
import SwiftUI

struct ImageGrid: View {
    let images: [ImageRef]
    let sessionKey: String
    @State private var preview: ImageRef?

    var body: some View {
        let columns = self.images.count == 1 ? 1 : 2
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 120, maximum: 320), spacing: 6, alignment: .leading), count: columns),
            alignment: .leading,
            spacing: 6)
        {
            ForEach(self.images, id: \.cacheKey) { ref in
                TranscriptImage(ref: ref, sessionKey: self.sessionKey, maxHeight: columns == 1 ? 360 : 200)
                    .onTapGesture { self.preview = ref }
            }
        }
        .frame(maxWidth: columns == 1 ? 480 : 640, alignment: .leading)
        .sheet(item: self.$preview) { ref in
            ImagePreview(ref: ref, sessionKey: self.sessionKey)
        }
    }
}

extension ImageRef: Identifiable {
    public var id: String { self.cacheKey }
}

struct TranscriptImage: View {
    let ref: ImageRef
    let sessionKey: String
    var maxHeight: CGFloat = 360
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let loader = self.gateway.images
        Group {
            if let image = loader.cached(self.ref) {
                Image(cgImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: self.maxHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                    .accessibilityLabel(self.ref.alt ?? "Image")
            } else if loader.hasFailed(self.ref) {
                if let link = self.webLink {
                    Link(destination: link) {
                        Label(self.ref.alt ?? link.host ?? "Open image", systemImage: "photo.badge.arrow.down")
                            .lineLimit(1)
                    }
                    .help(link.absoluteString)
                } else {
                    self.placeholder(systemImage: "photo.badge.exclamationmark", text: self.ref.alt ?? "Image unavailable")
                }
            } else {
                self.placeholder(systemImage: "photo", text: nil)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: self.ref.cacheKey) { loader.load(self.ref, sessionKey: self.sessionKey) }
    }

    private var webLink: URL? {
        guard let string = self.ref.url, let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private func placeholder(systemImage: String, text: String?) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quinary)
            .aspectRatio(self.ref.aspectRatio ?? 4 / 3, contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: min(self.maxHeight, 220))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: systemImage).font(.title2)
                    if let text { Text(text).font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
    }
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
