import Foundation
import Observation

/// Fetches non-image attachments for saving, and text/code attachments for inline previews.
@MainActor
@Observable
public final class FileContentLoader {
    public enum Preview: Equatable, Sendable {
        case text(String, truncated: Bool)
        /// Downloaded, but not UTF-8 text.
        case binary
        case failed
    }

    /// Longest preview shown inline; the whole file is still available through Save.
    public nonisolated static let previewLimit = 50_000

    public private(set) var previews: [String: Preview] = [:]
    @ObservationIgnored private let images: ArtifactImageLoader
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var order: [String] = []
    private let capacity = 40

    init(images: ArtifactImageLoader) {
        self.images = images
    }

    public func preview(_ file: FileRef) -> Preview? {
        self.previews[file.cacheKey]
    }

    /// Starts fetching the file's text if it isn't loaded yet. Safe to call repeatedly.
    public func loadPreview(_ file: FileRef, sessionKey: String) {
        let key = file.cacheKey
        guard file.isDownloadable, self.previews[key] == nil, !self.inFlight.contains(key) else { return }
        self.inFlight.insert(key)
        Task {
            defer { self.inFlight.remove(key) }
            let data = await self.images.data(for: file, sessionKey: sessionKey)
            let preview: Preview = if let data {
                await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
            } else {
                .failed
            }
            self.store(preview, key: key)
        }
    }

    /// The whole file, for saving.
    public func data(for file: FileRef, sessionKey: String) async -> Data? {
        await self.images.data(for: file, sessionKey: sessionKey)
    }

    nonisolated static func decode(_ data: Data) -> Preview {
        if data.isEmpty { return .text("", truncated: false) }
        // NUL bytes mean binary even when the rest happens to be valid UTF-8.
        if data.prefix(8192).contains(0) { return .binary }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.count > self.previewLimit else { return .text(normalized, truncated: false) }
        return .text(String(normalized.prefix(self.previewLimit)), truncated: true)
    }

    private func store(_ preview: Preview, key: String) {
        self.previews[key] = preview
        self.order.append(key)
        while self.order.count > self.capacity {
            self.previews.removeValue(forKey: self.order.removeFirst())
        }
    }
}
