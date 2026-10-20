import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Card thumbnails (#1012): the live panel's frames, throttled (once per 10 s per tab, only when the page changed) and downscaled off-main, keyed like
/// `BrowserPagePreview.tabKey` so a card shows the page it opened. Only tabs routed from a card (which carry a
/// profile) get one.
extension BrowserPanelModel {
    static let thumbnailInterval: TimeInterval = 10
    nonisolated static let thumbnailMaxWidth = 480
    nonisolated static let thumbnailQuality = 0.6

    /// `BrowserPagePreview.tabKey` for a tab, or nil when its route has no profile.
    static func thumbnailKey(for tab: BrowserPageTab) -> String? {
        guard let profile = tab.route.profile, !profile.isEmpty else { return nil }
        if tab.route.target == "node" {
            guard let node = tab.route.node, !node.isEmpty else { return nil }
            return "node|\(node)|\(profile)|\(tab.targetId)"
        }
        return "host|\(profile)|\(tab.targetId)"
    }

    func captureThumbnail(_ frame: BrowserFrame, tab: BrowserPageTab, now: Date = Date()) {
        guard self.thumbnailSink != nil, let key = Self.thumbnailKey(for: tab), !self.thumbnailInFlight.contains(key) else { return }
        if let last = self.thumbnailLast[key], now.timeIntervalSince(last) < Self.thumbnailInterval { return }
        self.thumbnailLast[key] = now
        self.thumbnailInFlight.insert(key)
        let image = frame.image
        Task.detached(priority: .utility) { [weak self] in
            let ref = Self.makeThumbnail(image)
            await MainActor.run {
                guard let self else { return }
                self.thumbnailInFlight.remove(key)
                // A closed tab drops its throttle entry; don't resurrect its thumbnail.
                guard self.thumbnailLast[key] != nil, let ref else { return }
                // Unchanged page: keep the card's current thumbnail.
                let digest = ref.cacheKey.hashValue
                guard self.thumbnailDigest[key] != digest else { return }
                self.thumbnailDigest[key] = digest
                self.thumbnailSink?(ref, key)
            }
        }
    }

    func clearThumbnail(for tab: BrowserPageTab) {
        guard let key = Self.thumbnailKey(for: tab) else { return }
        self.thumbnailLast[key] = nil
        self.thumbnailDigest[key] = nil
        self.thumbnailSink?(nil, key)
    }

    /// Clears every thumbnail this panel produced (gateway reset).
    func clearAllThumbnails() {
        let keys = Array(self.thumbnailLast.keys)
        self.thumbnailLast = [:]
        self.thumbnailDigest = [:]
        for key in keys { self.thumbnailSink?(nil, key) }
    }

    /// Downscales to at most 480 px wide and encodes JPEG at quality 0.6. Pure; runs off-main.
    nonisolated static func makeThumbnail(_ image: CGImage) -> ImageRef? {
        let scale = min(1, Double(Self.thumbnailMaxWidth) / Double(max(1, image.width)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = ImageEncoding.bitmapContext(width: width, height: height, alpha: .noneSkipLast) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = ImageEncoding.data(scaled, type: .jpeg, quality: Self.thumbnailQuality) else { return nil }
        return ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: "image/jpeg",
                        alt: nil, width: width, height: height)
    }
}
