import Foundation
import Network
import Observation

// MARK: Copy

/// The wizard's plain-language messages (product spec #175 §2), and the `openclaw` commands it shows.
/// Commands verified against upstream docs: start/getting-started, gateway/troubleshooting, cli/devices,
/// gateway/tailscale.
public enum FirstRunCopy {
    public static let installCommand = "curl -fsSL https://openclaw.ai/install.sh | bash"
    public static let installCommandWindows = "iwr -useb https://openclaw.ai/install.ps1 | iex"
    public static let keepRunningCommand = "openclaw gateway install"
    public static let statusCommand = "openclaw gateway status"
    public static let tokenCommand = "openclaw config get gateway.auth.token"
    public static let passwordCommand = "openclaw config get gateway.auth.password"
    public static let listDevicesCommand = "openclaw devices list"
    public static let tailscaleServeCommands = ["openclaw config set gateway.tailscale.mode serve", "openclaw gateway restart"]
    public static let installGuideURL = URL(string: "https://docs.openclaw.ai/start/getting-started")!
    public static let chooseHelpURL = URL(string: "https://docs.openclaw.ai/gateway/remote")!

    public static func approveCommand(requestId: String?) -> String {
        requestId.map { "openclaw devices approve \($0)" } ?? self.listDevicesCommand
    }

    public static let addressMissing = "Enter your Gateway's address."
    public static let invalidAddress =
        "That doesn't look like a Gateway address. Try something like wss://my-mac.tailnet.ts.net or ws://192.168.1.20:18789."
    public static let insecureAddress =
        "For safety, Pincer only uses unencrypted ws:// on this Mac, your local network, or Tailscale. Use a wss:// address instead."
    public static let cantReach =
        "Can't reach a Gateway at that address. Make sure OpenClaw is running (openclaw gateway status) and that this device can reach it."
    public static let tailscaleHint = "Is Tailscale connected on this device?"
    public static let notAGateway = "Something answered, but it isn't an OpenClaw Gateway. Check the address and port (usually 18789)."
    public static let tlsFailed =
        "Couldn't make a secure connection to that address. If you use Tailscale Serve, check that HTTPS is enabled for your tailnet."
    public static let pinMismatch = "The Gateway's certificate doesn't match the fingerprint you entered."

    public static let tokenWrong = "That token didn't work. Copy it again with the command below and paste the whole thing."
    public static let tokenMissing = "This Gateway needs a token."
    public static let passwordWrong = "That password didn't work. Check it and try again."
    public static let passwordNeeded = "This Gateway uses a password. Choose Use a password instead."
    public static let methodMismatch = "This Gateway isn't set up for that sign-in method. Try the other one."
    public static let rateLimited = "Too many tries. Wait a minute, then try again."
    public static let versionMismatch = "This Gateway's version doesn't work with this Pincer. Update OpenClaw or Pincer."
    public static let deviceTurnedDown =
        "The Gateway turned down this device. Go back and try again, or approve it with the command above."
    public static let requestChanged = "The request changed. Use this new command."

