import Foundation
import Testing
@testable import PincerKit

// The first-run wizard (#175): the pure state machine, its copy, and the model that drives it.

private let sampleVerified = FirstRunVerified(serverVersion: "2026.9.1", scopes: ["operator.read", "operator.write"])
private let loopback = "ws://127.0.0.1:18789"

private extension FirstRunState {
    /// A run from Welcome (or `entry`) walked forward to `step` with `address`.
    static func at(_ step: FirstRunStep, address: String = loopback, entry: FirstRunStep = .welcome,
                   location: FirstRunLocation = .tailscale) -> FirstRunState
    {
        var state = FirstRunState(entry: entry, location: location)
        if step == entry { return state }
        if state.step == .welcome { state.send(.getStarted) }
        if step == .haveGateway { return state }
        if state.step == .haveGateway {
            if step == .install {
                state.send(.answerHaveGateway(false))
                return state
            }
            state.send(.answerHaveGateway(true))
        }
        if step == .findGateway { return state }
        state.send(.setAddress(address))
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: state.normalizedAddress, .reachable))
        if step == .signIn { return state }
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.connected(sampleVerified)))
        if step == .verify { return state }
        state.send(.continueToSetup)
        if step == .gatewaySetup { return state }
        // Setup ending closes straight to the chats (spec 2.9), so Done is only reached from a saved run.
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["step"] = step.rawValue
        return try! JSONDecoder().decode(FirstRunState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func roundTripped() throws -> FirstRunState {
        try JSONDecoder().decode(FirstRunState.self, from: JSONEncoder().encode(self))
    }
}

@Suite("First-run wizard state")
struct FirstRunStateTests {
    // MARK: Entry

    @Test func freshInstallStartsAtWelcome() {
        let mac = FirstRunState.start(hasGateways: false, macOS: true)
        #expect(mac.step == .welcome && mac.entry == .welcome)
        #expect(mac.location == .thisMac && mac.address == FirstRunLocation.thisMacAddress, "on a Mac, This Mac is prefilled")
        let phone = FirstRunState.start(hasGateways: false, macOS: false)
        #expect(phone.location == .tailscale && phone.address.isEmpty)
        #expect(!mac.isInProgress && !phone.isInProgress, "an untouched Welcome isn't worth resuming")
        #expect(mac.gatewayId == nil && mac.verified == nil && mac.authMode == .token)
    }

    @Test func addGatewayStartsAtFind() {
        let id = UUID()
        let state = FirstRunState.start(hasGateways: true, macOS: false, profileId: id)
        #expect(state.step == .findGateway && state.entry == .findGateway)
        #expect(state.profileId == id)
        #expect(!state.isInProgress)
    }

    @Test func locations() {
        #expect(FirstRunLocation.available(macOS: true) == [.thisMac, .tailscale, .sameNetwork])
        #expect(FirstRunLocation.available(macOS: false) == [.tailscale, .sameNetwork])
        #expect(FirstRunLocation.default(macOS: true) == .thisMac)
        #expect(FirstRunLocation.default(macOS: false) == .tailscale)
    }

    @Test func progressCountsFiveSteps() {
        #expect(FirstRunState.countedStages.count == 5)
        let numbers = [FirstRunStep.welcome, .haveGateway, .install, .findGateway, .signIn, .verify, .gatewaySetup, .done]
            .map { FirstRunState.at($0).stepNumber }
        #expect(numbers == [1, 1, 1, 2, 3, 4, 5, nil], "Welcome, Have a gateway? and Install are all Get started")
        #expect(FirstRunStage.find < FirstRunStage.signIn)
        #expect(FirstRunStage.allCases.map(\.title).allSatisfy { !$0.isEmpty })
    }

    /// The header FirstRunView builds from the model: "Step N of 5 · <stage title>" (product review r1).
    @Test(arguments: [FirstRunStep.welcome, .haveGateway, .install])
    func getStartedStepsAreStepOne(_ step: FirstRunStep) throws {
        let state = FirstRunState.at(step)
        let number = try #require(state.stepNumber)
        #expect("Step \(number) of \(FirstRunState.countedStages.count) · \(state.stage.title)" == "Step 1 of 5 · Get started")
    }

    @Test func demoCaption() {
        #expect(FirstRunCopy.demoCaption == "No gateway needed. Explore sample agents and chats. Nothing leaves this device.")
    }

    // MARK: Welcome, Have a gateway?, Install

    @Test func getStarted() {
        var state = FirstRunState(entry: .welcome)
        #expect(state.send(.getStarted).isEmpty)
        #expect(state.step == .haveGateway)
        #expect(state.isInProgress)
        let again = state
        #expect(state.send(.getStarted).isEmpty && state == again, "Get Started only applies on Welcome")
    }

    @Test func haveGatewayYesGoesToFind() {
        var state = FirstRunState.at(.haveGateway)
        #expect(state.send(.answerHaveGateway(true)) == [.startDiscovery])
        #expect(state.step == .findGateway)
    }

    @Test func haveGatewayNoGoesToInstall() {
        var state = FirstRunState.at(.haveGateway)
        #expect(state.send(.answerHaveGateway(false)).isEmpty)
        #expect(state.step == .install)
        #expect(state.send(.installed) == [.startDiscovery])
        #expect(state.step == .findGateway)
    }

    @Test func eventsOffTheirStepAreIgnored() {
        let welcome = FirstRunState.at(.welcome)
        let ignored: [FirstRunEvent] = [
            .answerHaveGateway(true), .installed, .setAddress("x"), .checkAddress, .signIn(hasSecret: true),
            .signInUpdate(.connected(sampleVerified)), .continueToSetup, .gatewaySetupEnded, .finish, .skip, .back,
            .setAuthMode(.password), .useDiscovered(FirstRunDiscoveredGateway(name: "A", address: loopback)),
            .reachabilityResult(address: loopback, .reachable), .setLocation(.sameNetwork),
        ]
        for event in ignored {
            var state = welcome
            #expect(state.send(event).isEmpty, "\(event) on Welcome")
            #expect(state == welcome, "\(event) leaves Welcome alone")
        }
    }

