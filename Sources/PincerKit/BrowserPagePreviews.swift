import Foundation
import Observation

/// What `controlUi.linkPreview` returned for a page.
public struct LinkPreview: Hashable, Sendable {
    public let title: String?
    public let image: ImageRef?
    public let favicon: ImageRef?

    public init(title: String?, image: ImageRef?, favicon: ImageRef?) {
        self.title = title
        self.image = image
        self.favicon = favicon
    }
}

/// Page images for browser cards, fetched with `controlUi.linkPreview` (operator.read) as a
/// progressive enhancement. Bounded LRU; the data URLs are decoded to pixels off-main by `ArtifactImageLoader`.
@MainActor
@Observable
public final class BrowserPagePreviews {
    public static let maxEntries = 64
    public static let maxBytes = 8 * 1024 * 1024
    static let retryInterval: TimeInterval = 5 * 60
    nonisolated static let maxFaviconChars = 90_000
    nonisolated static let maxImageChars = 350_000
    static let method = "controlUi.linkPreview"

    weak var gateway: GatewayStore?
    private var entries: [URL: LinkPreview] = [:]
    private var screenshots: [String: ImageRef] = [:]
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var sizes: [URL: Int] = [:]
    @ObservationIgnored private var totalBytes = 0
    @ObservationIgnored private var inFlight: Set<URL> = []
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var active = 0
    static let maxInFlight = 4
    @ObservationIgnored private var failedAt: [URL: Date] = [:]
    @ObservationIgnored private var epoch = 0
    #if DEBUG
    @ObservationIgnored package private(set) var requestCount = 0
    package var cacheBytes: Int { self.totalBytes }
    package var cacheCount: Int { self.entries.count }
    #endif

    public init() {}

    /// Test seam: stores a preview without any network, as if `load` had finished.
    package func seed(_ preview: LinkPreview, for url: URL) {
        let bytes = (preview.image?.base64?.utf8.count ?? 0) + (preview.favicon?.base64?.utf8.count ?? 0)
        self.finishStore(preview: preview, url: url, bytes: bytes)
    }

    public func preview(for url: URL) -> LinkPreview? { self.entries[url] }

    public func screenshot(forTab key: String) -> ImageRef? { self.screenshots[key] }

    public func setScreenshot(_ ref: ImageRef?, forTab key: String) {
        if let ref { self.screenshots[key] = ref } else { self.screenshots[key] = nil }
    }

    public func load(_ url: URL) {
        if self.entries[url] != nil {
            if let index = self.order.firstIndex(of: url) { self.order.append(self.order.remove(at: index)) }
            return
        }
        guard !self.inFlight.contains(url), !self.queue.contains(url), Self.isFetchable(url), let gateway = self.gateway,
              gateway.state.isConnected, gateway.advertises(Self.method) else { return }
        if let failed = self.failedAt[url], Date().timeIntervalSince(failed) < Self.retryInterval { return }
        self.queue.append(url)
        self.pump()
    }

    private func pump() {
        while self.active < Self.maxInFlight, !self.queue.isEmpty {
            guard let gateway = self.gateway, gateway.state.isConnected else { self.queue = []; return }
            let url = self.queue.removeFirst()
            self.inFlight.insert(url)
            self.active += 1
            #if DEBUG
            self.requestCount += 1
            #endif
            let epoch = self.epoch
            let connection = gateway.connection
            Task { [weak self] in
                let result = try? await connection.request(Self.method, .object(["url": .string(url.absoluteString)]), timeout: 20)
                let parsed = await Task.detached(priority: .utility) { result.flatMap { Self.parse($0) } }.value
                self?.finish(url, parsed, epoch: epoch)
            }
        }
    }

    /// Public http(s) hosts only: no loopback, private, link-local or `.local` names, and no raw IP literals.
    nonisolated static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") { return false }
        if host.contains(":") { return false }
        let parts = host.split(separator: ".")
        if parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) || (parts.last?.allSatisfy(\.isNumber) ?? false) { return false }
        return true
    }

    /// Drops everything: the gateway profile changed.
    public func reset() {
        self.epoch += 1
        self.entries = [:]
        self.screenshots = [:]
        self.order = []
        self.sizes = [:]
        self.totalBytes = 0
        self.inFlight = []
        self.queue = []
        self.active = 0
        self.failedAt = [:]
    }

    private func finish(_ url: URL, _ parsed: (LinkPreview, Int)?, epoch: Int) {
        guard epoch == self.epoch else { return }
        self.inFlight.remove(url)
        self.active -= 1
        defer { self.pump() }
        guard let (preview, bytes) = parsed else {
            self.failedAt[url] = Date()
            return
        }
        self.failedAt[url] = nil
        self.finishStore(preview: preview, url: url, bytes: bytes)
    }

    private func finishStore(preview: LinkPreview, url: URL, bytes: Int) {
        if self.entries[url] != nil {
            self.totalBytes -= self.sizes[url] ?? 0
            self.order.removeAll { $0 == url }
        }
        self.entries[url] = preview
        self.sizes[url] = bytes
        self.totalBytes += bytes
        self.order.append(url)
        while self.order.count > Self.maxEntries || self.totalBytes > Self.maxBytes, self.order.count > 1 {
            let victim = self.order.removeFirst()
            self.entries[victim] = nil
            self.totalBytes -= self.sizes.removeValue(forKey: victim) ?? 0
        }
    }

    /// Validates the response and wraps its data URLs as inline `ImageRef`s. Nil when nothing usable came back.
    nonisolated static func parse(_ result: JSONValue) -> (LinkPreview, Int)? {
        let title = result["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = result["imageDataUrl"]?.string.flatMap { imageRef(dataURL: $0, limit: maxImageChars) }
        let favicon = result["faviconDataUrl"]?.string.flatMap { imageRef(dataURL: $0, limit: maxFaviconChars) }
        let cleanTitle = title?.isEmpty == false ? title : nil
        guard cleanTitle != nil || image != nil || favicon != nil else { return nil }
        let bytes = (image?.base64?.utf8.count ?? 0) + (favicon?.base64?.utf8.count ?? 0) + (cleanTitle?.utf8.count ?? 0)
        return (LinkPreview(title: cleanTitle, image: image, favicon: favicon), bytes)
    }

    /// Accepts only `data:image/(png|x-icon|jpeg);base64,` URLs within `limit` characters.
    nonisolated static func imageRef(dataURL: String, limit: Int) -> ImageRef? {
        guard dataURL.utf8.count <= limit else { return nil }
        for mime in ["image/png", "image/x-icon", "image/jpeg"] {
            let prefix = "data:\(mime);base64,"
            guard dataURL.hasPrefix(prefix) else { continue }
            let payload = String(dataURL.dropFirst(prefix.count))
            guard !payload.isEmpty, Data(base64Encoded: payload) != nil else { return nil }
            return ImageRef(artifactId: nil, base64: payload, url: nil, mimeType: mime, alt: nil, width: nil, height: nil)
        }
        return nil
    }
}
