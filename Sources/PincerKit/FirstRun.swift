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
        case .welcome: .welcome
        case .haveGateway, .install, .findGateway: .find
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
        case .welcome: "Welcome"
        case .find: "Find"
        case .signIn: "Sign In"
        case .verify: "Verify"
        case .setUp: "Set Up"
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

    public init(serverVersion: String?, scopes: [String]) {
        self.serverVersion = serverVersion
        self.scopes = scopes
    }

    public var hasFullManagement: Bool { self.scopes.contains(GatewayConnection.adminScope) }
}

/// Progress reports from a sign-in attempt, mapped from `ConnectionState`.
public enum FirstRunSignInUpdate: Hashable, Sendable {
    case connecting
    case awaitingPairing(requestId: String?, deviceId: String)
    case connected(FirstRunVerified)
    case failed(String)
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

    /// Builds the address from the TXT hints `lanHost`, `gatewayPort` and `gatewayTls`; nil without a host.
    public init?(name: String, txt: [String: String]) {
        guard let host = txt["lanHost"]?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        let port = txt["gatewayPort"].flatMap(Int.init) ?? 18789
        let scheme = txt["gatewayTls"] == "1" ? "wss" : "ws"
        let displayName = name.replacingOccurrences(of: " (OpenClaw)", with: "")
        self.init(name: displayName.isEmpty ? host : displayName, address: "\(scheme)://\(host):\(port)")
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
    /// "I've Started It" on the install screen.
    case installed
    case back
    case skip
    case setAddress(String)
    case setName(String)
    case setAuthMode(GatewayProfile.AuthMode)
    case discovered([FirstRunDiscoveredGateway])
    case useDiscovered(FirstRunDiscoveredGateway)
    /// Continue on Find: validates the address and checks it's reachable.
    case checkAddress
    case reachabilityResult(address: String, FirstRunReachability)
    /// Sign In. `hasSecret`: a token or password was entered (or is saved for this attempt).
    case signIn(hasSecret: Bool)
    case signInUpdate(FirstRunSignInUpdate)
    /// Continue on Verify.
    case continueToSetup
    /// The embedded per-gateway wizard finished or was closed.
    case gatewaySetupEnded
    /// Done on the last screen.
    case finish
    /// Cancel / Set Up Later / Esc: leave the wizard.
    case cancel
}

// MARK: State machine

/// The first-run wizard as a pure value: `send(_:)` applies an event and returns the side effects
/// for `FirstRunModel` to perform. Codable so it resumes after a quit; in-flight checks
/// (`reachability`, `signIn`, `discovered`) aren't saved and resume as idle. Never holds secrets.
public struct FirstRunState: Codable, Hashable, Sendable {
    public private(set) var step: FirstRunStep
    /// Where this run started: `.welcome` on a fresh install, `.haveGateway` from "Add Gateway…".
    public private(set) var entry: FirstRunStep
    /// Also the id of the gateway it becomes, so the Keychain secret and device token carry over.
    public private(set) var profileId: UUID
    public private(set) var address: String
    public private(set) var name: String
    /// Whether the user typed the name (else it follows the address).
    public private(set) var nameEdited: Bool
    public private(set) var authMode: GatewayProfile.AuthMode
    public private(set) var verified: FirstRunVerified?
    /// Set once the profile was added to the app.
    public private(set) var gatewayId: UUID?
    /// The embedded per-gateway wizard was skipped ("Set Up Later").
    public private(set) var skippedGatewaySetup: Bool

    public private(set) var reachability: FirstRunReachability = .unknown
    public private(set) var signInStatus: FirstRunSignIn = .idle
    public private(set) var discovered: [FirstRunDiscoveredGateway] = []

    public init(entry: FirstRunStep = .welcome, profileId: UUID = UUID()) {
        self.step = entry
        self.entry = entry
        self.profileId = profileId
        self.address = ""
        self.name = ""
        self.nameEdited = false
        self.authMode = .token
        self.verified = nil
        self.gatewayId = nil
        self.skippedGatewaySetup = false
    }

    /// A fresh run: from Welcome when there are no gateways, else straight to "Do you have a gateway?".
    public static func start(hasGateways: Bool, profileId: UUID = UUID()) -> FirstRunState {
        FirstRunState(entry: hasGateways ? .haveGateway : .welcome, profileId: profileId)
    }

