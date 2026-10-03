import Foundation
import PincerKit

// Setup wizard (#39) against the built-in demo and the mock gateway.

@MainActor
private func setupConnect(_ profile: GatewayProfile, _ label: String, timeout: Double = 25) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor(label, timeout: timeout) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(label) connected")
    return connected ? gateway : nil
}

@MainActor
private func setupCleanup(_ gateway: GatewayStore) {
    gateway.stop()
    UserDefaults.standard.removeObject(forKey: SetupProgress.key(for: gateway.id))
}

@MainActor
private func setupLoaded(_ gateway: GatewayStore, _ label: String) async -> Bool {
    await gateway.setup.load()
    return await waitFor(label) { gateway.setup.skills != nil && !gateway.setup.status(of: .agent).isNotChecked }
}

private extension SetupStepStatus {
    var isNotChecked: Bool { if case .notChecked = self { true } else { false } }
}

@MainActor
func runDemoSetup() async {
    let profile = GatewayProfile.demo()
    let key = SetupProgress.key(for: profile.id)
    UserDefaults.standard.removeObject(forKey: key)
    let gateway = GatewayStore(profile: profile)
    // An explicit one-off offer (Try the Demo no longer offers setup, #175; see FirstRunChecks).
    gateway.setup.requestOffer(connected: false)
    gateway.start()
    let demoUp = await waitFor("demo for setup") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(demoUp, "demo for setup connected")
    guard demoUp else { return }
    defer { setupCleanup(gateway) }
    let setup = gateway.setup

    // Offered at once, as the intro page.
    let offered = await waitFor("demo setup offer") { setup.isPresented }
    check(offered && setup.showsIntro && setup.isDemo, "an explicit demo offer shows Set Up at once (presented \(setup.isPresented), intro \(setup.showsIntro))")
    let demoLoaded = await setupLoaded(gateway, "demo setup checks")
    check(demoLoaded, "demo setup checks load")

    // Seeded statuses: Health and Channels aren't setup steps any more (#175).
    check(SetupStep.allCases == [.agent, .skills, .testMessage], "setup steps are Agent & Model, Skills, Test Message")
    check(setup.status(of: .agent).isDone, "demo Agent & Model is Done (\(setup.status(of: .agent)))")
    let agentPresentation = SetupStepPresentation(status: setup.status(of: .agent), step: .agent,
                                                  needsFullManagement: setup.needsFullManagement(.agent))
    check(agentPresentation.label == "Current default" && agentPresentation.symbol == "info.circle"
          && agentPresentation.tone == .neutral,
          "demo Agent & Model shows a neutral Current default status without Full Management")
    let skills = setup.status(of: .skills)
    // The wizard reads the Skills page's seed: every Needs Setup skill there (not disabled, blocked or other-OS) is missing.
    await gateway.skills.load(agentId: nil)
    let seedMissing = gateway.skills.skills.filter { $0.state == .needsSetup && !$0.platformIncompatible }.map(\.name)
    let wizardMissing = setup.skills?.missing.map(\.name) ?? []
    check(wizardMissing.contains("summarize") && Set(wizardMissing) == Set(seedMissing),
          "demo Skills: the seed's needs-setup skills are missing, summarize included (\(wizardMissing) vs \(seedMissing))")
    check(skills.isDone && !skills.needsAttention, "optional skills never need attention (\(skills))")
    check(setup.skills?.missing.first { $0.name == "summarize" }?.missing == ["summarize"], "demo summarize is missing its CLI")
    check(!setup.hasAdmin && setup.needsFullManagement(.agent) && !setup.needsFullManagement(.skills),
          "demo has no Full Management: agent defaults locked, rest read-only (admin \(setup.hasAdmin))")
    check(gateway.hello?.scopes.contains(GatewayConnection.adminScope) == false && !setup.hasAdmin,
          "demo setup is read-only: admin comes from hello.scopes (health.hasAdmin \(gateway.health.hasAdmin))")
    check(gateway.setupDefaultsBlocker == SetupWizardModel.fullManagementMessage, "saving defaults is blocked with the Full Management copy")

    // ⌘K item.
    let item = CommandPalette.setupGatewayItem(gateway: gateway)
    check(item?.id == "command:setupGateway" && item?.title == "Set Up Gateway…" && item?.subtitle == "2 of 3 steps",
          "⌘K Set Up Gateway… (\(item?.subtitle ?? "nil"))")

    // Start Setup opens on the first step not done.
    setup.startSetup()
    check(!setup.showsIntro && setup.currentStep == setup.resumeStep && setup.currentStep == .testMessage,
          "Start Setup opens on the first step not done, Test Message (\(setup.currentStep))")
    setup.present(at: .skills)
    setup.skipCurrent()
    check(setup.status(of: .skills).isDone && setup.currentStep == .testMessage, "skipping a done step moves on and it stays Done")
    setup.goBack()
    check(setup.currentStep == .skills, "Back returns to Skills")
    setup.unskip(.skills)
    setup.skip(.testMessage)
    check(setup.status(of: .testMessage) == .skipped && setup.progress.completed, "skipping the last open step completes setup")
    setup.unskip(.testMessage)
    check(!setup.status(of: .testMessage).isSettled, "unskip restores Not Checked (\(setup.status(of: .testMessage)))")

    // Test message: a demo chat that gets a demo reply.
    let (chatKey, outcome) = await gateway.sendSetupTestMessage(SetupWizardModel.testMessageText)
    if case .sent = outcome {} else { check(false, "demo test message sent (\(outcome))") }
    check(chatKey != nil && setup.status(of: .testMessage).isDone, "Test Message is Done once sent (\(setup.status(of: .testMessage)))")
    if let chatKey {
        let chat = gateway.chat(for: chatKey)
        let replied = await waitFor("demo test reply", timeout: 20) {
            !chat.isRunning && chat.items.contains { $0.role == .assistant && !$0.plainText.isEmpty }
        }
        check(replied && chat.items.contains { $0.role == .user && $0.plainText == SetupWizardModel.testMessageText }, "demo replies to the test message")
        check(gateway.sessions.contains { $0.key == chatKey }, "the test chat is listed")
        _ = await waitFor("test chat row") { gateway.sessions.contains { $0.key == chatKey } }
        let (secondKey, secondOutcome) = await gateway.sendSetupTestMessage("hello again")
        if case .sent = secondOutcome {} else { check(false, "second test message sent (\(secondOutcome))") }
        check(secondKey == chatKey, "a second test message reuses the \(GatewayStore.setupTestLabel) chat (\(secondKey ?? "nil") vs \(chatKey))")
        check(gateway.sessions.values.filter { $0.raw["label"]?.text == GatewayStore.setupTestLabel }.count == 1, "only one Setup Test chat")
        _ = await waitFor("second demo reply", timeout: 20) { !chat.isRunning }
    }

    setup.finish()
    check(setup.progress.completed && !setup.isPresented, "Finish completes and closes")
    check(UserDefaults.standard.object(forKey: key) == nil, "demo setup progress is never saved")

    // A demo connection alone doesn't pop it up; an explicit offer shows it again.
    let again = GatewayStore(profile: .demo())
    again.start()
    _ = await waitFor("demo reconnect") { again.state.isConnected && !again.sessions.isEmpty }
    // Negative window: a connection alone must not offer setup.
    try? await Task.sleep(for: .milliseconds(300))
    check(!again.setup.isPresented && !again.setup.isShowingOrPending, "a demo connection alone doesn't offer setup")
    again.setup.requestOffer(connected: true)
    check(again.setup.isPresented && again.setup.showsIntro, "an explicit offer shows demo setup again")
    setupCleanup(again)
}

