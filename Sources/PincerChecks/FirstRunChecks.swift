import Foundation
import PincerKit

// First-run wizard (#175): fresh install, resume, errors, the demo, and signing in to the mock gateway.

/// Network stand-ins: reachability answers `reachability`; sign-in plays `updates`, then waits for `approve()`
/// when `holdForApproval` is set, then plays `afterApproval`.
private final class FirstRunFakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var _reachability: FirstRunReachability = .reachable
    private var _updates: [FirstRunSignInUpdate] = []
    private var _afterApproval: [FirstRunSignInUpdate] = []
    private var pending: AsyncStream<FirstRunSignInUpdate>.Continuation?
    private var _signIns = 0

    private func locked<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    var reachability: FirstRunReachability {
        get { self.locked { self._reachability } }
        set { self.locked { self._reachability = newValue } }
    }

    var signIns: Int { self.locked { self._signIns } }

    func script(_ updates: [FirstRunSignInUpdate], thenOnApproval afterApproval: [FirstRunSignInUpdate] = []) {
        self.locked {
            self._updates = updates
            self._afterApproval = afterApproval
        }
    }

    func approve() {
        let (continuation, updates) = self.locked { (self.pending, self._afterApproval) }
        for update in updates { continuation?.yield(update) }
        continuation?.finish()
    }

    var environment: FirstRunModel.Environment {
        FirstRunModel.Environment(
            checkReachability: { _ in self.reachability },
            signIn: { _ in
                let (updates, hold) = self.locked {
                    self._signIns += 1
                    return (self._updates, !self._afterApproval.isEmpty)
                }
                return AsyncStream { continuation in
                    for update in updates { continuation.yield(update) }
                    if hold { self.locked { self.pending = continuation } } else { continuation.finish() }
                }
            })
    }
}

private let firstRunVerified = FirstRunVerified(serverVersion: "2026.9.1", scopes: ["operator.read", "operator.write"])

@MainActor
private func firstRunToSignIn(_ wizard: FirstRunModel, address: String) async -> Bool {
    wizard.send(.getStarted)
    wizard.send(.answerHaveGateway(true))
    wizard.send(.setLocation(.sameNetwork))
    wizard.send(.setAddress(address))
    wizard.send(.checkAddress)
    return await waitFor("first run reaches Sign In", timeout: 12) { wizard.state.step == .signIn }
}

@MainActor
private func firstRunCleanUp(_ app: AppModel, _ defaultsName: String) {
    for gateway in app.gateways { app.remove(gateway.id) }
    if app.firstRun.isPresented { app.firstRun.send(.cancel) }
    UserDefaults.standard.removePersistentDomain(forName: defaultsName)
}