    private enum CodingKeys: String, CodingKey {
        case step, entry, profileId, address, name, nameEdited, authMode, verified, gatewayId, skippedGatewaySetup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let step = try container.decode(FirstRunStep.self, forKey: .step)
        self.entry = try container.decodeIfPresent(FirstRunStep.self, forKey: .entry) ?? .welcome
        self.profileId = try container.decode(UUID.self, forKey: .profileId)
        self.address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.nameEdited = try container.decodeIfPresent(Bool.self, forKey: .nameEdited) ?? false
        self.authMode = try container.decodeIfPresent(GatewayProfile.AuthMode.self, forKey: .authMode) ?? .token
        self.verified = try container.decodeIfPresent(FirstRunVerified.self, forKey: .verified)
        self.gatewayId = try container.decodeIfPresent(UUID.self, forKey: .gatewayId)
        self.skippedGatewaySetup = try container.decodeIfPresent(Bool.self, forKey: .skippedGatewaySetup) ?? false
        // Signed in but the app quit before the gateway was saved: sign in again.
        self.step = (step == .verify || step == .gatewaySetup) && self.gatewayId == nil ? .signIn : step
    }

    // MARK: Derived

    public var stage: FirstRunStage { self.step.stage }

    /// Stages shown in the progress indicator (Welcome only on a fresh install).
    public var stages: [FirstRunStage] {
        self.entry == .welcome ? FirstRunStage.allCases : FirstRunStage.allCases.filter { $0 != .welcome }
    }

    /// 0-based position of the current stage in `stages`.
    public var stageIndex: Int { self.stages.firstIndex(of: self.stage) ?? 0 }