@MainActor
func runLiveSetup(url: String, token: String) async {
    // Standard access: read-only wizard.
    let reader = GatewayProfile(name: "Mock setup", url: url, authMode: .token)
    reader.secret = token
    UserDefaults.standard.removeObject(forKey: SetupProgress.key(for: reader.id))
    guard let gateway = await setupConnect(reader, "mock for setup") else { return }
    let setup = gateway.setup
    let offered = await waitFor("mock setup offer") { setup.isPresented }
    check(offered && setup.showsIntro && !setup.isDemo, "first connection offers Set Up")
    let mockLoaded = await setupLoaded(gateway, "mock setup checks")
    check(mockLoaded, "mock setup checks load")
    // Earlier live Skills checks install and fix some skills, so only check the ones they leave alone.
    check(Set(["notion", "voice-call"]).isSubset(of: setup.skills?.missing.map(\.name) ?? []), "skills.status: needs-setup skills missing (\(setup.skills?.missing.map(\.name) ?? []))")
    check(setup.status(of: .skills).isDone, "Skills is Done even with skills not set up (\(setup.status(of: .skills)))")
    check(!setup.hasAdmin && setup.needsFullManagement(.agent), "standard access can't change agent defaults")
    setup.notNow()
    check(!setup.isPresented && setup.progress.offered && !setup.progress.completed, "Not Now closes but stays resumable")
    check(SetupProgress.load(gatewayId: gateway.id, defaults: .standard)?.offered == true, "offered is saved per gateway")
    let (_, outcome) = await gateway.sendSetupTestMessage("hello")
    if case .sent = outcome {} else { check(false, "mock test message sent (\(outcome))") }
    check(setup.status(of: .testMessage).isDone && SetupProgress.load(gatewayId: gateway.id, defaults: .standard)?.testMessageSent == true,
          "mock test message saved as sent")
    gateway.stop()

    // Reconnecting doesn't pop up again; resume opens on the first not-done step.
    let back = GatewayStore(profile: reader)
    back.start()
    _ = await waitFor("mock reconnect") { back.state.isConnected && !back.sessions.isEmpty }
    // Negative window: reconnecting must not offer setup again.
    try? await Task.sleep(for: .milliseconds(300))
    check(!back.setup.isPresented, "not offered again after Not Now")
    _ = await setupLoaded(back, "mock resume checks")
    back.setup.present()
    check(back.setup.isPresented && !back.setup.showsIntro && back.setup.currentStep == back.setup.resumeStep
          && back.setup.status(of: .testMessage).isDone, "Set Up Gateway… resumes with saved statuses at \(back.setup.currentStep)")
    back.setup.close()
    setupCleanup(back)

    // Full Management: agent defaults unlocked.
    let admin = GatewayProfile(name: "Mock setup admin", url: url, authMode: .token, access: .admin)
    admin.secret = token
    guard let manager = await setupConnect(admin, "mock admin for setup") else { return }
    defer { setupCleanup(manager) }
    _ = await setupLoaded(manager, "mock admin setup checks")
    let wizard = manager.setup
    check(wizard.hasAdmin && !wizard.needsFullManagement(.agent), "Full Management can change agent defaults")
    check(manager.setupDefaultsBlocker == nil, "saving defaults isn't blocked with Full Management (\(manager.setupDefaultsBlocker ?? "nil"))")
}
