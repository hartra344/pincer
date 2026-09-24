import CryptoKit
import Foundation

public enum GatewayError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case insecureURL(String)
    case notConnected
    case timeout(String)
    case closed(String)
    case rpc(code: String, message: String, details: JSONValue?)
    case protocolViolation(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url): "“\(url)” isn’t a valid Gateway address. Use wss://host.tailnet.ts.net or ws://100.x.y.z:18789."
        case let .insecureURL(host): "Refusing unencrypted ws:// to public host \(host). Use wss:// (Tailscale Serve) or a tailnet IP."
        case .notConnected: "Not connected to the Gateway."
        case let .timeout(what): "Timed out waiting for \(what)."
        case let .closed(reason): "Connection closed: \(reason)"
        case let .rpc(code, message, details): "\(message) [\(details?["code"]?.string ?? code)]"
        case let .protocolViolation(message): "Unexpected Gateway response: \(message)"
        }
    }

    public var detailCode: String? {
        if case let .rpc(_, _, details) = self { return details?["code"]?.string }
        return nil
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    /// Gateway is waiting for `openclaw devices approve <requestId>` on the host.
    case awaitingPairing(requestId: String?, deviceId: String)
    case connected
    case reconnecting(attempt: Int, delaySeconds: Int, reason: String)
    /// Terminal until the user edits the connection (bad credentials, protocol mismatch…).
    case failed(String)

    public var isConnected: Bool { self == .connected }
}

public struct GatewayHello: Sendable {
    public let serverVersion: String?
    public let scopes: [String]
    public let maxPayload: Int
    public let maxImageBytes: Int?
    public let maxAttachmentBytes: Int?
    public let tickIntervalMs: Int
    public let methods: Set<String>
    public let snapshot: JSONValue?

    init(payload: JSONValue) {
        self.serverVersion = payload["server"]?["version"]?.string
        self.scopes = payload["auth"]?["scopes"]?.array?.compactMap(\.string) ?? []
        self.maxPayload = payload["policy"]?["maxPayload"]?.int ?? 25 * 1024 * 1024
        self.maxImageBytes = payload["policy"]?["attachments"]?["maxImageBytes"]?.int
        self.maxAttachmentBytes = payload["policy"]?["attachments"]?["maxBytes"]?.int
        self.tickIntervalMs = payload["policy"]?["tickIntervalMs"]?.int ?? 15000
        self.methods = Set(payload["features"]?["methods"]?.array?.compactMap(\.string) ?? [])
        self.snapshot = payload["snapshot"]
    }
}

public struct GatewayEvent: Sendable {
    public let name: String
    public let payload: JSONValue
    public let seq: Int?
}