@MainActor
func runFirstRunChecks() async {
    // Fresh install: no gateways, the wizard fills the window at Welcome.
    do {
        let (defaults, name) = scratchDefaults()
        let network = FirstRunFakeNetwork()
        let app = AppModel(defaults: defaults, firstRunEnvironment: network.environment)
        check(app.gateways.isEmpty && app.firstRun.presentation == .window && app.firstRun.state.step == .welcome,
              "fresh install shows the first-run wizard at Welcome (\(String(describing: app.firstRun.presentation)), \(app.firstRun.state.step))")
        check(FirstRunStore.load(from: defaults) == nil, "an untouched Welcome isn't saved")
        check(app.firstRun.state.stepNumber == 1 && FirstRunState.countedStages.count == 5, "Welcome is step 1 of 5")
        firstRunCleanUp(app, name)
    }

    // Bad addresses never reach the network.
    do {
        let (defaults, name) = scratchDefaults()
        let network = FirstRunFakeNetwork()
        let app = AppModel(defaults: defaults, firstRunEnvironment: network.environment)
        let wizard = app.firstRun
        wizard.send(.getStarted)
        wizard.send(.answerHaveGateway(true))
        check(wizard.state.location == .thisMac && wizard.state.address == FirstRunLocation.thisMacAddress,
              "on a Mac, Find starts with This Mac's address (\(wizard.state.location), \(wizard.state.address))")
        wizard.send(.setAddress(""))
        wizard.send(.checkAddress)
        check(wizard.state.reachability.error == FirstRunCopy.addressMissing, "empty address asks for one (\(wizard.state.reachability))")
        wizard.send(.setAddress("ftp://example.com"))
        wizard.send(.checkAddress)
        check(wizard.state.reachability.error == FirstRunCopy.invalidAddress && wizard.state.step == .findGateway,
              "a bad URL stays on Find (\(wizard.state.reachability))")
        wizard.send(.setAddress("ws://example.com"))
        wizard.send(.checkAddress)
        check(wizard.state.reachability.error == FirstRunCopy.insecureAddress, "public ws:// is refused (\(wizard.state.reachability))")
        check(!wizard.state.canSkip, "no Continue Anyway for an unusable address")
        firstRunCleanUp(app, name)
    }

    // Pairing: waiting for approval, then approved; resume after quitting mid-way.
    do {
        let (defaults, name) = scratchDefaults()
        let network = FirstRunFakeNetwork()
        network.script([.connecting, .awaitingPairing(requestId: "req-1", deviceId: "dev-1")],
                       thenOnApproval: [.connected(firstRunVerified)])
        let app = AppModel(defaults: defaults, firstRunEnvironment: network.environment)
        let wizard = app.firstRun
        let reached = await firstRunToSignIn(wizard, address: "192.168.1.20")
        check(reached && wizard.state.normalizedAddress == "ws://192.168.1.20:18789", "a bare LAN IP gets ws:// and :18789 (\(wizard.state.normalizedAddress))")
        wizard.secret = "dev-token"
        wizard.send(.signIn(hasSecret: true))
        let waiting = await waitFor("pairing pending") {
            wizard.state.signInStatus == .awaitingPairing(requestId: "req-1", deviceId: "dev-1")
        }
        check(waiting, "pairing pending shows Waiting for approval (\(wizard.state.signInStatus))")
        check(FirstRunCopy.approveCommand(requestId: "req-1") == "openclaw devices approve req-1", "the approve command names the request")
        check(FirstRunStore.load(from: defaults)?.step == .signIn, "progress is saved while waiting")
        network.approve()
        let approved = await waitFor("pairing approved") { wizard.state.step == .verify }
        check(approved && wizard.state.verified == firstRunVerified, "approval moves on to Verify")
        check(app.gateways.isEmpty, "nothing added before Continue")

        // "Quit" before Continue: signed in but not saved resumes at Sign In.
        let relaunched = AppModel(defaults: defaults, firstRunEnvironment: network.environment)
        check(relaunched.firstRun.presentation == .window && relaunched.firstRun.state.step == .signIn
              && relaunched.firstRun.state.profileId == wizard.state.profileId
              && relaunched.firstRun.state.address == "192.168.1.20",
              "relaunch resumes the run at Sign In (\(relaunched.firstRun.state.step))")
        check(relaunched.firstRun.secret.isEmpty, "the secret isn't restored from defaults")
        firstRunCleanUp(relaunched, name)
        firstRunCleanUp(app, name)
    }

    // Bad token: stays on Sign In with the spec copy, nothing added; unreachable offers Continue Anyway.
    do {
        let (defaults, name) = scratchDefaults()
        let network = FirstRunFakeNetwork()
        network.script([.connecting, .failed("unauthorized: gateway token mismatch (provide gateway auth token) [AUTH_TOKEN_MISMATCH]")])
        let app = AppModel(defaults: defaults, firstRunEnvironment: network.environment)
        let wizard = app.firstRun
        _ = await firstRunToSignIn(wizard, address: "ws://127.0.0.1:18789")
        wizard.secret = "wrong"
        wizard.send(.signIn(hasSecret: true))
        let failed = await waitFor("bad token") { wizard.state.signInStatus.error != nil }
        check(failed && wizard.state.signInStatus.error == FirstRunCopy.tokenWrong && wizard.state.step == .signIn,
              "a bad token says so and stays on Sign In (\(wizard.state.signInStatus))")
        check(app.gateways.isEmpty && wizard.secret == "wrong", "no gateway added; the typed token stays")

        wizard.send(.back)
        network.reachability = .unreachable(FirstRunCopy.cantReach)
        wizard.send(.setAddress("ws://127.0.0.1:1"))
        wizard.send(.checkAddress)
        let unreachable = await waitFor("unreachable") { wizard.state.reachability.error != nil }
        check(unreachable && wizard.state.step == .findGateway && wizard.state.canSkip,
              "unreachable stays on Find with Continue Anyway (\(wizard.state.reachability))")
        firstRunCleanUp(app, name)
    }

    // Add Gateway… over an existing gateway: a sheet at Find; dismissing it cancels.
    do {
        let (defaults, name) = scratchDefaults()
        let app = AppModel(defaults: defaults, firstRunEnvironment: FirstRunFakeNetwork().environment)
        app.firstRun.send(.tryDemo)
        app.firstRun.present()
        check(app.firstRun.presentation == .sheet && app.firstRun.state.step == .findGateway,
              "Add Gateway… opens a sheet at Find (\(String(describing: app.firstRun.presentation)), \(app.firstRun.state.step))")
        app.firstRun.isSheetPresented = false
        check(!app.firstRun.isPresented && FirstRunStore.load(from: defaults) == nil, "dismissing the sheet cancels")
        firstRunCleanUp(app, name)
    }
}

