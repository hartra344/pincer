import Foundation

// MARK: Steps

/// The first-run wizard's screens, in order. `install` is the "No, I don't have one yet" detour from
/// `haveGateway`; `gatewaySetup` embeds the per-gateway `SetupWizardModel` steps.
public enum FirstRunStep: String, CaseIterable, Codable, Hashable, Sendable {
    case welcome
    case haveGateway
    case install
    case findGateway
    case signIn
    case verify
    case gatewaySetup
    case done

    public var stage: FirstRunStage {
        switch self {
        // "Do you have a Gateway?" and "Set up OpenClaw" are still getting started (product review r1).
        case .welcome, .haveGateway, .install: .welcome
        case .findGateway: .find
        case .signIn: .signIn
        case .verify: .verify
        case .gatewaySetup: .setUp
        case .done: .done
        }
    }
}

/// What the progress indicator shows: one dot per stage.
public enum FirstRunStage: Int, CaseIterable, Comparable, Hashable, Sendable {
    case welcome, find, signIn, verify, setUp, done

    public var title: String {
        switch self {
        case .welcome: "Get started"
        case .find: "Find"
        case .signIn: "Sign in"
        case .verify: "Verify"
        case .setUp: "Set up"
        case .done: "Done"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: Results fed in as events

/// The outcome of opening a WebSocket to the address and waiting for the Gateway's `connect.challenge`.
public enum FirstRunReachability: Hashable, Sendable {
    case unknown
    case checking
    case reachable
    /// With a plain-language reason (and what to try).
    case unreachable(String)

    public var error: String? { if case let .unreachable(message) = self { message } else { nil } }
    public var isChecking: Bool { self == .checking }
}

/// Where signing in is.
public enum FirstRunSignIn: Hashable, Sendable {
    case idle
    case connecting
    /// The Gateway parked a pairing request: approve it on the host with `openclaw devices approve <requestId>`.
    case awaitingPairing(requestId: String?, deviceId: String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .connecting, .awaitingPairing: true
        case .idle, .failed: false
        }
    }

    public var error: String? { if case let .failed(message) = self { message } else { nil } }
}

/// What the Verify step shows about the Gateway that accepted the sign-in.
public struct FirstRunVerified: Codable, Hashable, Sendable {
    public var serverVersion: String?
    public var scopes: [String]
    /// A scope upgrade (answering agent questions) waiting for `openclaw devices approve <id>`.
    public var questionsRequestId: String?
    /// A one-line problem from the hello snapshot's health, if any. Never blocks Continue.
    public var healthProblem: String?

    public init(serverVersion: String?, scopes: [String], questionsRequestId: String? = nil, healthProblem: String? = nil) {
        self.serverVersion = serverVersion
        self.scopes = scopes
        self.questionsRequestId = questionsRequestId
        self.healthProblem = healthProblem
    }

    public var hasFullManagement: Bool { self.scopes.contains(GatewayConnection.adminScope) }
}

/// Progress reports from a sign-in attempt, mapped from `ConnectionState`.
public enum FirstRunSignInUpdate: Hashable, Sendable {
    case connecting
    case awaitingPairing(requestId: String?, deviceId: String)
    case connected(FirstRunVerified)
    /// The Gateway refused (`ConnectionState.failed`): raw `GatewayError` text, mapped by `FirstRunCopy.signInError`.
    case failed(String)
    /// The connection dropped or couldn't open (`ConnectionState.reconnecting`): raw reason.
    case dropped(String)
}

/// Where the Gateway runs, on Find: picks the placeholder, help text and default address.
public enum FirstRunLocation: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// macOS only: fills `ws://127.0.0.1:18789`.
    case thisMac
    case tailscale
    case sameNetwork

    public var id: String { self.rawValue }

    public static let thisMacAddress = "ws://127.0.0.1:18789"

    /// The choices on this platform (This Mac only on macOS).
    public static func available(macOS: Bool) -> [Self] { macOS ? Self.allCases : [.tailscale, .sameNetwork] }

    public static func `default`(macOS: Bool) -> Self { macOS ? .thisMac : .tailscale }
}

/// A Gateway advertising `_openclaw-gw._tcp` over Bonjour. TXT records are unauthenticated hints
/// (upstream docs/gateway/bonjour.md), so picking one only fills in the address.
public struct FirstRunDiscoveredGateway: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    /// The address it fills in, e.g. `ws://studio.local:18789`.
    public var address: String