    // MARK: Try the Demo

    @Test(arguments: [FirstRunStep.welcome, .haveGateway, .install])
    func tryDemo(from step: FirstRunStep) {
        var state = FirstRunState.at(step)
        let effects = state.send(.tryDemo)
        // The demo is added before closing, so the wizard doesn't stay up over "no gateways".
        #expect(effects == [.openDemo, .forgetCredentials(profileId: state.profileId), .close(selecting: nil)])
    }

    @Test(arguments: [FirstRunStep.findGateway, .signIn, .verify, .gatewaySetup, .done])
    func tryDemoOnlyBeforeFind(from step: FirstRunStep) {
        var state = FirstRunState.at(step)
        #expect(state.send(.tryDemo).isEmpty)
    }

    // MARK: Back

    @Test func backEverywhere() {
        var have = FirstRunState.at(.haveGateway)
        #expect(have.send(.back).isEmpty && have.step == .welcome)

        var install = FirstRunState.at(.install)
        #expect(install.send(.back).isEmpty && install.step == .haveGateway)

        var find = FirstRunState.at(.findGateway)
        #expect(find.send(.back) == [.stopDiscovery] && find.step == .haveGateway)

        var signIn = FirstRunState.at(.signIn)
        #expect(signIn.send(.back) == [.startDiscovery] && signIn.step == .findGateway)
        #expect(signIn.address == loopback, "the address is kept")
        #expect(signIn.reachability == .unknown, "and checked again")

        var verify = FirstRunState.at(.verify)
        #expect(verify.send(.back).isEmpty && verify.step == .signIn)
        #expect(verify.verified == nil && verify.gatewayId == nil)
    }

