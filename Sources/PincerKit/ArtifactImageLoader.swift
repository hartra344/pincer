import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Resolves transcript images (inline base64, artifact ids, or URLs) into `CGImage`s.
/// Artifacts are fetched through `artifacts.download` on the same authenticated socket,
/// so nothing is fetched from the Gateway over a second, unauthenticated channel.
///
/// Decoded images are downsampled to transcript size and kept in a cache bounded by decoded
/// bytes. An image that is evicted disappears from `images`, so the transcript shows its
/// placeholder again and `load` fetches it the next time its row is shown.
@MainActor
@Observable
public final class ArtifactImageLoader {
    #if os(iOS)
    public static var defaultByteBudget: Int { 64 * 1024 * 1024 }
    #else
    public static var defaultByteBudget: Int { 160 * 1024 * 1024 }
    #endif
    /// The largest transcript image is 400 pt wide; 1200 px covers 3x displays.
    public static let transcriptMaxPixel = 1200
    /// Cap for the sharp full-size preview.
    static let previewMaxPixel = 2400
    static let maxConcurrentDownloads = 4

    weak var gateway: GatewayStore?
    public private(set) var images: [String: CGImage] = [:]
    public private(set) var failures: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var cache: DecodedImageCache
    @ObservationIgnored private let limiter = DownloadLimiter(limit: ArtifactImageLoader.maxConcurrentDownloads)
    @ObservationIgnored private var pressureMonitor: MemoryPressureMonitor?
    @ObservationIgnored private var previewSlot: (key: String, image: CGImage)?
    @ObservationIgnored private var dataSlot: (key: String, data: Data)?
    @ObservationIgnored lazy var media = GatewayMediaClient(profile: { [weak self] in self?.gateway?.profile })

    public init(byteBudget: Int = ArtifactImageLoader.defaultByteBudget) {
        self.cache = DecodedImageCache(byteLimit: byteBudget)
        self.pressureMonitor = MemoryPressureMonitor { [weak self] critical in
            self?.handleMemoryPressure(critical: critical)
        }
    }

    var byteBudget: Int {
        get { self.cache.byteLimit }
        set { self.cache.byteLimit = newValue }
    }

    var decodedBytes: Int { self.cache.totalBytes }
    var imageCount: Int { self.cache.count }
    var peakConcurrentDownloads: Int { self.limiter.peak }

    /// Lookup that also marks the image recently used; safe to call from a view body.
    public func cached(_ ref: ImageRef) -> CGImage? {
        guard let image = self.images[ref.cacheKey] else { return nil }
        _ = self.cache.value(for: ref.cacheKey)
        return image
    }

    /// Starts resolving the image if it isn't cached yet. Call from `.task`.
    public func load(_ ref: ImageRef, sessionKey: String) {
        guard self.images[ref.cacheKey] == nil else { return }
        self.fetch(ref, sessionKey: sessionKey)
    }

    public func hasFailed(_ ref: ImageRef) -> Bool { self.failures.contains(ref.cacheKey) }

    /// Warning trims the cache to a quarter of the budget; critical drops everything.
    func handleMemoryPressure(critical: Bool) {
        let evicted = critical ? self.cache.removeAll() : self.cache.trim(toBytes: self.cache.byteLimit / 4)
        self.previewSlot = nil
        self.dataSlot = nil
        self.forget(evicted)
    }

    /// Raw bytes for "Save image…" / sharing. The last result is kept so the preview sheet doesn't download twice.
    public func data(for ref: ImageRef, sessionKey: String) async -> Data? {
        if let base64 = ref.base64 { return Self.decodeBase64(base64) }
        if let slot = self.dataSlot, slot.key == ref.cacheKey { return slot.data }
        guard let data = try? await self.download(ref, sessionKey: sessionKey) else { return nil }
        self.dataSlot = (ref.cacheKey, data)
        return data
    }

    /// Full-resolution decode for the preview sheet. Kept outside the byte budget, one image at a time.
    public func previewImage(for ref: ImageRef, sessionKey: String) async -> CGImage? {
        if let slot = self.previewSlot, slot.key == ref.cacheKey { return slot.image }
        guard let data = await self.data(for: ref, sessionKey: sessionKey) else { return nil }
        let image = await Self.decode(data, maxPixel: Self.previewMaxPixel)
        if let image { self.previewSlot = (ref.cacheKey, image) }
        return image
    }