    public var trimmedAddress: String { self.address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The name the gateway is saved with: the typed one, else one derived from the address.
    public var resolvedName: String {
        let typed = self.name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? Self.suggestedName(for: self.trimmedAddress) : typed
    }

    /// The profile a sign-in uses and the app saves: Chat & Approvals access, no TLS pin.
    public var profile: GatewayProfile {
        GatewayProfile(id: self.profileId, name: self.resolvedName, url: self.trimmedAddress, authMode: self.authMode)
    }

    /// Why the address can't be used, or nil when it's empty or valid.
    public var addressError: String? {
        guard !self.trimmedAddress.isEmpty else { return nil }
        do {
            _ = try self.profile.resolvedURL()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A likely problem to point out before connecting, e.g. `ws://` to a Tailscale Serve name.
    public var addressHint: String? {
        let lower = self.trimmedAddress.lowercased()
        if lower.hasPrefix("ws://"), lower.contains(".ts.net") {
            return "Tailscale Serve uses HTTPS, so this is usually wss://. Use ws:// only with the tailnet IP and port."
        }
        return nil
    }

    public var needsSecret: Bool { self.authMode != .none }

    public var canGoBack: Bool { self.previousStep != nil }

    /// Skip exists here: "Connect Anyway" after a failed check, "Skip Setup" on Verify, "Set Up Later".
    public var canSkip: Bool {
        switch self.step {
        case .findGateway: self.reachability.error != nil && self.addressError == nil && !self.trimmedAddress.isEmpty
        case .verify, .gatewaySetup: self.gatewayId != nil
        default: false
        }
    }

    public var canCheckAddress: Bool {
        !self.trimmedAddress.isEmpty && !self.reachability.isChecking
    }

    public var isInProgress: Bool { self.step != self.entry || !self.trimmedAddress.isEmpty }

    private var previousStep: FirstRunStep? {
        switch self.step {
        case .welcome, .done: nil
        case .haveGateway: self.entry == .welcome ? .welcome : nil
        case .install: .haveGateway
        case .findGateway: .haveGateway
        case .signIn: .findGateway
        // The gateway is saved once signed in; there's nothing to go back to.
        case .verify, .gatewaySetup: nil
        }
    }

    /// "home.tailnet.ts.net" → "home"; "localhost" → "This Computer"; IPs and the rest → "Gateway".
    public static func suggestedName(for address: String) -> String {
        var raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = raw.range(of: "://") { raw = String(raw[range.upperBound...]) }
        let host = raw.split(separator: "/").first.map(String.init) ?? ""
        let hostOnly = (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
        if hostOnly == "localhost" || hostOnly == "127.0.0.1" || hostOnly == "::1" { return "This Computer" }
        let isIP = hostOnly.split(separator: ".").allSatisfy { Int($0) != nil } || hostOnly.contains(":")
        guard !hostOnly.isEmpty, !isIP, let first = hostOnly.split(separator: ".").first, !first.isEmpty else {
            return "Gateway"
        }
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
            return self.leave(selecting: nil) + [.openDemo]

        case let .answerHaveGateway(yes):
            guard self.step == .haveGateway else { return [] }
            return yes ? self.go(to: .findGateway) : self.go(to: .install)

        case .installed:
            guard self.step == .install else { return [] }
            return self.go(to: .findGateway)

        case .back:
            guard let previous = self.previousStep else { return [] }
            return self.go(to: previous)

        case .skip:
            guard self.canSkip else { return [] }
            switch self.step {
            case .findGateway:
                return self.go(to: .signIn)
            case .verify, .gatewaySetup:
                self.skippedGatewaySetup = true
                self.step = .done
                return []
            default:
                return []
            }

        case let .setAddress(address):
            guard address != self.address, self.step == .findGateway else { return [] }
            self.address = address
            self.reachability = .unknown
            return []

        case let .setName(name):
            guard name != self.name, self.step == .findGateway || self.step == .signIn else { return [] }
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
            guard self.step == .findGateway else { return [] }
            return self.checkAddress()

        case let .reachabilityResult(address, result):
            guard self.step == .findGateway, address == self.trimmedAddress, self.reachability.isChecking else { return [] }
            self.reachability = result
            return result == .reachable ? self.go(to: .signIn) : []

        case let .signIn(hasSecret):
            guard self.step == .signIn, !self.signInStatus.isBusy else { return [] }
            if let error = self.addressError {
                self.signInStatus = .failed(error)
                return []
            }
            if self.needsSecret, !hasSecret {
                self.signInStatus = .failed(self.authMode == .token ? "Enter the Gateway token." : "Enter the Gateway password.")
                return []
            }
            self.signInStatus = .connecting
            return [.signIn(self.profile)]

        case let .signInUpdate(update):
            guard self.step == .signIn, self.signInStatus.isBusy else { return [] }
            switch update {
            case .connecting:
                self.signInStatus = .connecting
                return []
            case let .awaitingPairing(requestId, deviceId):
                self.signInStatus = .awaitingPairing(requestId: requestId, deviceId: deviceId)
                return []
            case let .failed(message):
                self.signInStatus = .failed(message)
                return [.cancelSignIn]
            case let .connected(verified):
                self.verified = verified
                self.signInStatus = .idle
                self.gatewayId = self.profileId
                self.step = .verify
                return [.cancelSignIn, .addGateway(self.profile)]
            }

        case .continueToSetup:
            guard self.step == .verify, let gatewayId = self.gatewayId else { return [] }
            self.step = .gatewaySetup
            return [.beginGatewaySetup(gatewayId: gatewayId)]

        case .gatewaySetupEnded:
            guard self.step == .gatewaySetup else { return [] }
            self.step = .done
            return []

        case .finish:
            guard self.step == .done else { return [] }
            return self.leave(selecting: self.gatewayId)

        case .cancel:
            return self.leave(selecting: self.gatewayId)
        }
    }

    /// Effects for the step being entered or left: discovery runs only on Find, sign-in only on Sign In.
    private mutating func go(to next: FirstRunStep) -> [FirstRunEffect] {
        let previous = self.step
        guard next != previous else { return [] }
        var effects: [FirstRunEffect] = []
        if previous == .signIn, self.signInStatus.isBusy { effects.append(.cancelSignIn) }
        if previous == .signIn { self.signInStatus = .idle }
        if previous == .findGateway { effects.append(.stopDiscovery) }
        self.step = next
        if next == .findGateway {
            if self.reachability.isChecking { self.reachability = .unknown }
            effects.append(.startDiscovery)
        }
        return effects
    }

    private mutating func checkAddress() -> [FirstRunEffect] {
        let address = self.trimmedAddress
        guard !address.isEmpty else {
            self.reachability = .unreachable("Enter your Gateway's address.")
            return []
        }
        let url: URL
        do {
            url = try self.profile.resolvedURL()
        } catch {
            self.reachability = .unreachable(error.localizedDescription)
            return []
        }
        self.reachability = .checking
        return [.checkReachability(address: address, url: url)]
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
        guard let data = try? JSONEncoder().encode(state) else { return }
        guard defaults.data(forKey: self.key) != data else { return }
        defaults.set(data, forKey: self.key)
    }

    public static func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: self.key)
    }
}
