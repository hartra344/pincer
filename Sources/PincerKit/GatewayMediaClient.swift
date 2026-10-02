import Foundation

enum MediaError: Error {
    case tooLarge
}

/// HTTP transport for media (images, files) served by one Gateway, or by the public web.
/// Keeps one pinned, ephemeral session and one Keychain read per Gateway profile instead of
/// creating both for every download.
@MainActor
final class GatewayMediaClient {
    /// Hard cap on any single media download.
    nonisolated static let defaultMaxBytes = 25 * 1024 * 1024
    /// Cap when the user explicitly saves or shares a file.
    nonisolated static let explicitMaxBytes = 200 * 1024 * 1024

    private struct Identity: Equatable {
        let id: UUID
        let fingerprint: String?
        let scheme: String?
        let host: String?
        let port: Int?
    }

    private struct Credentials {
        let identity: Identity
        let authorization: String?
    }

    /// Shared by every public (non-Gateway) fetch: no cookies, nothing cached to disk.
    private static let publicSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private let profile: @MainActor () -> GatewayProfile?
    private let secretReader: (GatewayProfile) -> String?
    let maxBytes: Int
    /// Test seam: replaces the configuration of both the Gateway session and the public session.
    var configurationOverride: URLSessionConfiguration?
    private var overriddenPublicSession: URLSession?
    private var credentials: Credentials?
    nonisolated(unsafe) private var session: URLSession?

    /// Keychain reads and sessions created since init; tests assert these stay at 1 across many requests.
    private(set) var keychainReads = 0
    private(set) var sessionsCreated = 0

    init(
        profile: @escaping @MainActor () -> GatewayProfile?,
        maxBytes: Int = GatewayMediaClient.defaultMaxBytes,
        secretReader: @escaping (GatewayProfile) -> String? = { $0.secret ?? $0.deviceToken })
    {
        self.profile = profile
        self.maxBytes = maxBytes
        self.secretReader = secretReader
    }

    deinit {
        self.session?.finishTasksAndInvalidate()
        self.overriddenPublicSession?.finishTasksAndInvalidate()
    }

    /// Drops the cached credentials and session; the next request rebuilds them. Requests already
    /// started keep running: `finishTasksAndInvalidate` lets them finish, and tasks are only ever created
    /// on the main actor right after `prepare()`, so nothing can start on an invalidated session.
    func reset() {
        self.credentials = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }

    /// Fetches with Gateway auth and the profile's TLS pin. Returns nil for non-200 responses and throws `MediaError.tooLarge` past the size cap.
    func fetchGateway(_ url: URL, maxBytes: Int? = nil) async throws -> Data? {
        for attempt in 0..<2 {
            guard let (session, authorization) = self.prepare() else { return nil }
            var request = URLRequest(url: url)
            if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            let result = try await BoundedDownload.run(session: session, request: request, limit: maxBytes ?? self.maxBytes)
            let status = result.response?.statusCode
            if attempt == 0, status == 401 || status == 403, authorization != nil {
                // Concurrent 401s only reset once: later ones find a newer session already in place.
                if self.session === session { self.reset() }
                continue
            }
            if result.tooLarge { throw MediaError.tooLarge }
            return status == 200 ? result.data : nil
        }
        return nil
    }

    /// Fetches a public https URL without credentials; a redirect off public https hosts is refused.
    func fetchPublic(_ url: URL, accept: String, maxBytes: Int? = nil) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Pincer/0.1 (OpenClaw client; +https://github.com/openclaw/openclaw)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let result = try await BoundedDownload.run(session: self.publicSession, request: request, limit: maxBytes ?? self.maxBytes)
        if result.tooLarge { throw MediaError.tooLarge }
        guard let http = result.response, http.statusCode == 200,
              let finalHost = http.url?.host, http.url?.scheme == "https", ArtifactImageLoader.isPublicHost(finalHost)
        else { return nil }
        return result.data
    }

    private var publicSession: URLSession {
        guard let configuration = self.configurationOverride else { return Self.publicSession }
        if let session = self.overriddenPublicSession { return session }
        let session = URLSession(configuration: configuration)
        self.overriddenPublicSession = session
        return session
    }

    /// Current session and auth header, rebuilt when the profile's identity changed.
    private func prepare() -> (URLSession, String?)? {
        guard let profile = self.profile(), let url = try? profile.resolvedURL() else { return nil }
        let identity = Identity(
            id: profile.id, fingerprint: PinningDelegate.normalized(profile.tlsFingerprint),
            scheme: url.scheme, host: url.host?.lowercased(), port: url.port)
        if let credentials = self.credentials, credentials.identity != identity { self.reset() }
        if self.credentials == nil {
            self.keychainReads += 1
            let secret = self.secretReader(profile)
            self.credentials = Credentials(identity: identity, authorization: secret.map { "Bearer \($0)" })
        }
        if self.session == nil {
            self.sessionsCreated += 1
            // Same TLS pin as the socket; ephemeral so nothing is cached to disk.
            self.session = URLSession(
                configuration: self.configurationOverride ?? .ephemeral,
                delegate: PinningDelegate(fingerprint: profile.tlsFingerprint),
                delegateQueue: nil)
        }
        guard let session = self.session else { return nil }
        return (session, self.credentials?.authorization)
    }
}

/// Streams one response, cancelling as soon as it is known or found to exceed `limit`.
final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable {
        var data: Data?
        var response: HTTPURLResponse?
        var tooLarge: Bool
    }

    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var tooLarge = false
    private var continuation: CheckedContinuation<Result, any Error>?

    private init(limit: Int) {
        self.limit = limit
    }

    /// Main-actor isolated so the task is created and resumed before the caller can be interleaved with a `reset()`.
    @MainActor
    static func run(session: URLSession, request: URLRequest, limit: Int) async throws -> Result {
        let download = BoundedDownload(limit: limit)
        let task = session.dataTask(with: request)
        task.delegate = download
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.lock()
                download.continuation = continuation
                download.lock.unlock()
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        self.lock.lock()
        self.response = response as? HTTPURLResponse
        let oversized = response.expectedContentLength > Int64(self.limit)
        if oversized { self.tooLarge = true }
        self.lock.unlock()
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.lock.lock()
        self.buffer.append(data)
        let oversized = self.buffer.count > self.limit
        if oversized {
            self.tooLarge = true
            self.buffer = Data()
        }
        self.lock.unlock()
        if oversized { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = Result(data: self.tooLarge ? nil : self.buffer, response: self.response, tooLarge: self.tooLarge)
        let tooLarge = self.tooLarge
        self.lock.unlock()
        if let error, !tooLarge {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: result)
        }
    }
}