/// One operator WebSocket to one Gateway: handshake, device pairing, request/response
/// correlation, event fan-out, and reconnect with backoff.
///
/// Deliberately operator-only: it never registers as a `node`, never advertises host
/// commands, and never starts or embeds a Gateway process.
public actor GatewayConnection {
    public static let protocolVersion = 4
    public static let role = "operator"
    public static let scopes = ["operator.read", "operator.write", "operator.approvals"]
    public static let caps = ["tool-events"]

    public nonisolated let profile: GatewayProfile
    private let identity: DeviceIdentity
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var challengeWaiter: CheckedContinuation<(String, Int64), Error>?
    private var bufferedChallenge: (String, Int64)?
    private var shouldRun = false
    private var attempt = 0
    private var lastFrameAt = Date()
    private var hello: GatewayHello?
    private var eventHandler: (@Sendable (GatewayEvent) -> Void)?
    private var stateHandler: (@Sendable (ConnectionState, GatewayHello?) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    public init(profile: GatewayProfile, identity: DeviceIdentity = .loadOrCreate()) {
        self.profile = profile
        self.identity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(
            configuration: configuration,
            delegate: PinningDelegate(fingerprint: profile.tlsFingerprint),
            delegateQueue: nil)
    }

    public var deviceId: String { self.identity.deviceId }

    public func setHandlers(
        onEvent: @escaping @Sendable (GatewayEvent) -> Void,
        onState: @escaping @Sendable (ConnectionState, GatewayHello?) -> Void)
    {
        self.eventHandler = onEvent
        self.stateHandler = onState
    }

    public func start() {
        guard !self.shouldRun else { return }
        self.shouldRun = true
        self.attempt = 0
        self.loopTask = Task { await self.runLoop() }
    }

    public func stop() {
        self.shouldRun = false
        self.loopTask?.cancel()
        self.watchdogTask?.cancel()
        self.teardown(reason: "stopped")
        self.emit(.idle)
    }

    /// Force an immediate reconnect (e.g. app returned to foreground on iOS).
    public func reconnectNow() {
        guard self.shouldRun else { return }
        if self.hello != nil, self.task?.state == .running { return }
        self.attempt = 0
        self.loopTask?.cancel()
        self.teardown(reason: "reconnect requested")
        self.loopTask = Task { await self.runLoop() }
    }

    public func request(_ method: String, _ params: JSONValue = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        guard self.hello != nil, let task = self.task else { throw GatewayError.notConnected }
        guard DebugLog.enabled, !DebugLog.quietMethods.contains(method) else {
            return try await self.send(method: method, params: params, on: task, timeout: timeout)
        }
        do {
            let result = try await self.send(method: method, params: params, on: task, timeout: timeout)
            DebugLog.write("→ \(method) \(DebugLog.brief(params)) ✓")
            return result
        } catch {
            DebugLog.write("→ \(method) \(DebugLog.brief(params)) ✗ \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Connect loop

    private func runLoop() async {
        while self.shouldRun, !Task.isCancelled {
            self.emit(.connecting)
            do {
                try await self.connectOnce()
                self.attempt = 0
                self.emit(.connected)
                await self.waitUntilDisconnected()
                guard self.shouldRun, !Task.isCancelled else { return }
                self.attempt += 1
                let delay = self.backoffSeconds()
                self.emit(.reconnecting(attempt: self.attempt, delaySeconds: delay, reason: "connection lost"))
                try? await Task.sleep(for: .seconds(delay))
            } catch let error as GatewayError {
                self.teardown(reason: error.localizedDescription)
                guard self.shouldRun, !Task.isCancelled else { return }
                switch Self.classify(error) {
                case let .pairing(requestId):
                    self.emit(.awaitingPairing(requestId: requestId, deviceId: self.identity.deviceId))
                    try? await Task.sleep(for: .seconds(5))
                case .staleDeviceToken:
                    // The Gateway rotated or revoked our device token; fall back to the shared secret once.
                    guard self.profile.deviceToken != nil else {
                        self.shouldRun = false
                        self.emit(.failed(error.localizedDescription))
                        return
                    }
                    self.profile.deviceToken = nil
                case let .fatal(message):
                    self.shouldRun = false
                    self.emit(.failed(message))
                    return
                case let .retry(message):
                    self.attempt += 1
                    let delay = self.backoffSeconds()
                    self.emit(.reconnecting(attempt: self.attempt, delaySeconds: delay, reason: message))
                    try? await Task.sleep(for: .seconds(delay))
                }
            } catch {
                self.teardown(reason: error.localizedDescription)
                guard self.shouldRun, !Task.isCancelled else { return }
                self.attempt += 1
                let delay = self.backoffSeconds()
                self.emit(.reconnecting(attempt: self.attempt, delaySeconds: delay, reason: error.localizedDescription))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private enum FailureClass { case pairing(String?), staleDeviceToken, fatal(String), retry(String) }

    private static func classify(_ error: GatewayError) -> FailureClass {
        switch error {
        case .invalidURL, .insecureURL:
            return .fatal(error.localizedDescription)
        case let .rpc(code, message, details):
            let detailCode = details?["code"]?.string ?? code
            if detailCode == "PAIRING_REQUIRED" || code == "PAIRING_REQUIRED" {
                let fromMessage = message.range(of: #"requestId:\s*[^\s)]+"#, options: .regularExpression)
                    .map { String(message[$0]).replacingOccurrences(of: "requestId:", with: "").trimmingCharacters(in: .whitespaces) }
                return .pairing(details?["requestId"]?.text ?? fromMessage)
            }
            if detailCode == "AUTH_DEVICE_TOKEN_MISMATCH" || detailCode == "AUTH_SCOPE_MISMATCH" {
                return .staleDeviceToken
            }
            if code == "UNAVAILABLE" || detailCode == "AUTH_RATE_LIMITED" {
                return .retry(message)
            }
            if detailCode.hasPrefix("AUTH_") || detailCode.hasPrefix("DEVICE_") || detailCode == "PROTOCOL_MISMATCH"
                || detailCode == "CLIENT_VERSION_MISMATCH"
            {
                return .fatal(error.localizedDescription)
            }
            return .retry(message)
        default:
            return .retry(error.localizedDescription)
        }
    }

    private func backoffSeconds() -> Int {
        min(30, 1 << min(self.attempt, 5))
    }

    private func connectOnce() async throws {
        let url = try self.profile.resolvedURL()
        self.teardown(reason: "new attempt")
        self.generation += 1
        let generation = self.generation
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let task = self.session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        self.bufferedChallenge = nil
        task.resume()
        self.receive(on: task, generation: generation)

        let (nonce, signedAt) = try await self.waitForChallenge(timeout: 20)

        // Prefer the paired device token; fall back to the configured shared secret.
        let deviceToken = self.profile.deviceToken
        let secret = self.profile.secret
        var auth: [String: JSONValue] = [:]
        var signatureToken: String?
        if let deviceToken {
            auth["token"] = .string(deviceToken)
            signatureToken = deviceToken
        } else if self.profile.authMode == .token, let secret {
            auth["token"] = .string(secret)
            signatureToken = secret
        }
        if self.profile.authMode == .password, let secret {
            auth["password"] = .string(secret)
        }

        let clientId = Self.clientId
        let clientMode = "ui"
        let payload = DeviceAuthPayload.v2(
            deviceId: self.identity.deviceId,
            clientId: clientId,
            clientMode: clientMode,
            role: Self.role,
            scopes: Self.scopes,
            signedAtMs: signedAt,
            token: signatureToken,
            nonce: nonce)
        let signature = try self.identity.sign(payload)

        var params: [String: JSONValue] = [
            "minProtocol": .number(Double(Self.protocolVersion)),
            "maxProtocol": .number(Double(Self.protocolVersion)),
            "client": [
                "id": .string(clientId),
                "displayName": .string(Self.displayName),
                "version": .string(Self.appVersion),
                "platform": .string(Self.platform),
                "mode": .string(clientMode),
                "deviceFamily": .string(Self.deviceFamily),
                "instanceId": .string(Self.instanceId),
            ],
            "role": .string(Self.role),
            "scopes": JSONValue(Self.scopes),
            "caps": JSONValue(Self.caps),
            "commands": [],
            "permissions": [:],
            "locale": .string(Locale.preferredLanguages.first ?? "en-US"),
            "userAgent": .string("pincer/\(Self.appVersion) (\(Self.platform))"),
            "device": [
                "id": .string(self.identity.deviceId),
                "publicKey": .string(self.identity.publicKeyBase64Url),
                "signature": .string(signature),
                "signedAt": .number(Double(signedAt)),
                "nonce": .string(nonce),
            ],
        ]
        if !auth.isEmpty { params["auth"] = .object(auth) }

        let response = try await self.send(method: "connect", params: .object(params), on: task, timeout: 20)
        guard generation == self.generation else { throw GatewayError.closed("superseded") }
        let hello = GatewayHello(payload: response)
        if let issued = response["auth"]?["deviceToken"]?.text, issued != deviceToken {
            self.profile.deviceToken = issued
        }
        self.hello = hello
        self.lastFrameAt = Date()
        self.startWatchdog(tickIntervalMs: hello.tickIntervalMs, generation: generation)
    }

    private func waitUntilDisconnected() async {
        while self.shouldRun, !Task.isCancelled, self.hello != nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func startWatchdog(tickIntervalMs: Int, generation: Int) {
        self.watchdogTask?.cancel()
        let limit = Double(max(tickIntervalMs, 5000)) * 2.5 / 1000
        self.watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if await self.isStale(limit: limit, generation: generation) {
                    await self.teardown(reason: "no heartbeat from Gateway")
                    return
                }
            }
        }
    }

    private func isStale(limit: TimeInterval, generation: Int) -> Bool {
        generation == self.generation && self.hello != nil && Date().timeIntervalSince(self.lastFrameAt) > limit
    }

    private func teardown(reason: String) {
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.hello = nil
        self.generation += 1
        let waiters = self.pending
        self.pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: GatewayError.closed(reason))
        }
        self.challengeWaiter?.resume(throwing: GatewayError.closed(reason))
        self.challengeWaiter = nil
    }

    // MARK: Frames

    private func send(method: String, params: JSONValue, on task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> JSONValue {
        let id = UUID().uuidString
        let frame: JSONValue = ["type": "req", "id": .string(id), "method": .string(method), "params": params]
        let data = try frame.encoded()
        if let hello, data.count > hello.maxPayload {
            throw GatewayError.rpc(code: "PAYLOAD_TOO_LARGE", message: "Message is larger than the Gateway allows (\(hello.maxPayload / 1_048_576) MB).", details: nil)
        }
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            self.pending[id] = continuation
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    self.fail(id: id, error: GatewayError.closed(error.localizedDescription))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.fail(id: id, error: GatewayError.timeout(method))
            }
        }
    }

    private func fail(id: String, error: Error) {
        self.pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func waitForChallenge(timeout: TimeInterval) async throws -> (String, Int64) {
        if let buffered = self.bufferedChallenge {
            self.bufferedChallenge = nil
            return buffered
        }
        let generation = self.generation
        return try await withCheckedThrowingContinuation { continuation in
            self.challengeWaiter = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if self.generation == generation, let waiter = self.challengeWaiter {
                    self.challengeWaiter = nil
                    waiter.resume(throwing: GatewayError.timeout("connect.challenge"))
                }
            }
        }
    }

    private nonisolated func receive(on task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                switch result {
                case let .success(message):
                    await self.handle(message, generation: generation)
                    if await self.isCurrent(generation) {
                        self.receive(on: task, generation: generation)
                    }
                case let .failure(error):
                    await self.socketFailed(generation: generation, error: error)
                }
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    private func socketFailed(generation: Int, error: Error) {
        guard generation == self.generation else { return }
        var reason = error.localizedDescription
        if let task = self.task, task.closeCode != .invalid {
            let closeReason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            reason = "closed (\(task.closeCode.rawValue)) \(closeReason)"
        }
        self.teardown(reason: reason)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, generation: Int) {
        guard generation == self.generation else { return }
        self.lastFrameAt = Date()
        let data: Data
        switch message {
        case let .string(text): data = Data(text.utf8)
        case let .data(bytes): data = bytes
        @unknown default: return
        }
        guard let frame = try? JSONValue.decode(data), let type = frame["type"]?.string else { return }
        switch type {
        case "res":
            guard let id = frame["id"]?.string, let continuation = self.pending.removeValue(forKey: id) else { return }
            if frame["ok"]?.bool == true {
                continuation.resume(returning: frame["payload"] ?? .null)
            } else {
                let error = frame["error"]
                continuation.resume(throwing: GatewayError.rpc(
                    code: error?["code"]?.string ?? "ERROR",
                    message: error?["message"]?.string ?? "Request failed",
                    details: error?["details"]))
            }
        case "event":
            guard let name = frame["event"]?.string else { return }
            let payload = frame["payload"] ?? .null
            if name == "connect.challenge" {
                guard let nonce = payload["nonce"]?.text, let ts = payload["ts"]?.int64, ts >= 0 else { return }
                if let waiter = self.challengeWaiter {
                    self.challengeWaiter = nil
                    waiter.resume(returning: (nonce, ts))
                } else {
                    self.bufferedChallenge = (nonce, ts)
                }
                return
            }
            if name == "tick" { return }
            if name == "shutdown" {
                self.teardown(reason: "Gateway restarting")
                return
            }
            self.eventHandler?(GatewayEvent(name: name, payload: payload, seq: frame["seq"]?.int))
        default:
            return
        }
    }

    private func emit(_ state: ConnectionState) {
        self.stateHandler?(state, state == .connected ? self.hello : nil)
    }

    // MARK: Client identity

    // The Gateway accepts only ids from its closed client registry; native Apple UIs use these.
    #if os(iOS)
    static let clientId = "openclaw-ios"
    static let platform = "ios"
    static let deviceFamily = "iPhone"
    #else
    static let clientId = "openclaw-macos"
    static let platform = "macos"
    static let deviceFamily = "Mac"
    #endif
    static let displayName = "Pincer"
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static var instanceId: String {
        let key = "pincer.instanceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

/// Optional certificate pinning. Without a fingerprint, normal system trust applies
/// (Tailscale Serve certificates for *.ts.net are publicly trusted).
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String?

    init(fingerprint: String?) {
        self.fingerprint = fingerprint?
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
            .nilIfEmpty
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard let fingerprint else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return actual == fingerprint ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Diagnostic log of requests and their outcomes, enabled with `PINCER_REQUEST_LOG=<path>`.
enum DebugLog {
    static let path = ProcessInfo.processInfo.environment["PINCER_REQUEST_LOG"]
    static var enabled: Bool { path != nil }
    static let quietMethods: Set<String> = ["chat.history", "artifacts.download"]
    private static let lock = NSLock()

    static func brief(_ params: JSONValue) -> String {
        guard var object = params.object else { return "" }
        if object["attachments"] != nil { object["attachments"] = .string("…") }
        if object["message"] != nil { object["message"] = .string("…") }
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ line: String) {
        guard let path else { return }
        lock.lock()
        defer { lock.unlock() }
        let entry = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: entry)
        }
    }
}
