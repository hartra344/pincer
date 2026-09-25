import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Resolves transcript images (inline base64, artifact ids, or URLs) into `CGImage`s.
/// Artifacts are fetched through `artifacts.download` on the same authenticated socket,
/// so nothing is fetched from the Gateway over a second, unauthenticated channel.
@MainActor
@Observable
public final class ArtifactImageLoader {
    weak var gateway: GatewayStore?
    public private(set) var images: [String: CGImage] = [:]
    public private(set) var failures: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var order: [String] = []
    private let capacity = 80

    public init() {}

    /// Pure lookup; safe to call from a view body.
    public func cached(_ ref: ImageRef) -> CGImage? {
        self.images[ref.cacheKey]
    }

    /// Starts resolving the image if it isn't cached yet. Call from `.task`.
    public func load(_ ref: ImageRef, sessionKey: String) {
        guard self.images[ref.cacheKey] == nil else { return }
        self.fetch(ref, sessionKey: sessionKey)
    }

    public func hasFailed(_ ref: ImageRef) -> Bool { self.failures.contains(ref.cacheKey) }

    /// Raw bytes for "Save image…" / sharing.
    public func data(for ref: ImageRef, sessionKey: String) async -> Data? {
        if let base64 = ref.base64 { return Data(base64Encoded: Self.stripDataURL(base64)) }
        return try? await self.download(ref, sessionKey: sessionKey)
    }

    private func fetch(_ ref: ImageRef, sessionKey: String) {
        let key = ref.cacheKey
        guard !self.inFlight.contains(key), !self.failures.contains(key) else { return }
        self.inFlight.insert(key)
        Task {
            defer { self.inFlight.remove(key) }
            let data: Data? = if let base64 = ref.base64 {
                Data(base64Encoded: Self.stripDataURL(base64))
            } else {
                try? await self.download(ref, sessionKey: sessionKey)
            }
            // Decoding a large image takes long enough to drop frames, so it stays off the main thread.
            let image = await Task.detached(priority: .userInitiated) { data.flatMap(ImageCodec.decode) }.value
            if let image {
                self.store(image, key: key)
            } else {
                self.failures.insert(key)
            }
        }
    }

    private func download(_ ref: ImageRef, sessionKey: String) async throws -> Data? {
        if let artifactId = ref.artifactId, let gateway {
            var params: [String: JSONValue] = ["sessionKey": .string(sessionKey), "artifactId": .string(artifactId)]
            if SessionKey.agentId(from: sessionKey) == nil, let agent = gateway.sessions[sessionKey]?.agentId {
                params["agentId"] = .string(agent)
            }
            let result = try await gateway.connection.request("artifacts.download", .object(params), timeout: 60)
            if let data = result["data"]?.string ?? result["content"]?.string {
                return Data(base64Encoded: Self.stripDataURL(data))
            }
            if let url = result["url"]?.text { return try await self.fetchURL(url, sessionKey: sessionKey) }
            return nil
        }
        if let url = ref.url { return try await self.fetchURL(url, sessionKey: sessionKey) }
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
    private func fetchURL(_ string: String, sessionKey: String) async throws -> Data? {
        if string.hasPrefix("data:") {
            return string.split(separator: ",", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }
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
            return try await self.fetchFromGateway(url)
        }
        guard let url = URL(string: string, relativeTo: base)?.absoluteURL, let host = url.host?.lowercased() else { return nil }
        if host == gatewayURL.host?.lowercased() {
            guard url.scheme == "https" || url.scheme == "http" else { return nil }
            return try await self.fetchFromGateway(url)
        }
        guard Self.loadsWebImages, url.scheme == "https", Self.isPublicHost(host) else { return nil }
        return try await Self.fetchPublic(url)
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

    private static func fetchPublic(_ url: URL) async throws -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Pincer/0.1 (OpenClaw client; +https://github.com/openclaw/openclaw)", forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalHost = http.url?.host, http.url?.scheme == "https", Self.isPublicHost(finalHost),
              data.count <= 25 * 1024 * 1024
        else { return nil }
        return data
    }

    private func fetchFromGateway(_ url: URL) async throws -> Data? {
        guard let gateway else { return nil }
        var request = URLRequest(url: url)
        // Gateway HTTP auth accepts the shared token or password as a bearer, or the paired device token.
        if let secret = gateway.profile.secret ?? gateway.profile.deviceToken {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        // Same TLS pin as the socket; ephemeral so nothing is cached to disk.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: PinningDelegate(fingerprint: gateway.profile.tlsFingerprint),
            delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
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

    private func store(_ image: CGImage, key: String) {
        self.images[key] = image
        self.order.append(key)
        while self.order.count > self.capacity {
            let evicted = self.order.removeFirst()
            self.images.removeValue(forKey: evicted)
        }
    }
}

public enum ImageCodec {
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
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