    private func fetch(_ ref: ImageRef, sessionKey: String) {
        let key = ref.cacheKey
        guard !self.inFlight.contains(key), !self.failures.contains(key) else { return }
        self.inFlight.insert(key)
        Task {
            defer { self.inFlight.remove(key) }
            let data: Data? = if let base64 = ref.base64 {
                Self.decodeBase64(base64)
            } else {
                try? await self.download(ref, sessionKey: sessionKey)
            }
            let image = if let data { await Self.decode(data, maxPixel: Self.transcriptMaxPixel) } else { CGImage?.none }
            if let image {
                self.store(image, key: key)
            } else {
                self.failures.insert(key)
            }
        }
    }

    // Decoding a large image takes long enough to drop frames, so it stays off the main thread.
    private static func decode(_ data: Data, maxPixel: Int) async -> CGImage? {
        if SVGRasterizer.isSVG(data) { return await SVGRasterizer.rasterize(data) }
        return await Task.detached(priority: .userInitiated) { ImageCodec.decode(data, maxPixel: maxPixel) }.value
    }

    /// Raw bytes of a non-image attachment, fetched the same way as images.
    public func data(for file: FileRef, sessionKey: String) async -> Data? {
        try? await self.download(artifactId: file.artifactId, url: file.url, sessionKey: sessionKey, accept: "*/*")
    }

    private func download(_ ref: ImageRef, sessionKey: String) async throws -> Data? {
        try await self.download(artifactId: ref.artifactId, url: ref.url, sessionKey: sessionKey, accept: "image/*")
    }

    private func download(artifactId: String?, url: String?, sessionKey: String, accept: String) async throws -> Data? {
        guard artifactId != nil || url != nil else { return nil }
        try await self.limiter.acquire()
        defer { self.limiter.release() }
        if let artifactId, let gateway {
            var params: [String: JSONValue] = ["sessionKey": .string(sessionKey), "artifactId": .string(artifactId)]
            if SessionKey.agentId(from: sessionKey) == nil, let agent = gateway.sessions[sessionKey]?.agentId {
                params["agentId"] = .string(agent)
            }
            let result = try await gateway.connection.request("artifacts.download", .object(params), timeout: 60)
            if let data = result["data"]?.string ?? result["content"]?.string {
                return Self.decodeBase64(data)
            }
            if let url = result["url"]?.text { return try await self.fetchURL(url, sessionKey: sessionKey, accept: accept) }
            return nil
        }
        if let url { return try await self.fetchURL(url, sessionKey: sessionKey, accept: accept) }
        return nil
    }

    /// Whether agent-linked web images (`MEDIA:https://…`) load directly, like OpenClaw's web UI.
    public static var loadsWebImages: Bool {
        UserDefaults.standard.object(forKey: "pincer.loadWebImages") as? Bool ?? true
    }

    /// Routes a media source the way OpenClaw's Control UI does:
    /// - `data:` URIs decode in place;
    /// - Gateway-served paths and URLs on the Gateway host are fetched with Gateway auth;
    /// - local paths on the Gateway host (`/…`, `~/…`, `file:`, `media://inbound/…`) go through
    ///   the Gateway's `assistant-media` route, which applies its own file policy;
    /// - public `https` URLs are fetched directly, without credentials.
    private func fetchURL(_ string: String, sessionKey: String, accept: String) async throws -> Data? {
        if string.hasPrefix("data:") {
            return string.split(separator: ",", maxSplits: 1).last.flatMap { Self.decodeBase64(String($0)) }
        }
        guard let gateway, let gatewayURL = try? gateway.profile.resolvedURL(), let base = Self.httpBase(for: gatewayURL) else { return nil }
        if Self.isGatewayLocalSource(string) {
            var components = URLComponents(url: base.appendingPathComponent("__openclaw__/assistant-media"), resolvingAgainstBaseURL: false)
            var query = [URLQueryItem(name: "source", value: string), URLQueryItem(name: "sessionKey", value: sessionKey)]
            if let agentId = gateway.sessions[sessionKey]?.agentId ?? SessionKey.agentId(from: sessionKey) {
                query.append(URLQueryItem(name: "agentId", value: agentId))
            }
            components?.queryItems = query
            guard let url = components?.url else { return nil }
            return try await self.media.fetchGateway(url)
        }
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL, let host = url.host?.lowercased() else { return nil }
        if host == gatewayURL.host?.lowercased() {
            guard url.scheme == "https" || url.scheme == "http" else { return nil }
            return try await self.media.fetchGateway(url)
        }
        guard Self.loadsWebImages, url.scheme == "https", Self.isPublicHost(host) else { return nil }
        return try await self.media.fetchPublic(url, accept: accept)
    }