    @Test func backWhileSigningInCancelsIt() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev")))
        #expect(state.send(.back) == [.cancelSignIn], "Back from Waiting for approval returns to the form")
        #expect(state.step == .signIn && state.signInStatus == .idle && !state.pairingRequestChanged)
        #expect(state.send(.back) == [.startDiscovery])
        #expect(state.step == .findGateway)
    }

    @Test func backFromAddGatewayFindCloses() {
        var state = FirstRunState.start(hasGateways: true, macOS: false)
        #expect(state.canGoBack)
        #expect(state.send(.back) == [.stopDiscovery, .forgetCredentials(profileId: state.profileId), .close(selecting: nil)])
    }

    @Test func noBackOnWelcomeSetupOrDone() {
        for step in [FirstRunStep.welcome, .gatewaySetup, .done] {
            var state = FirstRunState.at(step)
            #expect(!state.canGoBack, "\(step)")
            let before = state
            #expect(state.send(.back).isEmpty && state == before, "\(step)")
        }
        for step in [FirstRunStep.haveGateway, .install, .findGateway, .signIn, .verify] {
            #expect(FirstRunState.at(step).canGoBack, "\(step)")
        }
    }

    // MARK: Find your Gateway

    @Test func setAddressResetsTheCheck() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("ws://127.0.0.1:1"))
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: "ws://127.0.0.1:1", .unreachable(FirstRunCopy.cantReach)))
        #expect(state.reachability.error != nil)
        state.send(.setAddress("ws://127.0.0.1:2"))
        #expect(state.reachability == .unknown)
    }

    @Test func emptyAddress() {
        var state = FirstRunState.at(.findGateway)
        #expect(!state.canCheckAddress)
        #expect(state.send(.checkAddress).isEmpty)
        #expect(state.reachability == .unreachable(FirstRunCopy.addressMissing))
        #expect(state.addressError == nil, "an empty field isn't an error until checked")
        #expect(!state.canSkip)
    }

    @Test(arguments: ["ftp://example.com", "ws://", "wss://exa mple.com"])
    func invalidAddress(_ address: String) {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress(address))
        #expect(state.addressError == FirstRunCopy.invalidAddress)
        #expect(state.send(.checkAddress).isEmpty, "no network check for a bad address")
        #expect(state.reachability == .unreachable(FirstRunCopy.invalidAddress))
        #expect(!state.canSkip, "Continue Anyway needs a usable address")
    }

    @Test(arguments: ["ws://example.com", "ws://8.8.8.8:18789", "http://gateway.example.com"])
    func insecureAddress(_ address: String) {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress(address))
        #expect(state.addressError == FirstRunCopy.insecureAddress)
        #expect(state.send(.checkAddress).isEmpty)
        #expect(state.reachability.error == FirstRunCopy.insecureAddress)
        #expect(!state.canSkip, "no Continue Anyway for an address Pincer won't use")
    }

    @Test func checkAddressProbesTheNormalizedURL() throws {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("  192.168.1.20  "))
        let effects = state.send(.checkAddress)
        #expect(effects == [.checkReachability(address: "ws://192.168.1.20:18789", url: try #require(URL(string: "ws://192.168.1.20:18789")))])
        #expect(state.reachability == .checking && !state.canCheckAddress)
        #expect(state.send(.checkAddress).isEmpty, "one check at a time")
    }

    @Test func reachableGoesToSignIn() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress(loopback))
        state.send(.checkAddress)
        #expect(state.send(.reachabilityResult(address: loopback, .reachable)) == [.stopDiscovery])
        #expect(state.step == .signIn && state.reachability == .reachable)
    }

    @Test func staleReachabilityResultIsIgnored() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress(loopback))
        state.send(.checkAddress)
        state.send(.setAddress("ws://127.0.0.1:1"))
        #expect(state.send(.reachabilityResult(address: loopback, .reachable)).isEmpty)
        #expect(state.step == .findGateway && state.reachability == .unknown)
        // Not checking any more, so a late result is dropped too.
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: "ws://127.0.0.1:1", .unreachable("x")))
        #expect(state.send(.reachabilityResult(address: "ws://127.0.0.1:1", .reachable)).isEmpty)
        #expect(state.step == .findGateway)
    }

    @Test func unreachableOffersContinueAnyway() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("ws://127.0.0.1:1"))
        #expect(!state.canSkip, "nothing to skip before a check fails")
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: "ws://127.0.0.1:1", .unreachable(FirstRunCopy.cantReach)))
        #expect(state.step == .findGateway)
        // canSkip is what swaps the primary to "Try Again" with Continue Anyway beside it (FirstRunView).
        #expect(state.canSkip && state.canCheckAddress)
        #expect(state.reachability.error == FirstRunCopy.cantReach)
        #expect(state.send(.skip) == [.stopDiscovery])
        #expect(state.step == .signIn)
    }

    @Test func notAGatewayStaysOnFind() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress(loopback))
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: loopback, .unreachable(FirstRunCopy.notAGateway)))
        #expect(state.step == .findGateway && state.reachabilityMessage == FirstRunCopy.notAGateway)
    }

    @Test func tailscaleHintOnlyForTailscale() {
        var tailscale = FirstRunState.at(.findGateway, location: .tailscale)
        tailscale.send(.setAddress("wss://home.tail1234.ts.net"))
        tailscale.send(.checkAddress)
        tailscale.send(.reachabilityResult(address: "wss://home.tail1234.ts.net", .unreachable(FirstRunCopy.cantReach)))
        #expect(tailscale.reachabilityMessage == "\(FirstRunCopy.cantReach) \(FirstRunCopy.tailscaleHint)")

        var lan = FirstRunState.at(.findGateway, location: .sameNetwork)
        lan.send(.setAddress("192.168.1.20"))
        lan.send(.checkAddress)
        lan.send(.reachabilityResult(address: "ws://192.168.1.20:18789", .unreachable(FirstRunCopy.cantReach)))
        #expect(lan.reachabilityMessage == FirstRunCopy.cantReach)
    }

    @Test func addressHintForWsTailscale() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("ws://home.tail1234.ts.net"))
        #expect(state.addressHint?.contains("wss://") == true)
        state.send(.setAddress("wss://home.tail1234.ts.net"))
        #expect(state.addressHint == nil)
    }

    @Test func setLocation() {
        var state = FirstRunState.at(.findGateway, location: .tailscale)
        state.send(.setLocation(.thisMac))
        #expect(state.location == .thisMac && state.address == FirstRunLocation.thisMacAddress, "This Mac fills in loopback")
        state.send(.setLocation(.sameNetwork))
        #expect(state.address.isEmpty, "the untouched loopback default goes away")
        state.send(.setAddress("192.168.1.20"))
        state.send(.setLocation(.thisMac))
        #expect(state.address == "192.168.1.20", "a typed address is kept")
        state.send(.setLocation(.tailscale))
        #expect(state.address == "192.168.1.20")
    }

    @Test(arguments: [
        ("192.168.1.20", "ws://192.168.1.20:18789"),
        ("localhost", "ws://localhost:18789"),
        ("127.0.0.1", "ws://127.0.0.1:18789"),
        ("ws://127.0.0.1", "ws://127.0.0.1:18789"),
        ("ws://127.0.0.1:19000", "ws://127.0.0.1:19000"),
        ("ws://studio.local/gw", "ws://studio.local:18789/gw"),
        ("http://10.0.0.2:18789", "ws://10.0.0.2:18789"),
        ("home.tail1234.ts.net", "wss://home.tail1234.ts.net"),
        ("https://home.tail1234.ts.net", "wss://home.tail1234.ts.net"),
        ("wss://gateway.example.com", "wss://gateway.example.com"),
        ("ws://[::1]", "ws://[::1]:18789"),
        ("ws://[::1]:19000", "ws://[::1]:19000"),
        ("::1", "ws://[::1]:18789"),
        ("  ws://127.0.0.1:18789  ", "ws://127.0.0.1:18789"),
        ("", ""),
    ])
    func normalize(_ raw: String, _ expected: String) {
        #expect(FirstRunState.normalize(raw) == expected)
    }

    @Test func bareIPConnects() throws {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("::1"))
        #expect(state.addressError == nil)
        #expect(try state.profile.resolvedURL().port == 18789)
    }

    @Test(arguments: [
        ("wss://home.tail1234.ts.net", "Home"),
        ("studio.local", "Studio"),
        ("ws://localhost:18789", "This Mac"),
        ("127.0.0.1", "This Mac"),
        ("::1", "This Mac"),
        ("192.168.1.20", "Gateway"),
        ("", "Gateway"),
    ])
    func suggestedName(_ address: String, _ expected: String) {
        #expect(FirstRunState.suggestedName(for: address) == expected)
    }

    // MARK: Discovery

    @Test func discoveredTXT() {
        let plain = FirstRunDiscoveredGateway(name: "Studio (OpenClaw)", txt: ["lanHost": "studio.local."])
        #expect(plain == FirstRunDiscoveredGateway(name: "Studio", address: "ws://studio.local:18789"))
        let tls = FirstRunDiscoveredGateway(name: "x", txt: ["lanHost": "studio.local", "gatewayPort": "19000", "gatewayTls": "1", "displayName": "Studio Mac"])
        #expect(tls == FirstRunDiscoveredGateway(name: "Studio Mac", address: "wss://studio.local:19000"))
        #expect(FirstRunDiscoveredGateway(name: "x", txt: [:]) == nil, "no host, no hint")
        #expect(FirstRunDiscoveredGateway(name: "x", txt: ["lanHost": " "]) == nil)
    }

    @Test func useDiscoveredFillsAndChecks() throws {
        var state = FirstRunState.at(.findGateway)
        let studio = FirstRunDiscoveredGateway(name: "Studio", address: "ws://studio.local:18789")
        state.send(.discovered([studio]))
        #expect(state.discovered == [studio])
        let effects = state.send(.useDiscovered(studio))
        #expect(effects == [.checkReachability(address: studio.address, url: try #require(URL(string: studio.address)))])
        #expect(state.address == studio.address && state.name == "Studio")
        #expect(state.reachability == .checking)
    }

    @Test func useDiscoveredKeepsATypedName() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setName("Office"))
        #expect(state.nameEdited)
        state.send(.useDiscovered(FirstRunDiscoveredGateway(name: "Studio", address: "ws://studio.local:18789")))
        #expect(state.name == "Office" && state.resolvedName == "Office")
    }

    @Test func discoveredAppliesAnywhere() {
        var state = FirstRunState.at(.welcome)
        state.send(.discovered([FirstRunDiscoveredGateway(name: "A", address: loopback)]))
        #expect(state.discovered.count == 1)
    }

    // MARK: Sign in

    @Test func signInConnectsWithTheProfile() {
        var state = FirstRunState.at(.signIn, address: "192.168.1.20")
        let effects = state.send(.signIn(hasSecret: true))
        guard case let .signIn(profile)? = effects.first, effects.count == 1 else {
            Issue.record("expected one sign-in effect, got \(effects)")
            return
        }
        #expect(profile.id == state.profileId)
        #expect(profile.url == "ws://192.168.1.20:18789")
        #expect(profile.authMode == .token)
        #expect(profile.access == .standard, "new gateways get Chat & Approvals")
        #expect(state.signInStatus == .connecting && state.signInStatus.isBusy)
        #expect(state.send(.signIn(hasSecret: true)).isEmpty, "one sign-in at a time")
        #expect(state.send(.setAuthMode(.password)).isEmpty && state.authMode == .token, "no switching while busy")
    }

    @Test func signInNeedsASecret() {
        var token = FirstRunState.at(.signIn)
        #expect(token.needsSecret)
        #expect(token.send(.signIn(hasSecret: false)).isEmpty)
        #expect(token.signInStatus == .failed(FirstRunCopy.tokenMissing))

        var password = FirstRunState.at(.signIn)
        password.send(.setAuthMode(.password))
        #expect(password.send(.signIn(hasSecret: false)).isEmpty)
        #expect(password.signInStatus == .failed(FirstRunCopy.passwordNeeded))

        var none = FirstRunState.at(.signIn)
        none.send(.setAuthMode(.none))
        #expect(!none.needsSecret)
        #expect(none.send(.signIn(hasSecret: false)).count == 1, "pairing-only needs no secret")
    }

    @Test func switchingModeClearsTheError() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: false))
        #expect(state.signInStatus.error != nil)
        state.send(.setAuthMode(.password))
        #expect(state.signInStatus == .idle && state.authMode == .password)
    }

    @Test func signInAfterContinueAnywayStillValidates() {
        var state = FirstRunState.at(.findGateway)
        state.send(.setAddress("ws://127.0.0.1:1"))
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: "ws://127.0.0.1:1", .unreachable(FirstRunCopy.cantReach)))
        state.send(.skip)
        #expect(state.step == .signIn)
        #expect(state.send(.signIn(hasSecret: true)).count == 1)
    }

    @Test func badTokenStaysOnSignIn() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.connecting))
        let effects = state.send(.signInUpdate(.failed("unauthorized: gateway token mismatch (provide gateway auth token) [AUTH_TOKEN_MISMATCH]")))
        #expect(effects == [.cancelSignIn])
        #expect(state.step == .signIn)
        #expect(state.signInStatus == .failed(FirstRunCopy.tokenWrong))
        #expect(state.gatewayId == nil)
        #expect(state.send(.signIn(hasSecret: true)).count == 1, "can try again")
    }

    @Test func droppedConnection() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        #expect(state.send(.signInUpdate(.dropped("The network connection was lost."))) == [.cancelSignIn])
        #expect(state.signInStatus == .failed(FirstRunCopy.cantReach))
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.dropped("too many failed authentication attempts")))
        #expect(state.signInStatus == .failed(FirstRunCopy.rateLimited))
    }

    @Test func pairingPendingThenApproved() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev-1")))
        #expect(state.signInStatus == .awaitingPairing(requestId: "req-1", deviceId: "dev-1"))
        #expect(state.signInStatus.isBusy && !state.pairingRequestChanged)
        // Retries while waiting don't flash back to "Connecting…".
        state.send(.signInUpdate(.connecting))
        #expect(state.signInStatus == .awaitingPairing(requestId: "req-1", deviceId: "dev-1"))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev-1")))
        #expect(!state.pairingRequestChanged, "the same request again isn't a change")
        #expect(state.send(.signInUpdate(.connected(sampleVerified))) == [.cancelSignIn])
        #expect(state.step == .verify && state.verified == sampleVerified)
    }

    @Test func pairingRequestChanged() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev-1")))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-2", deviceId: "dev-1")))
        #expect(state.pairingRequestChanged)
        #expect(state.signInStatus == .awaitingPairing(requestId: "req-2", deviceId: "dev-1"))
        #expect(FirstRunCopy.approveCommand(requestId: "req-2") == "openclaw devices approve req-2")
        #expect(FirstRunCopy.approveCommand(requestId: nil) == FirstRunCopy.listDevicesCommand)
        // A new attempt starts fresh.
        state.send(.back)
        state.send(.checkAddress)
        state.send(.reachabilityResult(address: loopback, .reachable))
        state.send(.signIn(hasSecret: true))
        #expect(!state.pairingRequestChanged)
    }

    @Test func pairingRejected() {
        var state = FirstRunState.at(.signIn)
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev-1")))
        state.send(.signInUpdate(.failed("device rejected [DEVICE_IDENTITY_REQUIRED]")))
        #expect(state.signInStatus == .failed(FirstRunCopy.deviceTurnedDown))
        #expect(state.step == .signIn && state.gatewayId == nil)
    }

    @Test func updatesAfterSignInEndedAreIgnored() {
        var state = FirstRunState.at(.signIn)
        let before = state
        #expect(state.send(.signInUpdate(.connected(sampleVerified))).isEmpty)
        #expect(state == before, "not signing in")
    }

    @Test func connectedSuggestsAName() {
        var state = FirstRunState.at(.signIn, address: "wss://home.tail1234.ts.net")
        state.send(.signIn(hasSecret: true))
        state.send(.signInUpdate(.connected(sampleVerified)))
        #expect(state.name == "Home" && state.resolvedName == "Home")

        var named = FirstRunState.at(.findGateway)
        named.send(.setName("Office"))
        named.send(.setAddress("wss://home.tail1234.ts.net"))
        named.send(.checkAddress)
        named.send(.reachabilityResult(address: "wss://home.tail1234.ts.net", .reachable))
        named.send(.signIn(hasSecret: true))
        named.send(.signInUpdate(.connected(sampleVerified)))
        #expect(named.name == "Office")
    }

    // MARK: Verify, set up, done

    @Test func verifyShowsWhatConnected() {
        let state = FirstRunState.at(.verify)
        #expect(state.verified?.serverVersion == "2026.9.1")
        #expect(state.verified?.hasFullManagement == false)
        #expect(FirstRunVerified(serverVersion: nil, scopes: [GatewayConnection.adminScope]).hasFullManagement)
        #expect(state.gatewayId == nil, "not saved until the user continues")
        #expect(state.canSkip && state.canGoBack)
    }

    @Test func renameOnVerify() {
        var state = FirstRunState.at(.verify)
        state.send(.setName("Studio"))
        #expect(state.resolvedName == "Studio" && state.profile.name == "Studio")
        state.send(.setName("   "))
        #expect(!state.nameEdited && state.resolvedName == "This Mac", "blank falls back to the suggestion")
    }

    @Test func continueHandsOffToGatewaySetup() {
        var state = FirstRunState.at(.verify)
        let effects = state.send(.continueToSetup)
        guard effects.count == 2, case let .addGateway(profile) = effects[0] else {
            Issue.record("expected addGateway then beginGatewaySetup, got \(effects)")
            return
        }
        #expect(profile.id == state.profileId && profile.name == "This Mac")
        #expect(effects[1] == .beginGatewaySetup(gatewayId: state.profileId))
        #expect(state.step == .gatewaySetup && state.gatewayId == state.profileId)
        #expect(!state.canGoBack && state.canSkip)
    }

    @Test func skipToChatsFromVerify() {
        var state = FirstRunState.at(.verify)
        let effects = state.send(.skip)
        #expect(effects.count == 2)
        if case .addGateway? = effects.first {} else { Issue.record("adds the gateway first: \(effects)") }
        #expect(effects.last == .close(selecting: state.profileId))
        #expect(!effects.contains(.forgetCredentials(profileId: state.profileId)), "the saved gateway keeps its secret")
    }

    @Test func skipGatewaySetup() {
        var state = FirstRunState.at(.gatewaySetup)
        #expect(state.send(.skip) == [.close(selecting: state.profileId)])
    }

    @Test func gatewaySetupEndedGoesToTheChats() {
        var state = FirstRunState.at(.gatewaySetup)
        #expect(state.send(.gatewaySetupEnded) == [.close(selecting: state.profileId)])
        #expect(state.send(.finish).isEmpty, "Finish is for Done")
    }

    @Test func savedDoneFinishes() {
        var state = FirstRunState.at(.done)
        #expect(state.step == .done && state.gatewayId == state.profileId && state.verified == sampleVerified)
        #expect(state.stepNumber == nil && !state.canGoBack && !state.canSkip)
        #expect(state.send(.finish) == [.close(selecting: state.profileId)])
    }

    // MARK: Cancel

    @Test func cancelBeforeSaving() {
        var find = FirstRunState.at(.findGateway)
        #expect(find.send(.cancel) == [.stopDiscovery, .forgetCredentials(profileId: find.profileId), .close(selecting: nil)])

        var signIn = FirstRunState.at(.signIn)
        signIn.send(.signIn(hasSecret: true))
        #expect(signIn.send(.cancel) == [.cancelSignIn, .forgetCredentials(profileId: signIn.profileId), .close(selecting: nil)])
    }

    @Test func cancelAfterSavingKeepsTheGateway() {
        var state = FirstRunState.at(.gatewaySetup)
        #expect(state.send(.cancel) == [.close(selecting: state.profileId)])
    }

    // MARK: Resume

    @Test(arguments: [FirstRunStep.welcome, .haveGateway, .install, .findGateway, .signIn, .gatewaySetup, .done])
    func roundTrip(_ step: FirstRunStep) throws {
        let state = FirstRunState.at(step, address: "wss://home.tail1234.ts.net")
        let resumed = try state.roundTripped()
        #expect(resumed.step == step)
        #expect(resumed.entry == state.entry && resumed.profileId == state.profileId)
        #expect(resumed.address == state.address && resumed.name == state.name && resumed.authMode == state.authMode)
        #expect(resumed.verified == state.verified && resumed.gatewayId == state.gatewayId)
    }

    @Test func roundTripKeepsLocationModeAndName() throws {
        var state = FirstRunState.at(.signIn, location: .sameNetwork)
        state.send(.setAuthMode(.password))
        var named = FirstRunState.at(.findGateway, location: .sameNetwork)
        named.send(.setName("Office"))
        let resumed = try state.roundTripped()
        #expect(resumed.location == .sameNetwork && resumed.authMode == .password)
        let resumedName = try named.roundTripped()
        #expect(resumedName.name == "Office" && resumedName.nameEdited)
    }

    @Test func transientStateIsNotSaved() throws {
        var checking = FirstRunState.at(.findGateway)
        checking.send(.discovered([FirstRunDiscoveredGateway(name: "A", address: loopback)]))
        checking.send(.setAddress(loopback))
        checking.send(.checkAddress)
        let resumedCheck = try checking.roundTripped()
        #expect(resumedCheck.reachability == .unknown && resumedCheck.discovered.isEmpty)
        #expect(resumedCheck.canCheckAddress, "a check in flight when the app quit can run again")

        var pairing = FirstRunState.at(.signIn)
        pairing.send(.signIn(hasSecret: true))
        pairing.send(.signInUpdate(.awaitingPairing(requestId: "req-1", deviceId: "dev")))
        var resumedPairing = try pairing.roundTripped()
        #expect(resumedPairing.step == .signIn && resumedPairing.signInStatus == .idle)
        #expect(resumedPairing.send(.signIn(hasSecret: true)).count == 1, "signs in again after the relaunch")
    }

    @Test func savedJSONHasOnlyTheDocumentedKeys() throws {
        var state = FirstRunState.at(.gatewaySetup)
        state.send(.discovered([FirstRunDiscoveredGateway(name: "A", address: loopback)]))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(Set(json.keys).isSubset(of: ["step", "entry", "profileId", "location", "address", "name", "nameEdited",
                                             "authMode", "verified", "gatewayId"]), "\(json.keys.sorted())")
        #expect(json["step"] as? String == "gatewaySetup")
    }

    @Test(arguments: ["verify", "gatewaySetup", "done"])
    func signedInButNotSavedResumesAtSignIn(_ step: String) throws {
        let json = #"{"step":"\#(step)","entry":"welcome","profileId":"\#(UUID().uuidString)","address":"ws://127.0.0.1:18789","verified":{"scopes":[]}}"#
        let resumed = try JSONDecoder().decode(FirstRunState.self, from: Data(json.utf8))
        #expect(resumed.step == .signIn)
        #expect(resumed.address == loopback && resumed.authMode == .token)
    }

    @Test func oldOrPartialSavesDecode() throws {
        let json = #"{"step":"findGateway","profileId":"\#(UUID().uuidString)","somethingNew":1}"#
        let resumed = try JSONDecoder().decode(FirstRunState.self, from: Data(json.utf8))
        #expect(resumed.step == .findGateway && resumed.entry == .welcome && resumed.location == .tailscale)
        #expect(resumed.address.isEmpty && resumed.name.isEmpty && !resumed.nameEdited)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FirstRunState.self, from: Data(#"{"step":"nope","profileId":"\#(UUID().uuidString)"}"#.utf8))
        }
    }

    @Test func store() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        let state = FirstRunState.at(.signIn)
        FirstRunStore.save(state, to: scratch.defaults)
        let loaded = FirstRunStore.load(from: scratch.defaults)
        #expect(loaded?.step == .signIn && loaded?.profileId == state.profileId)
        FirstRunStore.clear(scratch.defaults)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        scratch.defaults.set(Data("garbage".utf8), forKey: FirstRunStore.key)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil, "a corrupt save starts over")
    }
}