    public var id: String { "\(self.name)|\(self.address)" }

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// Builds the address from the TXT hints `lanHost`, `gatewayPort` and `gatewayTls`; the name from
    /// `displayName`, else the service name. Nil without a host.
    public init?(name: String, txt: [String: String]) {
        guard let host = txt["lanHost"]?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        let port = txt["gatewayPort"].flatMap(Int.init) ?? 18789
        let scheme = txt["gatewayTls"] == "1" ? "wss" : "ws"
        let display = (txt["displayName"]?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? name.replacingOccurrences(of: " (OpenClaw)", with: "")
        self.init(name: display.isEmpty ? host : display, address: "\(scheme)://\(host):\(port)")
    }
}

// MARK: Effects

/// Side effects the model performs after an event. The state machine never performs them itself.
public enum FirstRunEffect: Hashable, Sendable {
    case openDemo
    case startDiscovery
    case stopDiscovery
    /// Open a WebSocket and wait for `connect.challenge`; report `.reachabilityResult`.
    case checkReachability(address: String, url: URL)
    /// Store the secret in the Keychain under `profile.id`, connect, and report `.signInUpdate`s.
    case signIn(GatewayProfile)
    case cancelSignIn
    /// Save the profile (secret already in the Keychain) and select it.
    case addGateway(GatewayProfile)
    /// Show the gateway's `SetupWizardModel` steps inside the wizard.
    case beginGatewaySetup(gatewayId: UUID)
    /// Drop the Keychain secret and device token saved for a sign-in that never became a gateway.
    case forgetCredentials(profileId: UUID)
    /// Close the wizard and forget its saved state; select `gatewayId` if set.
    case close(selecting: UUID?)
}

// MARK: Events

public enum FirstRunEvent: Hashable, Sendable {
    case getStarted
    case tryDemo
    case answerHaveGateway(Bool)
    /// "My Gateway Is Running" on the install screen.
    case installed
    case back
    /// "Continue Anyway" after a failed check; "Skip to Chats" on Verify and during setup.
    case skip
    case setLocation(FirstRunLocation)
    case setAddress(String)
    case setName(String)
    /// Token ↔ password ("Use a password instead"). `.none` is only offered in Advanced.
    case setAuthMode(GatewayProfile.AuthMode)
    case discovered([FirstRunDiscoveredGateway])
    case useDiscovered(FirstRunDiscoveredGateway)
    /// Continue on Find: validates the address and checks it's reachable.
    case checkAddress
    case reachabilityResult(address: String, FirstRunReachability)
    /// Sign In. `hasSecret`: a token or password was entered.
    case signIn(hasSecret: Bool)
    case signInUpdate(FirstRunSignInUpdate)
    /// Continue Setup on Verify: saves the gateway and starts its setup steps.
    case continueToSetup
    /// The embedded per-gateway wizard finished or was closed.
    case gatewaySetupEnded
    /// Go to Chats on the last screen.
    case finish
    /// Close / Esc / ⌘.: leave the wizard.
    case cancel
}

// MARK: State machine

/// The first-run wizard as a pure value: `send(_:)` applies an event and returns the side effects
/// for `FirstRunModel` to perform. Codable so it resumes after a quit; in-flight checks
/// (`reachability`, `signInStatus`, `discovered`) aren't saved and resume as idle. Never holds secrets.
public struct FirstRunState: Codable, Hashable, Sendable {
    public private(set) var step: FirstRunStep
    /// Where this run started: `.welcome` on a fresh install, `.findGateway` from "Add Gateway…".
    public private(set) var entry: FirstRunStep
    /// Also the id of the gateway it becomes, so the Keychain secret and device token carry over.
    public private(set) var profileId: UUID
    public private(set) var location: FirstRunLocation
    /// What the user typed; `normalizedAddress` is what Pincer connects to.
    public private(set) var address: String
    public private(set) var name: String
    /// Whether the user typed the name (else it follows the address or the Bonjour name).
    public private(set) var nameEdited: Bool
    public private(set) var authMode: GatewayProfile.AuthMode
    public private(set) var verified: FirstRunVerified?
    /// Set once the profile was added to the app (leaving Verify).
    public private(set) var gatewayId: UUID?

