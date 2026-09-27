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
    return await waitFor(label) {
        gateway.setup.channels != nil && gateway.setup.skills != nil
            && !gateway.setup.status(of: .health).isNotChecked && !gateway.setup.status(of: .agent).isNotChecked
    }
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
    // What AppModel.openDemo (Try the Demo) does for a new demo gateway.
    gateway.setup.requestOffer(connected: false)
    gateway.start()
    let demoUp = await waitFor("demo for setup") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(demoUp, "demo for setup connected")
    guard demoUp else { return }
    defer { setupCleanup(gateway) }
    let setup = gateway.setup

    // Offered at once, as the intro page.
    let offered = await waitFor("demo setup offer") { setup.isPresented }
    check(offered && setup.showsIntro && setup.isDemo, "Try the Demo offers Set Up at once (presented \(setup.isPresented), intro \(setup.showsIntro))")
    let demoLoaded = await setupLoaded(gateway, "demo setup checks")
    check(demoLoaded, "demo setup checks load")

    // Seeded statuses.
    check(setup.status(of: .health).isDone, "demo Health is Done (\(setup.status(of: .health)))")
    let channels = setup.status(of: .channels)
    check(channels.needsAttention && channels.label == "Needs Attention", "demo Channels needs attention (\(channels))")
    check(setup.channels?.channels.contains { $0.id == "telegram" && !$0.problemAccounts.isEmpty } == true,
          "Telegram is the degraded channel")
    check(setup.status(of: .agent).isDone, "demo Agent & Model is Done (\(setup.status(of: .agent)))")
    let skills = setup.status(of: .skills)
    check(skills.needsAttention && setup.skills?.missing.map(\.name) == ["summarize"],
          "demo Skills: exactly summarize missing (\(skills), \(setup.skills?.missing.map(\.name) ?? []))")
    check(!setup.hasAdmin && setup.needsFullManagement(.channels) && setup.needsFullManagement(.agent)
          && !setup.needsFullManagement(.health) && !setup.canStartQRLogin(channel: "whatsapp"),
          "demo has no Full Management: channel and agent actions locked, rest read-only (admin \(setup.hasAdmin), qr \(setup.canStartQRLogin(channel: "whatsapp")))")
    check(gateway.hello?.methods.contains("web.login.start") == false, "demo doesn't advertise web.login.*")
    check(gateway.hello?.scopes.contains(GatewayConnection.adminScope) == false && !setup.hasAdmin,
          "demo setup is read-only: admin comes from hello.scopes (health.hasAdmin \(gateway.health.hasAdmin))")
    check(gateway.setupDefaultsBlocker == SetupWizardModel.fullManagementMessage, "saving defaults is blocked with the Full Management copy")

    // Start Setup opens on the first step not done.
    setup.startSetup()
    check(!setup.showsIntro && setup.currentStep == setup.resumeStep && setup.currentStep == .channels,
          "Start Setup opens on the first step not done, Channels (\(setup.currentStep))")
    setup.present(at: .channels)
    setup.skipCurrent()
    check(setup.status(of: .channels) == .skipped && setup.currentStep == .agent, "skip marks Channels skipped and moves on")
    setup.goBack()
    check(setup.currentStep == .channels, "Back returns to a skipped step")
    setup.unskip(.channels)
    check(setup.status(of: .channels).needsAttention, "unskip restores Needs Attention")

    // ⌘K item.
    let item = CommandPalette.setupGatewayItem(gateway: gateway)
    check(item?.id == "command:setupGateway" && item?.title == "Set Up Gateway…" && item?.subtitle == "2 of 5 steps",
          "⌘K Set Up Gateway… (\(item?.subtitle ?? "nil"))")

    // Test message: a demo chat that gets a demo reply.
    let (chatKey, outcome) = await gateway.sendSetupTestMessage(SetupWizardModel.testMessageText)
    if case .sent = outcome {} else { check(false, "demo test message sent (\(outcome))") }
    check(chatKey != nil && setup.status(of: .testMessage).isDone, "Test Message is Done once sent (\(setup.status(of: .testMessage)))")
    if let chatKey {
        let chat = gateway.chat(for: chatKey)
        let replied = await waitFor("demo test reply", timeout: 20) {
            !chat.isRunning && chat.items.contains { $0.role == .assistant && !$0.plainText.isEmpty }
        }
        check(replied && chat.items.contains { $0.role == .user && $0.plainText == "hello" }, "demo replies to the test hello")
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

    // A demo connection without Try the Demo doesn't pop it up; Try the Demo again offers it again.
    let again = GatewayStore(profile: .demo())
    again.start()
    _ = await waitFor("demo reconnect") { again.state.isConnected && !again.sessions.isEmpty }
    try? await Task.sleep(for: .milliseconds(300))
    check(!again.setup.isPresented && !again.setup.isShowingOrPending, "a demo connection alone doesn't offer setup")
    again.setup.requestOffer(connected: true)
    check(again.setup.isPresented && again.setup.showsIntro, "Try the Demo again offers setup again")
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
    let whatsapp = setup.channels?.channels.first { $0.id == "whatsapp" }
    check(setup.channels?.channels.map(\.id).contains("discord") == true && whatsapp != nil,
          "channels.status lists Discord and WhatsApp (\(setup.channels?.channels.map(\.id) ?? []))")
    check(setup.skills?.missing.map(\.name) == ["summarize"], "skills.status: summarize missing (\(setup.skills?.missing.map(\.name) ?? []))")
    check(setup.status(of: .skills).needsAttention, "Skills needs attention")
    check(!setup.hasAdmin && setup.needsFullManagement(.channels) && !setup.canStartQRLogin(channel: "whatsapp"),
          "standard access can't start a QR login")
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
    try? await Task.sleep(for: .milliseconds(300))
    check(!back.setup.isPresented, "not offered again after Not Now")
    _ = await setupLoaded(back, "mock resume checks")
    back.setup.present()
    check(back.setup.isPresented && !back.setup.showsIntro && back.setup.currentStep == back.setup.resumeStep
          && back.setup.status(of: .testMessage).isDone, "Set Up Gateway… resumes with saved statuses at \(back.setup.currentStep)")
    back.setup.close()
    setupCleanup(back)

    // Full Management: QR login links WhatsApp.
    let admin = GatewayProfile(name: "Mock setup admin", url: url, authMode: .token, access: .admin)
    admin.secret = token
    guard let manager = await setupConnect(admin, "mock admin for setup") else { return }
    defer { setupCleanup(manager) }
    _ = await setupLoaded(manager, "mock admin setup checks")
    let wizard = manager.setup
    check(wizard.hasAdmin && !wizard.needsFullManagement(.channels) && wizard.canStartQRLogin(channel: "whatsapp"),
          "Full Management can start a WhatsApp QR login")
    check(!wizard.canStartQRLogin(channel: "discord"), "no QR login for Discord")
    check(manager.hello?.methods.contains("web.login.start") == false && manager.hello?.methods.contains("channels.status") == true,
          "web.login.* isn't advertised (like upstream), yet QR login is offered")
    wizard.startQRLogin(channel: "whatsapp")
    let showing = await waitFor("QR shown") { if case .showing = wizard.qrLogin(channel: "whatsapp") { true } else { false } }
    check(showing, "web.login.start shows a QR (\(wizard.qrLogin(channel: "whatsapp")))")
    let linked = await waitFor("WhatsApp linked", timeout: 30) {
        if case .connected = wizard.qrLogin(channel: "whatsapp") { true } else { false }
    }
    check(linked, "web.login.wait links WhatsApp (\(wizard.qrLogin(channel: "whatsapp")))")
    let refreshed = await waitFor("WhatsApp connected in channels.status") {
        wizard.channels?.channels.first { $0.id == "whatsapp" }?.problemAccounts.isEmpty == true
    }
    check(refreshed, "channels.status reloaded after linking")
    wizard.startQRLogin(channel: "whatsapp")
    let already = await waitFor("already linked") {
        switch wizard.qrLogin(channel: "whatsapp") {
        case .connected, .failed: true
        default: false
        }
    }
    if case .connected = wizard.qrLogin(channel: "whatsapp") {} else {
        check(false, "starting again on a linked WhatsApp reports it linked (\(wizard.qrLogin(channel: "whatsapp")), already \(already))")
    }
    wizard.cancelQRLogin(channel: "whatsapp")
    check(wizard.qrLogin(channel: "whatsapp") == .idle, "cancel clears the QR login")
}