@Suite("First-run wizard copy")
struct FirstRunCopyTests {
    // The mock gateway's (and upstream's) connect failures, as `GatewayError.rpc` text.
    @Test(arguments: [
        ("unauthorized: gateway token mismatch (provide gateway auth token) [AUTH_TOKEN_MISMATCH]", GatewayProfile.AuthMode.token, FirstRunCopy.tokenWrong),
        ("unauthorized [AUTH_UNAUTHORIZED]", .token, FirstRunCopy.tokenWrong),
        ("unauthorized [AUTH_UNAUTHORIZED]", .password, FirstRunCopy.passwordWrong),
        ("unauthorized: gateway password mismatch (provide gateway auth password) [AUTH_PASSWORD_MISMATCH]", .password, FirstRunCopy.passwordWrong),
        ("unauthorized: gateway token missing (provide gateway auth token) [AUTH_TOKEN_MISSING]", .token, FirstRunCopy.tokenMissing),
        ("unauthorized: gateway password missing (provide gateway auth password) [AUTH_PASSWORD_MISSING]", .password, FirstRunCopy.passwordNeeded),
        ("unauthorized: gateway token not configured on gateway (set gateway.auth.token) [AUTH_TOKEN_NOT_CONFIGURED]", .token, FirstRunCopy.methodMismatch),
        ("unauthorized: gateway password not configured on gateway (set gateway.auth.password) [AUTH_PASSWORD_NOT_CONFIGURED]", .password, FirstRunCopy.methodMismatch),
        ("unauthorized: too many failed authentication attempts (retry later) [AUTH_RATE_LIMITED]", .token, FirstRunCopy.rateLimited),
        ("protocol mismatch [PROTOCOL_MISMATCH]", .token, FirstRunCopy.versionMismatch),
        ("something else [SOMETHING_ELSE]", .token, "something else [SOMETHING_ELSE]"),
        ("plain text", .token, "plain text"),
    ])
    func signInError(_ message: String, _ mode: GatewayProfile.AuthMode, _ expected: String) {
        #expect(FirstRunCopy.signInError(message, authMode: mode) == expected)
    }