    /// The `[CODE]` suffix of `GatewayError.rpc` text, if any.
    static func code(in message: String) -> String? {
        message.range(of: #"\[([A-Z_]+)\]\s*$"#, options: .regularExpression)
            .map { String(message[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
    }

    /// A refused sign-in (`ConnectionState.failed` text, "message [CODE]") as spec copy.
    public static func signInError(_ message: String, authMode: GatewayProfile.AuthMode, whilePairing: Bool = false) -> String {
        let code = self.code(in: message)
        switch code {
        case "AUTH_TOKEN_MISMATCH": return self.tokenWrong
        case "AUTH_UNAUTHORIZED": return authMode == .password ? self.passwordWrong : self.tokenWrong
        case "AUTH_PASSWORD_MISMATCH": return self.passwordWrong
        case "AUTH_TOKEN_MISSING": return self.tokenMissing
        case "AUTH_PASSWORD_MISSING": return self.passwordNeeded
        case "AUTH_TOKEN_NOT_CONFIGURED", "AUTH_PASSWORD_NOT_CONFIGURED": return self.methodMismatch
        case "AUTH_RATE_LIMITED": return self.rateLimited
        case "PROTOCOL_MISMATCH", "CLIENT_VERSION_MISMATCH": return self.versionMismatch
        default: break
        }
        if whilePairing, let code, code.hasPrefix("DEVICE_") || code.hasPrefix("AUTH_") { return self.deviceTurnedDown }
        if self.isRateLimit(message) { return self.rateLimited }
        if code == nil, message.localizedCaseInsensitiveContains("invalid") && message.contains("Gateway address") {
            return self.invalidAddress
        }
        return message
    }

    /// A sign-in whose connection dropped or never opened (`ConnectionState.reconnecting`).
    public static func signInDropped(_ reason: String) -> String {
        self.isRateLimit(reason) ? self.rateLimited : self.cantReach
    }

    private static func isRateLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("rate limit") || lower.contains("too many failed")
    }

    /// Why a WebSocket to the Gateway didn't open.
    public static func reachabilityError(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?,
             .serverCertificateNotYetValid?, .secureConnectionFailed?, .clientCertificateRejected?:
            return self.tlsFailed
        case .badServerResponse?:
            return self.notAGateway
        default:
            return self.cantReach
        }
    }

    /// One line from the hello snapshot's health, when it reports a problem (channels aren't setup's concern).
    /// Under Welcome's Try the Demo.
    public static let demoCaption = "No gateway needed. Explore sample agents and chats. Nothing leaves this device."

    /// Verify's health line: plain words, with Details for the specifics (product review r1).
    public static let healthReported = "Your Gateway reported a problem. You can keep going and check it later."
    public static let approveElsewhere =
        "Already use Pincer on another device with Full Management? You can approve this one there, in Gateway Settings → Devices."

    public static func healthProblem(_ health: GatewayHealthSummary?) -> String? {
        guard let health else { return nil }
        if let plugin = health.pluginErrors.first { return "The \(plugin.id) plugin failed to load." }
        if let queue = health.failedQueues.first(where: { $0.count > 0 }) {
            return "\(queue.count) queued \(queue.count == 1 ? "item" : "items") failed in \(queue.queueName)."
        }
        if !health.unavailablePlugins.isEmpty {
            return "Unavailable plugins: \(health.unavailablePlugins.joined(separator: ", "))."
        }
        return nil
    }
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
        } else {
            self.state = .start(hasGateways: hasGateways, macOS: Self.isMacOS)
            self.presentation = hasGateways ? nil : .window
        }
    }

    public var isPresented: Bool { self.presentation != nil }

    public nonisolated static var isMacOS: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

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
            self.state = .start(hasGateways: hasGateways, macOS: Self.isMacOS)
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
            self.state = .start(hasGateways: false, macOS: Self.isMacOS)
            self.secret = ""
        }
        self.presentation = .window
        self.resumeEffects()
    }

    /// A gateway was added some other way (Advanced…, the demo, a deep link): the run that filled
    /// the window gives way to it. Its own `addGateway` is ignored.
    func gatewayAdded(_ id: UUID) {
        guard id != self.state.gatewayId, self.presentation != nil, self.state.gatewayId == nil else { return }
        self.send(.cancel)
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
            self.state = .start(hasGateways: !(self.app?.gateways.isEmpty ?? true), macOS: Self.isMacOS)
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
            guard let message else { return .unreachable(FirstRunCopy.cantReach) }
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
            return .unreachable(FirstRunCopy.reachabilityError(error))
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
                        let health = hello?.snapshot?["health"].flatMap(GatewayHealthSummary.init)
                        continuation.yield(.connected(FirstRunVerified(
                            serverVersion: hello?.serverVersion, scopes: hello?.scopes ?? [],
                            questionsRequestId: hello?.scopeUpgradeRequestId,
                            healthProblem: FirstRunCopy.healthProblem(health))))
                        continuation.finish()
                    case let .reconnecting(_, _, reason):
                        continuation.yield(.dropped(reason))
                        continuation.finish()
                    case let .failed(message):
                        continuation.yield(.failed(message))
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