    public private(set) var reachability: FirstRunReachability = .unknown
    public private(set) var signInStatus: FirstRunSignIn = .idle
    /// The pairing request id changed while waiting (superseded or rejected and retried).
    public private(set) var pairingRequestChanged = false
    public private(set) var discovered: [FirstRunDiscoveredGateway] = []

    public init(entry: FirstRunStep = .welcome, profileId: UUID = UUID(), location: FirstRunLocation = .tailscale) {
        self.step = entry
        self.entry = entry
        self.profileId = profileId
        self.location = location
        self.address = location == .thisMac ? FirstRunLocation.thisMacAddress : ""
        self.name = ""
        self.nameEdited = false
        self.authMode = .token
        self.verified = nil
        self.gatewayId = nil
    }

    /// A fresh run: from Welcome when there are no gateways, else straight to Find ("Add Gateway…").
    public static func start(hasGateways: Bool, macOS: Bool, profileId: UUID = UUID()) -> FirstRunState {
        FirstRunState(entry: hasGateways ? .findGateway : .welcome, profileId: profileId,
                      location: .default(macOS: macOS))
    }

    private enum CodingKeys: String, CodingKey {
        case step, entry, profileId, location, address, name, nameEdited, authMode, verified, gatewayId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let step = try container.decode(FirstRunStep.self, forKey: .step)
        self.entry = try container.decodeIfPresent(FirstRunStep.self, forKey: .entry) ?? .welcome
        self.profileId = try container.decode(UUID.self, forKey: .profileId)
        self.location = try container.decodeIfPresent(FirstRunLocation.self, forKey: .location) ?? .tailscale
        self.address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.nameEdited = try container.decodeIfPresent(Bool.self, forKey: .nameEdited) ?? false
        self.authMode = try container.decodeIfPresent(GatewayProfile.AuthMode.self, forKey: .authMode) ?? .token
        self.verified = try container.decodeIfPresent(FirstRunVerified.self, forKey: .verified)
        self.gatewayId = try container.decodeIfPresent(UUID.self, forKey: .gatewayId)
        // Signed in but quit before the gateway was saved: sign in again (the device stays paired).
        self.step = (step == .verify || step == .gatewaySetup || step == .done) && self.gatewayId == nil ? .signIn : step
    }

    // MARK: Derived

    public var stage: FirstRunStage { self.step.stage }

    /// The five connection stages the progress indicator counts ("Step N of 5").
    public static let countedStages: [FirstRunStage] = [.welcome, .find, .signIn, .verify, .setUp]

    /// 1-based "Step N of 5"; nil on Done.
    public var stepNumber: Int? { Self.countedStages.firstIndex(of: self.stage).map { $0 + 1 } }

    public var trimmedAddress: String { self.address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What Pincer connects to: bare `*.ts.net` hosts get `wss://`, other bare hosts `ws://`, and
    /// `ws://` without a port gets the Gateway's default `:18789`. `http(s)://` becomes `ws(s)://`.
    public var normalizedAddress: String { Self.normalize(self.trimmedAddress) }

    public static let defaultPort = 18789

    public static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()
        if lower.hasPrefix("https://") { text = "wss://" + text.dropFirst(8) }
        else if lower.hasPrefix("http://") { text = "ws://" + text.dropFirst(7) }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            text = (host.lowercased().hasSuffix(".ts.net") || host.lowercased().contains(".ts.net:") ? "wss://" : "ws://") + text
        }
        guard text.lowercased().hasPrefix("ws://"), let schemeEnd = text.range(of: "://") else { return text }
        let rest = text[schemeEnd.upperBound...]
        let authority = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !authority.isEmpty else { return text }
        let hasPort: Bool = if authority.hasPrefix("[") {
            authority.contains("]:")
        } else {
            authority.filter { $0 == ":" }.count == 1
        }
        guard !hasPort else { return text }
        // A bare IPv6 address needs brackets before a port can follow it.
        let host = authority.contains(":") && !authority.hasPrefix("[") ? "[\(authority)]" : authority
        let path = rest.dropFirst(authority.count)
        return "ws://\(host):\(Self.defaultPort)\(path)"
    }