    @Test func signInErrorWhilePairing() {
        #expect(FirstRunCopy.signInError("x [DEVICE_TOKEN_REVOKED]", authMode: .token, whilePairing: true) == FirstRunCopy.deviceTurnedDown)
        #expect(FirstRunCopy.signInError("x [DEVICE_TOKEN_REVOKED]", authMode: .token) == "x [DEVICE_TOKEN_REVOKED]")
        #expect(FirstRunCopy.signInError("x [AUTH_TOKEN_MISMATCH]", authMode: .token, whilePairing: true) == FirstRunCopy.tokenWrong)
    }

    @Test func reachabilityErrors() {
        #expect(FirstRunCopy.reachabilityError(URLError(.cannotConnectToHost)) == FirstRunCopy.cantReach)
        #expect(FirstRunCopy.reachabilityError(URLError(.timedOut)) == FirstRunCopy.cantReach)
        #expect(FirstRunCopy.reachabilityError(URLError(.serverCertificateUntrusted)) == FirstRunCopy.tlsFailed)
        #expect(FirstRunCopy.reachabilityError(URLError(.badServerResponse)) == FirstRunCopy.notAGateway)
    }

    @Test func specWording() {
        // Product spec §2 wording the lead signed off on.
        #expect(FirstRunCopy.tokenWrong == "That token didn't work. Copy it again with the command below and paste the whole thing.")
        #expect(FirstRunCopy.addressMissing == "Enter your Gateway's address.")
        #expect(FirstRunCopy.tokenCommand == "openclaw config get gateway.auth.token")
        #expect(FirstRunCopy.approveCommand(requestId: "abc") == "openclaw devices approve abc")
    }
}