@MainActor
func runDemoFirstRun() async {
    let (defaults, name) = scratchDefaults()
    let app = AppModel(defaults: defaults, firstRunEnvironment: FirstRunFakeNetwork().environment)
    defer { firstRunCleanUp(app, name) }
    check(app.firstRun.state.step == .welcome, "demo run starts at Welcome")
    app.firstRun.send(.tryDemo)
    let demo = app.gateways.first { $0.profile.isDemo }
    check(demo != nil && app.selectedGatewayId == demo?.id, "Try the Demo adds and selects the demo")
    check(!app.firstRun.isPresented, "Try the Demo leaves the wizard (\(String(describing: app.firstRun.presentation)))")
    check(FirstRunStore.load(from: defaults) == nil, "nothing left to resume")
    guard let demo else { return }
    check(!demo.setup.isShowingOrPending, "Try the Demo doesn't queue a setup offer")
    let connected = await waitFor("first-run demo connects") { demo.state.isConnected && !demo.sessions.isEmpty }
    check(connected, "the demo connects")
    // Try the Demo lands straight in the chat list (#175 product review r1): no setup wizard offer.
    try? await Task.sleep(for: .milliseconds(500))
    check(!demo.setup.isPresented && !demo.setup.isShowingOrPending,
          "the connected demo doesn't offer setup (presented \(demo.setup.isPresented))")
    check(app.selectedGatewayId == demo.id && !app.firstRun.isPresented,
          "the demo stays selected with first-run dismissed")
    app.remove(demo.id)
    check(app.firstRun.presentation == .window && app.firstRun.state.step == .welcome,
          "removing the demo (the last gateway) shows Welcome again")
}