    /// The name the gateway is saved with: the typed one, else one derived from the address.
    public var resolvedName: String {
        let typed = self.name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? Self.suggestedName(for: self.normalizedAddress) : typed
    }

    /// The profile a sign-in uses and the app saves: Chat & Approvals access, no TLS pin.
    public var profile: GatewayProfile {
        GatewayProfile(id: self.profileId, name: self.resolvedName, url: self.normalizedAddress, authMode: self.authMode)
    }

    /// Why the address can't be used (spec copy), or nil when it's empty or valid.
    public var addressError: String? {
        guard !self.trimmedAddress.isEmpty else { return nil }
        do {
            _ = try self.profile.resolvedURL()
            return nil
        } catch GatewayError.insecureURL {
            return FirstRunCopy.insecureAddress
        } catch {
            return FirstRunCopy.invalidAddress
        }
    }

    /// A likely problem to point out before connecting, e.g. `ws://` to a Tailscale Serve name.
    public var addressHint: String? {
        let lower = self.normalizedAddress.lowercased()
        if lower.hasPrefix("ws://"), lower.contains(".ts.net") {
            return "Tailscale Serve uses HTTPS, so this is usually wss://. Use ws:// only with the tailnet IP and port."
        }
        return nil
    }

    /// The reachability error to show, with the Tailscale hint when that's the chosen location.
    public var reachabilityMessage: String? {
        guard let error = self.reachability.error else { return nil }
        return error == FirstRunCopy.cantReach && self.location == .tailscale ? "\(error) \(FirstRunCopy.tailscaleHint)" : error
    }

    public var needsSecret: Bool { self.authMode != .none }

    /// Back: everywhere but Welcome, the embedded setup (it has its own) and Done.
    public var canGoBack: Bool {
        switch self.step {
        case .welcome, .gatewaySetup, .done: false
        default: true
        }
    }

    /// Skip exists here: "Continue Anyway" after a failed check, "Skip to Chats" on Verify and in setup.
    public var canSkip: Bool {
        switch self.step {
        case .findGateway: self.reachability.error != nil && self.addressError == nil && !self.trimmedAddress.isEmpty
        case .verify: self.verified != nil
        case .gatewaySetup: self.gatewayId != nil
        default: false
        }
    }

    public var canCheckAddress: Bool { !self.trimmedAddress.isEmpty && !self.reachability.isChecking }

    /// Worth saving to resume: moved past where it started, or typed an address.
    public var isInProgress: Bool {
        self.step != self.entry || (!self.trimmedAddress.isEmpty && self.trimmedAddress != FirstRunLocation.thisMacAddress)
    }