    /// Mirrors the Control UI's `isLocalAssistantAttachmentSource`.
    static func isGatewayLocalSource(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespaces)
        if value.range(of: #"^/(?:__openclaw__|media|api/chat/media/outgoing)/"#, options: .regularExpression) != nil {
            return false
        }
        if value.lowercased().hasPrefix("media://inbound/") || value.lowercased().hasPrefix("file:") { return true }
        if value.hasPrefix("~") || value.hasPrefix("/") { return true }
        if value.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil { return true }
        return !value.isEmpty && value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) == nil
    }

    /// Transcript content must not be able to make this Mac probe its local network.
    static func isPublicHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard host.contains("."), !host.contains(":") else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".ts.net") || host.hasSuffix(".home.arpa")
        {
            return false
        }
        return host.split(separator: ".").allSatisfy { Int($0) != nil } == false
    }

    private static func httpBase(for socketURL: URL) -> URL? {
        var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false)
        components?.scheme = socketURL.scheme == "wss" ? "https" : "http"
        components?.path = "/"
        return components?.url
    }

    private static func stripDataURL(_ value: String) -> String {
        guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") else { return value }
        return String(value[value.index(after: comma)...])
    }

    /// Decodes base64 unless its length already implies more than the download cap.
    static func decodeBase64(_ value: String, maxBytes: Int = GatewayMediaClient.defaultMaxBytes) -> Data? {
        let payload = self.stripDataURL(value)
        guard payload.utf8.count / 4 * 3 <= maxBytes else { return nil }
        return Data(base64Encoded: payload)
    }

    func store(_ image: CGImage, key: String) {
        let evicted = self.cache.insert(image, for: key)
        self.images[key] = image
        self.forget(evicted)
    }

    private func forget(_ keys: [String]) {
        for key in keys { self.images.removeValue(forKey: key) }
    }
}

/// At most `limit` downloads run at once; the rest wait in FIFO order.
@MainActor
final class DownloadLimiter {
    let limit: Int
    private(set) var active = 0
    private(set) var peak = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        if self.active < self.limit, self.waiters.isEmpty {
            self.claim()
            return
        }
        self.nextID += 1
        let id = self.nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    func release() {
        if self.waiters.isEmpty {
            self.active -= 1
        } else {
            // The slot passes straight to the next waiter.
            self.waiters.removeFirst().continuation.resume()
        }
    }

    private func claim() {
        self.active += 1
        self.peak = max(self.peak, self.active)
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Reports system memory pressure on the main queue.
final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(handler: @escaping @MainActor (_ critical: Bool) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { handler(critical) }
        }
        source.resume()
        self.source = source
    }

    deinit {
        self.source.cancel()
    }
}

public enum ImageCodec {
    public static func decode(_ data: Data) -> CGImage? {
        self.decode(data, maxPixel: 2400)
    }

    /// Decodes straight to a thumbnail of at most `maxPixel` on the long side, without inflating the full image.
    public static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Re-encodes an image so it fits under `maxBytes`, shrinking progressively. Strips
    /// metadata (GPS etc.) as a side effect, which is what we want before upload.
    public static func prepareForUpload(_ data: Data, fileName: String, maxBytes: Int) -> OutgoingAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let baseName = (fileName as NSString).deletingPathExtension
        let originalType = CGImageSourceGetType(source) as String?
        let keepsAlpha = originalType == UTType.png.identifier
        // Re-encoding would drop animation, so GIFs that already fit go up untouched.
        if data.count <= maxBytes, originalType == UTType.gif.identifier {
            return OutgoingAttachment(fileName: "\(baseName).gif", mimeType: "image/gif", data: data)
        }
        if data.count <= maxBytes, originalType == UTType.jpeg.identifier || originalType == UTType.png.identifier {
            if let clean = Self.encode(source: source, maxPixel: nil, png: keepsAlpha, quality: 0.9) , clean.count <= maxBytes {
                return OutgoingAttachment(
                    fileName: "\(baseName).\(keepsAlpha ? "png" : "jpg")",
                    mimeType: keepsAlpha ? "image/png" : "image/jpeg",
                    data: clean)
            }
        }
        for maxPixel in [3072, 2048, 1600, 1280, 1024, 768, 512] {
            for quality in [0.85, 0.7, 0.55] {
                if let encoded = Self.encode(source: source, maxPixel: maxPixel, png: false, quality: quality),
                   encoded.count <= maxBytes
                {
                    return OutgoingAttachment(fileName: "\(baseName).jpg", mimeType: "image/jpeg", data: encoded)
                }
            }
        }
        return nil
    }

    private static func encode(source: CGImageSource, maxPixel: Int?, png: Bool, quality: Double) -> Data? {
        var thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if let maxPixel { thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let output = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
