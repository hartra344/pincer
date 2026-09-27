import Foundation
import Network
import Observation

// MARK: Error copy

/// Plain-language messages for what went wrong while finding or signing in to a Gateway.
public enum FirstRunCopy {
    /// A sign-in failure, from `ConnectionState.failed`/`.reconnecting` text ("message [CODE]").
    public static func signInError(_ message: String) -> String {
        let code = message.range(of: #"\[([A-Z_]+)\]\s*$"#, options: .regularExpression)
            .map { String(message[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
        switch code {
        case "AUTH_TOKEN_MISMATCH", "AUTH_UNAUTHORIZED":
            return "The Gateway didn't accept that token. Copy it again from the Gateway host and try once more."
        case "AUTH_PASSWORD_MISMATCH":
            return "The Gateway didn't accept that password. Check it and try again."
        case "AUTH_TOKEN_MISSING", "AUTH_REQUIRED":
            return "This Gateway needs a token. Paste it above and try again."
        case "AUTH_PASSWORD_MISSING":
            return "This Gateway needs a password. Enter it above and try again."
        case "AUTH_TOKEN_NOT_CONFIGURED":
            return "This Gateway doesn't use a token. Try Password or No Sign-In instead."
        case "AUTH_PASSWORD_NOT_CONFIGURED":
            return "This Gateway doesn't use a password. Try Token or No Sign-In instead."
        case "AUTH_RATE_LIMITED":
            return "Too many failed attempts. Wait a minute, then try again."
        case let code? where code.hasPrefix("AUTH_TAILSCALE"):
            return "The Gateway couldn't confirm your Tailscale identity. Use a token instead, or connect through Tailscale Serve."
        case "PROTOCOL_MISMATCH", "CLIENT_VERSION_MISMATCH":
            return "This Gateway runs a different OpenClaw version than Pincer supports. Update OpenClaw on the Gateway host."
        default:
            return message
        }
    }

    /// Why a WebSocket to the Gateway didn't open.
    public static func reachabilityError(_ error: Error, host: String) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .cannotFindHost?, .dnsLookupFailed?:
            return "Couldn't find \(host). Check the spelling, and that this device is on the same network or tailnet."
        case .cannotConnectToHost?, .networkConnectionLost?:
            return "Nothing answered at \(host). Make sure the Gateway is running and listening on this network (by default it only listens on its own computer)."
        case .timedOut?:
            return "\(host) didn't answer in time. Check that the Gateway is running and this device can reach it."
        case .notConnectedToInternet?:
            return "This device is offline. Connect to your network or tailnet and try again."
        case .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?,
             .serverCertificateNotYetValid?, .secureConnectionFailed?:
            return "\(host)'s certificate isn't trusted. Use Tailscale Serve (wss://…ts.net), or pin the certificate under Advanced."
        case .badServerResponse?:
            return "Something answered at \(host), but it isn't an OpenClaw Gateway. Check the address and port (the default is 18789)."
        default:
            return "Couldn't reach \(host): \(error.localizedDescription)"
        }
    }

    public static let notAGateway =
        "Something answered, but it didn't greet Pincer like an OpenClaw Gateway. Check the address and port (the default is 18789)."
}

// MARK: Model

/// Drives `FirstRunState` with real side effects: reachability checks, sign-in, Bonjour discovery,
/// adding the gateway to the app and saving progress. One per app, owned by `AppModel`.
@MainActor
@Observable
public final class FirstRunModel {
    public enum Presentation: Hashable, Sendable {
        /// Fills the main window (no gateways yet).
        case window
        /// A sheet over the chat list ("Add Gateway…").
        case sheet
    }

    /// The side effects, injectable for tests.
    public struct Environment: Sendable {
        public typealias SignIn = @Sendable (GatewayProfile) -> AsyncStream<FirstRunSignInUpdate>
        public var checkReachability: @Sendable (URL) async -> FirstRunReachability
        public var signIn: SignIn
        public var discover: @Sendable () -> AsyncStream<[FirstRunDiscoveredGateway]>

        public init(checkReachability: @escaping @Sendable (URL) async -> FirstRunReachability,
                    signIn: @escaping SignIn,
                    discover: @escaping @Sendable () -> AsyncStream<[FirstRunDiscoveredGateway]> = { AsyncStream { $0.finish() } })
        {
            self.checkReachability = checkReachability
            self.signIn = signIn
            self.discover = discover
        }

        public static let live = Environment(
            checkReachability: { await FirstRunProbe.checkReachability($0) },
            signIn: { FirstRunProbe.signIn($0) },
            discover: { FirstRunDiscovery.browse() })
    }

    public private(set) var state: FirstRunState
    public private(set) var presentation: Presentation?
    /// The token or password being typed. Never saved outside the Keychain.
    public var secret = ""
    /// Bumped each time the wizard is presented, so views can reset focus.
    public private(set) var presentationCount = 0

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var reachabilityTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    /// Loads a run saved before the app quit. `hasGateways` decides where a fresh run starts.
    public init(defaults: UserDefaults, environment: Environment = .live, hasGateways: Bool) {
        self.defaults = defaults
        self.environment = environment
        if let saved = FirstRunStore.load(from: defaults) {
            self.state = saved
            self.presentation = hasGateways ? .sheet : .window
            self.secret = saved.gatewayId == nil ? (GatewayProfile(id: saved.profileId, name: "", url: "", authMode: .token).secret ?? "") : ""
        } else {
            self.state = .start(hasGateways: hasGateways)
            self.presentation = hasGateways ? nil : .window
        }
    }

    public var isPresented: Bool { self.presentation != nil }

    /// The sheet binding's value.
    public var isSheetPresented: Bool {
        get { self.presentation == .sheet }
        set { if !newValue, self.presentation == .sheet { self.send(.cancel) } }
    }

    /// The gateway the run added, once signed in.
    public var gateway: GatewayStore? {
        guard let id = self.state.gatewayId else { return nil }
        return self.app?.gateways.first { $0.id == id }
    }

    /// "Add Gateway…": a new run (or the one in progress), over the chat list if there is one.
    public func present() {
        let hasGateways = !(self.app?.gateways.isEmpty ?? true)
        if self.presentation == nil {
            self.state = .start(hasGateways: hasGateways)
            self.secret = ""
        }
        self.presentation = hasGateways ? (self.presentation ?? .sheet) : .window
        self.presentationCount += 1
        self.resumeEffects()
    }

    /// With no gateways left (fresh install, or the last one removed) the wizard fills the window.
    public func showIfNoGateways() {
        guard self.app?.gateways.isEmpty ?? false, self.presentation != .window else { return }
        if self.presentation == nil {
            self.state = .start(hasGateways: false)
            self.secret = ""
        }
        self.presentation = .window
        self.resumeEffects()
    }

    /// Restarts discovery after a resume or a new presentation.
    private func resumeEffects() {
        if self.state.step == .findGateway, self.discoveryTask == nil { self.perform(.startDiscovery) }
        if self.state.step == .gatewaySetup, let id = self.state.gatewayId { self.perform(.beginGatewaySetup(gatewayId: id)) }
    }

    public func send(_ event: FirstRunEvent) {
        var next = self.state
        let effects = next.send(event)
        if next != self.state { self.state = next }
        for effect in effects { self.perform(effect) }
        self.persist()
    }

    private func persist() {
        if self.presentation != nil, self.state.isInProgress {
            FirstRunStore.save(self.state, to: self.defaults)
        } else if self.defaults.data(forKey: FirstRunStore.key) != nil {
            FirstRunStore.clear(self.defaults)
        }
    }

    private func perform(_ effect: FirstRunEffect) {
        switch effect {
        case .openDemo:
            self.app?.openDemo()

        case .startDiscovery:
            self.discoveryTask?.cancel()
            let stream = self.environment.discover()
            self.discoveryTask = Task { [weak self] in
                for await found in stream {
                    guard !Task.isCancelled else { return }
                    self?.send(.discovered(found))
                }
            }

        case .stopDiscovery:
            self.discoveryTask?.cancel()
            self.discoveryTask = nil

        case let .checkReachability(address, url):
            self.reachabilityTask?.cancel()
            let check = self.environment.checkReachability
            self.reachabilityTask = Task { [weak self] in
                let result = await check(url)
                guard !Task.isCancelled else { return }
                self?.send(.reachabilityResult(address: address, result))
            }

        case let .signIn(profile):
            self.signInTask?.cancel()
            profile.forgetDeviceToken()
            profile.secret = profile.authMode == .none ? nil : self.secret
            let stream = self.environment.signIn(profile)
            self.signInTask = Task { [weak self] in
                for await update in stream {
                    guard !Task.isCancelled else { return }
                    self?.send(.signInUpdate(update))
                }
            }

        case .cancelSignIn:
            self.signInTask?.cancel()
            self.signInTask = nil

        case let .addGateway(profile):
            guard let app = self.app, !app.gateways.contains(where: { $0.id == profile.id }) else { return }
            // The secret is already in the Keychain; `add` would write it again.
            let store = app.add(profile, secret: profile.secret)
            // Its setup steps run inside this wizard, not as their own offer.
            store.setup.markOffered()
            self.secret = ""

        case let .beginGatewaySetup(gatewayId):
            self.app?.gateways.first { $0.id == gatewayId }?.setup.beginEmbedded()

        case let .forgetCredentials(profileId):
            GatewayProfile(id: profileId, name: "", url: "", authMode: .token).forgetCredentials()
            self.secret = ""

        case let .close(selecting):
            self.reachabilityTask?.cancel()
            self.signInTask?.cancel()
            self.discoveryTask?.cancel()
            self.discoveryTask = nil
            if let selecting, let app = self.app, app.gateways.contains(where: { $0.id == selecting }) {
                app.selectedGatewayId = selecting
                app.gateways.first { $0.id == selecting }?.setup.endEmbedded()
            }
            self.presentation = nil
            self.secret = ""
            self.state = .start(hasGateways: !(self.app?.gateways.isEmpty ?? true))
            FirstRunStore.clear(self.defaults)
            if self.app?.gateways.isEmpty ?? false { self.presentation = .window }
        }
    }
}

// MARK: Live probes

/// The real reachability check and sign-in, over the same `GatewayConnection` the app uses.
public enum FirstRunProbe {
    /// Opens a WebSocket and waits (up to `timeout`) for the Gateway's `connect.challenge` event.
    public static func checkReachability(_ url: URL, timeout: TimeInterval = 8) async -> FirstRunReachability {
        let host = url.port.map { "\(url.host ?? url.absoluteString):\($0)" } ?? (url.host ?? url.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        do {
            let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let message else { return .unreachable(FirstRunCopy.reachabilityError(URLError(.timedOut), host: host)) }
            let data: Data? = switch message {
            case let .data(data): data
            case let .string(text): Data(text.utf8)
            @unknown default: nil
            }
            guard let data, case .challenge? = GatewayConnection.inboundFrame(data) else {
                return .unreachable(FirstRunCopy.notAGateway)
            }
            return .reachable
        } catch {
            return .unreachable(FirstRunCopy.reachabilityError(error, host: host))
        }
    }

    /// Connects with `profile` (secret already in the Keychain) and reports progress until it
    /// connects or fails. Waiting for pairing approval keeps going; ending the stream stops it.
    public static func signIn(_ profile: GatewayProfile) -> AsyncStream<FirstRunSignInUpdate> {
        AsyncStream { continuation in
            let connection = GatewayConnection(profile: profile)
            let task = Task {
                await connection.setHandlers(onEvent: { _ in }, onState: { state, hello in
                    switch state {
                    case .idle:
                        break
                    case .connecting:
                        continuation.yield(.connecting)
                    case let .awaitingPairing(requestId, deviceId):
                        continuation.yield(.awaitingPairing(requestId: requestId, deviceId: deviceId))
                    case .connected:
                        continuation.yield(.connected(FirstRunVerified(serverVersion: hello?.serverVersion,
                                                                       scopes: hello?.scopes ?? [])))
                        continuation.finish()
                    case let .reconnecting(_, _, reason):
                        continuation.yield(.failed(FirstRunCopy.signInError(reason)))
                        continuation.finish()
                    case let .failed(message):
                        continuation.yield(.failed(FirstRunCopy.signInError(message)))
                        continuation.finish()
                    }
                })
                await connection.start()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await connection.stop() }
            }
        }
    }
}

// MARK: Bonjour

/// Browses `_openclaw-gw._tcp` on `local.` (upstream docs/gateway/bonjour.md). Results are hints:
/// picking one fills in the address, and signing in still checks it.
public enum FirstRunDiscovery {
    public static let serviceType = "_openclaw-gw._tcp"

    public static func browse() -> AsyncStream<[FirstRunDiscoveredGateway]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: self.serviceType, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                var seen: Set<String> = []
                let found = results.compactMap { result -> FirstRunDiscoveredGateway? in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    var txt: [String: String] = [:]
                    if case let .bonjour(record) = result.metadata {
                        for (key, entry) in record.dictionary { txt[key] = entry }
                    }
                    return FirstRunDiscoveredGateway(name: name, txt: txt)
                }
                .filter { seen.insert($0.address).inserted }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                continuation.yield(found)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            browser.start(queue: .main)
            continuation.onTermination = { _ in browser.cancel() }
        }
    }
}