    /// "home.tailnet.ts.net" → "Home"; loopback → "This Mac"; IPs and the rest → "Gateway".
    public static func suggestedName(for address: String) -> String {
        guard let url = URL(string: normalize(address)), let host = url.host?.lowercased(), !host.isEmpty else { return "Gateway" }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return "This Mac" }
        let isIP = host.split(separator: ".").allSatisfy { Int($0) != nil } || host.contains(":")
        guard !isIP, let first = host.split(separator: ".").first, !first.isEmpty else { return "Gateway" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    // MARK: Transitions

    @discardableResult
    public mutating func send(_ event: FirstRunEvent) -> [FirstRunEffect] {
        switch event {
        case .getStarted:
            guard self.step == .welcome else { return [] }
            self.step = .haveGateway
            return []

        case .tryDemo:
            guard self.step == .welcome || self.step == .haveGateway || self.step == .install else { return [] }
            return [.openDemo] + self.leave(selecting: nil)

        case let .answerHaveGateway(yes):
            guard self.step == .haveGateway else { return [] }
            return self.go(to: yes ? .findGateway : .install)

        case .installed:
            guard self.step == .install else { return [] }
            return self.go(to: .findGateway)

        case .back:
            switch self.step {
            case .welcome, .gatewaySetup, .done: return []
            case .haveGateway: return self.go(to: .welcome)
            case .install: return self.go(to: .haveGateway)
            case .findGateway: return self.entry == .findGateway ? self.leave(selecting: nil) : self.go(to: .haveGateway)
            case .signIn:
                // Back from "Signing in…" or "Waiting for approval…" returns to the sign-in form.
                guard !self.signInStatus.isBusy else {
                    self.signInStatus = .idle
                    self.pairingRequestChanged = false
                    return [.cancelSignIn]
                }
                return self.go(to: .findGateway)
            case .verify:
                self.verified = nil
                return self.go(to: .signIn)
            }

        case .skip:
            guard self.canSkip else { return [] }
            switch self.step {
            case .findGateway:
                return self.go(to: .signIn)
            case .verify:
                return self.addGateway() + self.leave(selecting: self.profileId)
            case .gatewaySetup:
                return self.leave(selecting: self.gatewayId)
            default:
                return []
            }

        case let .setLocation(location):
            guard location != self.location, self.step == .findGateway else { return [] }
            if location == .thisMac, self.trimmedAddress.isEmpty {
                self.address = FirstRunLocation.thisMacAddress
            } else if self.location == .thisMac, self.trimmedAddress == FirstRunLocation.thisMacAddress {
                self.address = ""
            }
            self.location = location
            self.reachability = .unknown
            return []

        case let .setAddress(address):
            guard address != self.address, self.step == .findGateway else { return [] }
            self.address = address
            self.reachability = .unknown
            return []

        case let .setName(name):
            guard name != self.name, self.step == .verify || self.step == .findGateway else { return [] }
            self.name = name
            self.nameEdited = !name.trimmingCharacters(in: .whitespaces).isEmpty
            return []

        case let .setAuthMode(mode):
            guard mode != self.authMode, self.step == .signIn, !self.signInStatus.isBusy else { return [] }
            self.authMode = mode
            if self.signInStatus.error != nil { self.signInStatus = .idle }
            return []

        case let .discovered(gateways):
            guard gateways != self.discovered else { return [] }
            self.discovered = gateways
            return []

        case let .useDiscovered(gateway):
            guard self.step == .findGateway else { return [] }
            self.address = gateway.address
            if !self.nameEdited { self.name = gateway.name }
            self.reachability = .unknown
            return self.checkAddress()

        case .checkAddress:
            guard self.step == .findGateway, !self.reachability.isChecking else { return [] }
            return self.checkAddress()

        case let .reachabilityResult(address, result):
            guard self.step == .findGateway, address == self.normalizedAddress, self.reachability.isChecking else { return [] }
            self.reachability = result
            return result == .reachable ? self.go(to: .signIn) : []

        case let .signIn(hasSecret):
            guard self.step == .signIn, !self.signInStatus.isBusy else { return [] }
            if let error = self.addressError {
                self.signInStatus = .failed(error)
                return []
            }
            if self.needsSecret, !hasSecret {
                self.signInStatus = .failed(self.authMode == .token ? FirstRunCopy.tokenMissing : FirstRunCopy.passwordNeeded)
                return []
            }
            self.signInStatus = .connecting
            self.pairingRequestChanged = false
            return [.signIn(self.profile)]

        case let .signInUpdate(update):
            guard self.step == .signIn, self.signInStatus.isBusy else { return [] }
            switch update {
            case .connecting:
                // Retrying while waiting for approval: keep showing the waiting screen, no flashing.
                if case .awaitingPairing = self.signInStatus { return [] }
                self.signInStatus = .connecting
                return []
            case let .awaitingPairing(requestId, deviceId):
                if case let .awaitingPairing(previous?, _) = self.signInStatus, let requestId, requestId != previous {
                    self.pairingRequestChanged = true
                }
                self.signInStatus = .awaitingPairing(requestId: requestId, deviceId: deviceId)
                return []
            case let .failed(message):
                let wasPairing = if case .awaitingPairing = self.signInStatus { true } else { false }
                self.signInStatus = .failed(FirstRunCopy.signInError(message, authMode: self.authMode, whilePairing: wasPairing))
                return [.cancelSignIn]
            case let .dropped(reason):
                self.signInStatus = .failed(FirstRunCopy.signInDropped(reason))
                return [.cancelSignIn]
            case let .connected(verified):
                self.verified = verified
                self.signInStatus = .idle
                self.pairingRequestChanged = false
                if !self.nameEdited, self.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.name = Self.suggestedName(for: self.normalizedAddress)
                }
                self.step = .verify
                return [.cancelSignIn]
            }

        case .continueToSetup:
            guard self.step == .verify, self.verified != nil else { return [] }
            let effects = self.addGateway()
            self.step = .gatewaySetup
            return effects + [.beginGatewaySetup(gatewayId: self.profileId)]

        case .gatewaySetupEnded:
            // Straight to the chat list (spec 2.9: the Done screen is optional).
            guard self.step == .gatewaySetup else { return [] }
            return self.leave(selecting: self.gatewayId)

        case .finish:
            guard self.step == .done else { return [] }
            return self.leave(selecting: self.gatewayId)

        case .cancel:
            return self.leave(selecting: self.gatewayId)
        }
    }