@MainActor
func runLiveFirstRun(url: String, token: String) async {
    guard let gatewayURL = URL(string: url) else {
        check(false, "live URL parses (\(url))")
        return
    }

    // Reachability: the mock answers with connect.challenge; a closed port doesn't.
    let reachable = await FirstRunProbe.checkReachability(gatewayURL, timeout: 5)
    check(reachable == .reachable, "the mock is reachable (\(reachable))")
    let closed = await FirstRunProbe.checkReachability(URL(string: "ws://127.0.0.1:1")!, timeout: 5)
    check(closed == .unreachable(FirstRunCopy.cantReach), "a closed port is unreachable (\(closed))")

    // A fresh device (the Keychain is in memory here) so the mock asks for pairing; restored after.
    let identityAccount = "device.ed25519"
    let savedIdentity = Keychain.get(identityAccount)
    Keychain.delete(identityAccount)
    defer {
        if let savedIdentity { Keychain.set(savedIdentity, for: identityAccount) } else { Keychain.delete(identityAccount) }
    }

    // Bad token: refused before pairing, with the upstream code mapped to spec copy.
    let wrong = GatewayProfile(name: "First run wrong", url: url, authMode: .token)
    wrong.secret = "not-the-token"
    var failure: String?
    for await update in FirstRunProbe.signIn(wrong) {
        if case let .failed(message) = update { failure = message }
    }
    wrong.forgetCredentials()
    check(failure.map { FirstRunCopy.signInError($0, authMode: .token) } == FirstRunCopy.tokenWrong,
          "a bad token fails with AUTH_TOKEN_MISMATCH (\(failure ?? "nil"))")

    // The whole wizard, live: Welcome → Find → Sign In (pairing pending, auto-approved) → Verify → setup → chats.
    let (defaults, name) = scratchDefaults()
    let app = AppModel(defaults: defaults, firstRunEnvironment: .live)
    defer { firstRunCleanUp(app, name) }
    let wizard = app.firstRun
    check(wizard.presentation == .window && wizard.state.step == .welcome, "live: fresh install shows Welcome")
    let reached = await firstRunToSignIn(wizard, address: url)
    check(reached, "live: the mock passes the reachability check (\(wizard.state.reachability))")
    guard reached else { return }
    wizard.secret = token
    wizard.send(.signIn(hasSecret: true))
    var sawPairing = false
    let verified = await waitFor("live sign-in", timeout: 30) {
        if case .awaitingPairing = wizard.state.signInStatus { sawPairing = true }
        return wizard.state.step == .verify || wizard.state.signInStatus.error != nil
    }
    check(sawPairing, "live: a new device waits for pairing approval")
    check(verified && wizard.state.step == .verify, "live: approved and signed in (\(wizard.state.signInStatus))")
    guard wizard.state.step == .verify, let info = wizard.state.verified else { return }
    check(info.serverVersion?.isEmpty == false && info.scopes.contains("operator.read"),
          "live: Verify shows the version and scopes (\(info.serverVersion ?? "nil"), \(info.scopes))")
    check(!info.hasFullManagement, "live: a new gateway gets Chat & Approvals, not Full Management")
    check(app.gateways.isEmpty, "live: nothing added before Continue")

    wizard.send(.continueToSetup)
    let id = wizard.state.profileId
    guard let gateway = app.gateways.first(where: { $0.id == id }) else {
        check(false, "live: Continue adds the gateway")
        return
    }
    check(app.selectedGatewayId == id && gateway.profile.secret == token, "live: the gateway is saved with its token, and selected")
    check(gateway.setup.isEmbedded && !gateway.setup.isPresented, "live: its setup runs inside the wizard, not as its own sheet")
    let connected = await waitFor("live added gateway connects", timeout: 25) { gateway.state.isConnected }
    check(connected, "live: the saved gateway connects without pairing again (\(gateway.state))")
    check(FirstRunStore.load(from: defaults)?.step == .gatewaySetup, "live: progress saved at setup")

    wizard.send(.gatewaySetupEnded)
    check(!wizard.isPresented && app.selectedGatewayId == id && !gateway.setup.isEmbedded,
          "live: ending setup lands on the gateway's chats")
    check(FirstRunStore.load(from: defaults) == nil, "live: a finished run leaves nothing to resume")
    UserDefaults.standard.removeObject(forKey: SetupProgress.key(for: id))
}