/// `FirstRunModel` inside `AppModel`, with the network faked.
@Suite("First-run wizard model", .serialized)
@MainActor
struct FirstRunModelTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _reachability: FirstRunReachability = .reachable
        private var _updates: [FirstRunSignInUpdate] = [.connecting, .connected(sampleVerified)]
        private var _probed: [URL] = []
        private var _secrets: [String?] = []
        private var _profiles: [GatewayProfile] = []

        private func locked<T>(_ body: () -> T) -> T { self.lock.lock(); defer { self.lock.unlock() }; return body() }
        var reachability: FirstRunReachability {
            get { self.locked { self._reachability } }
            set { self.locked { self._reachability = newValue } }
        }
        var updates: [FirstRunSignInUpdate] {
            get { self.locked { self._updates } }
            set { self.locked { self._updates = newValue } }
        }
        var probed: [URL] { self.locked { self._probed } }
        var secrets: [String?] { self.locked { self._secrets } }
        var profiles: [GatewayProfile] { self.locked { self._profiles } }

        var environment: FirstRunModel.Environment {
            FirstRunModel.Environment(
                checkReachability: { url in
                    self.locked { self._probed.append(url) }
                    return self.reachability
                },
                signIn: { profile in
                    self.locked {
                        self._profiles.append(profile)
                        self._secrets.append(profile.secret)
                    }
                    let updates = self.updates
                    return AsyncStream { continuation in
                        for update in updates { continuation.yield(update) }
                        continuation.finish()
                    }
                })
        }
    }

    static func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        await eventually(timeout: .seconds(5), condition)
    }

    /// Welcome → Sign in at `address`, through the model.
    static func toSignIn(_ wizard: FirstRunModel, address: String = loopback) async -> Bool {
        wizard.send(.getStarted)
        wizard.send(.answerHaveGateway(true))
        wizard.send(.setLocation(.sameNetwork))
        wizard.send(.setAddress(address))
        wizard.send(.checkAddress)
        return await self.settle { wizard.state.step == .signIn }
    }

    static func cleanUp(_ app: AppModel) {
        for gateway in app.gateways { app.remove(gateway.id) }
        if app.firstRun.isPresented { app.firstRun.send(.cancel) }
    }

    @Test func freshInstallShowsWelcome() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: Probe().environment)
        #expect(app.gateways.isEmpty)
        #expect(app.firstRun.isPresented && app.firstRun.presentation == .window && !app.firstRun.isSheetPresented)
        #expect(app.firstRun.state.step == .welcome)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil, "nothing saved until the user does something")
    }

    @Test func happyPathAddsAndSelectsTheGateway() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        #expect(await Self.toSignIn(wizard))
        #expect(probe.probed == [URL(string: loopback)!])
        wizard.secret = "dev-token"
        wizard.send(.signIn(hasSecret: true))
        #expect(await Self.settle { wizard.state.step == .verify })
        #expect(probe.secrets == ["dev-token"], "the secret is in the Keychain before connecting")
        #expect(app.gateways.isEmpty, "nothing saved before Continue")
        let id = wizard.state.profileId

        wizard.send(.continueToSetup)
        #expect(app.gateways.map(\.id) == [id])
        #expect(app.selectedGatewayId == id)
        #expect(app.gateways.first?.profile.secret == "dev-token")
        #expect(app.gateways.first?.profile.name == "This Mac")
        #expect(wizard.secret.isEmpty, "the typed secret is dropped once saved")
        #expect(wizard.gateway?.id == id)
        #expect(wizard.state.step == .gatewaySetup)
        #expect(wizard.gateway?.setup.isEmbedded == true, "the per-gateway wizard runs inside this one")
        #expect(wizard.gateway?.setup.progress.offered == true, "and doesn't offer itself again")
        #expect(wizard.isPresented && wizard.presentation == .window)

        wizard.send(.gatewaySetupEnded)
        #expect(!wizard.isPresented, "finishing setup goes straight to the chats")
        #expect(app.selectedGatewayId == id)
        #expect(app.gateways.first?.setup.isEmbedded == false)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil, "a finished run leaves nothing to resume")
    }

    @Test func secretIsNeverWrittenToDefaults() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        probe.updates = [.connecting, .awaitingPairing(requestId: "pair_1", deviceId: "abc")]
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        #expect(await Self.toSignIn(wizard))
        wizard.secret = "super-secret-token-value"
        wizard.send(.signIn(hasSecret: true))
        #expect(await Self.settle { wizard.state.signInStatus == .awaitingPairing(requestId: "pair_1", deviceId: "abc") })
        #expect(FirstRunStore.load(from: scratch.defaults)?.step == .signIn)
        let dump = scratch.defaults.dictionaryRepresentation().map { key, value in
            "\(key)=\((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")"
        }.joined(separator: "\n")
        #expect(!dump.contains("super-secret-token-value"))
    }

    @Test func resumeAfterQuit() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        let first = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        #expect(await Self.toSignIn(first.firstRun, address: "wss://home.tail1234.ts.net"))
        first.firstRun.send(.setAuthMode(.password))
        let profileId = first.firstRun.state.profileId

        // "Quit": a new app on the same defaults.
        let second = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(second) }
        #expect(second.firstRun.presentation == .window)
        #expect(second.firstRun.state.step == .signIn)
        #expect(second.firstRun.state.address == "wss://home.tail1234.ts.net")
        #expect(second.firstRun.state.authMode == .password && second.firstRun.state.location == .sameNetwork)
        #expect(second.firstRun.state.profileId == profileId)
        #expect(second.firstRun.secret.isEmpty, "the secret isn't restored from defaults")
        second.firstRun.send(.cancel)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        #expect(second.firstRun.presentation == .window && second.firstRun.state.step == .welcome,
                "with no gateways, cancel starts over at Welcome")
    }

    @Test func resumeInGatewaySetup() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        let first = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        #expect(await Self.toSignIn(first.firstRun))
        first.firstRun.secret = "dev-token"
        first.firstRun.send(.signIn(hasSecret: true))
        #expect(await Self.settle { first.firstRun.state.step == .verify })
        first.firstRun.send(.continueToSetup)
        let id = first.firstRun.state.profileId
        for gateway in first.gateways { gateway.stop() }

        let second = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(second) }
        #expect(second.gateways.map(\.id) == [id])
        #expect(second.firstRun.presentation == .sheet, "a saved run over existing gateways is a sheet")
        #expect(second.firstRun.state.step == .gatewaySetup)
        #expect(second.firstRun.gateway?.id == id)
        second.firstRun.present()
        #expect(second.firstRun.gateway?.setup.isEmbedded == true, "presenting resumes the embedded setup")
    }

    @Test func untouchedWelcomeIsNotSaved() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: Probe().environment)
        app.firstRun.send(.discovered([]))
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        app.firstRun.send(.getStarted)
        #expect(FirstRunStore.load(from: scratch.defaults)?.step == .haveGateway)
        app.firstRun.send(.back)
        #expect(FirstRunStore.load(from: scratch.defaults) == nil, "back at Welcome, nothing to resume")
    }

    @Test func badTokenKeepsTheSecretTyped() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        probe.updates = [.connecting, .failed("unauthorized: gateway token mismatch (provide gateway auth token) [AUTH_TOKEN_MISMATCH]")]
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        #expect(await Self.toSignIn(wizard))
        wizard.secret = "wrong"
        wizard.send(.signIn(hasSecret: true))
        #expect(await Self.settle { wizard.state.signInStatus.error != nil })
        #expect(wizard.state.signInStatus == .failed(FirstRunCopy.tokenWrong))
        #expect(wizard.state.step == .signIn)
        #expect(wizard.secret == "wrong", "the field stays filled")
        #expect(app.gateways.isEmpty, "no half-configured gateway")
        let profileId = wizard.state.profileId
        wizard.send(.cancel)
        #expect(GatewayProfile(id: profileId, name: "", url: "", authMode: .token).secret == nil, "cancel forgets the tried secret")
    }

    @Test func unreachableStaysOnFind() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        probe.reachability = .unreachable(FirstRunCopy.cantReach)
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        #expect(await Self.toSignIn(wizard, address: "ws://127.0.0.1:1") == false)
        #expect(wizard.state.step == .findGateway)
        #expect(wizard.state.reachabilityMessage == FirstRunCopy.cantReach)
        wizard.send(.skip)
        #expect(wizard.state.step == .signIn, "Continue Anyway")
    }

    @Test func invalidAddressNeverProbes() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        wizard.send(.getStarted)
        wizard.send(.answerHaveGateway(true))
        wizard.send(.setAddress("ftp://example.com"))
        wizard.send(.checkAddress)
        #expect(wizard.state.reachability.error == FirstRunCopy.invalidAddress)
        #expect(probe.probed.isEmpty)
    }

    @Test func tryDemoLeavesTheWizard() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: Probe().environment)
        defer { Self.cleanUp(app) }
        app.firstRun.send(.getStarted)
        app.firstRun.send(.tryDemo)
        #expect(app.gateways.contains { $0.profile.isDemo })
        #expect(app.selectedGatewayId == app.gateways.first?.id)
        #expect(!app.firstRun.isPresented, "the demo opens in the main window, not under the wizard")
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        let demo = app.gateways.first { $0.profile.isDemo }
        #expect(demo?.setup.isPresented == false && demo?.setup.isShowingOrPending == false,
                "straight to the chat list: no setup offer")
    }

    @Test func removingTheLastGatewayShowsWelcome() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: Probe().environment)
        defer { Self.cleanUp(app) }
        app.openDemo()
        app.firstRun.send(.cancel)
        for gateway in app.gateways { app.remove(gateway.id) }
        #expect(app.firstRun.presentation == .window && app.firstRun.state.step == .welcome)
    }

    @Test func addGatewayIsASheetAtFind() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: Probe().environment)
        defer { Self.cleanUp(app) }
        app.openDemo()
        app.firstRun.send(.cancel)
        #expect(!app.firstRun.isPresented)
        app.firstRun.present()
        #expect(app.firstRun.presentation == .sheet && app.firstRun.isSheetPresented)
        #expect(app.firstRun.state.step == .findGateway && app.firstRun.state.entry == .findGateway)
        app.firstRun.send(.setAddress("192.168.1.20"))
        app.firstRun.isSheetPresented = false
        #expect(!app.firstRun.isPresented, "dismissing the sheet cancels")
        #expect(FirstRunStore.load(from: scratch.defaults) == nil)
        #expect(app.gateways.count == 1)
    }

    @Test func cancelDuringSignInForgetsTheSecret() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let probe = Probe()
        probe.updates = [.connecting, .awaitingPairing(requestId: "pair_1", deviceId: "abc")]
        let app = AppModel(defaults: scratch.defaults, firstRunEnvironment: probe.environment)
        defer { Self.cleanUp(app) }
        let wizard = app.firstRun
        #expect(await Self.toSignIn(wizard))
        wizard.secret = "dev-token"
        wizard.send(.signIn(hasSecret: true))
        #expect(await Self.settle { wizard.state.signInStatus.isBusy })
        let id = wizard.state.profileId
        #expect(GatewayProfile(id: id, name: "", url: "", authMode: .token).secret == "dev-token")
        wizard.send(.cancel)
        #expect(GatewayProfile(id: id, name: "", url: "", authMode: .token).secret == nil)
        #expect(app.gateways.isEmpty)
    }
}