    private mutating func addGateway() -> [FirstRunEffect] {
        guard self.gatewayId == nil else { return [] }
        self.gatewayId = self.profileId
        return [.addGateway(self.profile)]
    }

    /// Effects for the step being entered or left: discovery runs only on Find, sign-in only on Sign In.
    private mutating func go(to next: FirstRunStep) -> [FirstRunEffect] {
        let previous = self.step
        guard next != previous else { return [] }
        var effects: [FirstRunEffect] = []
        if previous == .signIn {
            if self.signInStatus.isBusy { effects.append(.cancelSignIn) }
            self.signInStatus = .idle
            self.pairingRequestChanged = false
        }
        if previous == .findGateway { effects.append(.stopDiscovery) }
        self.step = next
        if next == .findGateway {
            if self.reachability.isChecking || self.reachability == .reachable { self.reachability = .unknown }
            effects.append(.startDiscovery)
        }
        return effects
    }

    private mutating func checkAddress() -> [FirstRunEffect] {
        guard !self.trimmedAddress.isEmpty else {
            self.reachability = .unreachable(FirstRunCopy.addressMissing)
            return []
        }
        if let error = self.addressError {
            self.reachability = .unreachable(error)
            return []
        }
        guard let url = try? self.profile.resolvedURL() else { return [] }
        self.reachability = .checking
        return [.checkReachability(address: self.normalizedAddress, url: url)]
    }

    private mutating func leave(selecting gatewayId: UUID?) -> [FirstRunEffect] {
        var effects: [FirstRunEffect] = []
        if self.step == .signIn, self.signInStatus.isBusy { effects.append(.cancelSignIn) }
        if self.step == .findGateway { effects.append(.stopDiscovery) }
        if self.gatewayId == nil { effects.append(.forgetCredentials(profileId: self.profileId)) }
        effects.append(.close(selecting: gatewayId))
        self.signInStatus = .idle
        return effects
    }
}

// MARK: Persistence

/// The in-progress run, saved as JSON in the app's own UserDefaults (secrets stay in the Keychain).
public enum FirstRunStore {
    public static let key = "pincer.firstRun.v1"

    public static func load(from defaults: UserDefaults) -> FirstRunState? {
        guard let data = defaults.data(forKey: self.key) else { return nil }
        return try? JSONDecoder().decode(FirstRunState.self, from: data)
    }

    public static func save(_ state: FirstRunState, to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(state), defaults.data(forKey: self.key) != data else { return }
        defaults.set(data, forKey: self.key)
    }

    public static func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: self.key)
    }
}
