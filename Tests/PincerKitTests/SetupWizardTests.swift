import Foundation
import Testing
@testable import PincerKit

/// `skills.status` fixtures in the Gateway's shape (as `mock-gateway/setup.mjs`).
enum SetupFixtures {
    static func skill(_ name: String, eligible: Bool = true, missingBins: [String] = [], os: [String] = [],
                      disabled: Bool = false) -> String
    {
        let bins = missingBins.map { "\"\($0)\"" }.joined(separator: ",")
        let oses = os.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"name":"\(name)","description":"d","source":"openclaw-bundled","bundled":true,"filePath":"f","baseDir":"b",
         "skillKey":"\(name)","always":false,"disabled":\(disabled),"blockedByAllowlist":false,"blockedByAgentFilter":false,
         "eligible":\(eligible),"platformIncompatible":\(!os.isEmpty),"modelVisible":\(eligible),"userInvocable":true,
         "commandVisible":\(eligible),"requirements":{"bins":[],"anyBins":[],"env":[],"config":[],"os":[]},
         "missing":{"bins":[\(bins)],"anyBins":[],"env":[],"config":[],"os":[\(oses)]},"configChecks":[],
         "install":[{"id":"brew","kind":"brew","label":"Install \(name) (brew)","bins":[\(bins)]}]}
        """
    }

    static func skills(_ entries: [String]) -> JSONValue {
        Fixtures.json(#"{"workspaceDir":"/w","managedSkillsDir":"/m","agentId":"main","skills":["# + entries.joined(separator: ",") + "]}")
    }

    static let skillsOneMissing = skills([
        skill("github"), skill("weather"), skill("summarize", eligible: false, missingBins: ["summarize"]),
        skill("apple-notes", eligible: false, missingBins: ["memo"], os: ["darwin"]),
        skill("off", eligible: false, disabled: true),
    ])
}

/// Records calls; answers from `results`, throws for anything else.
@MainActor
final class SetupFakeGateway {
    var results: [String: JSONValue] = [:]
    var calls: [(String, JSONValue)] = []
    var failure: Error?

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        self.calls.append((method, params))
        if let failure { throw failure }
        guard let result = self.results[method] else {
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
        return result
    }
}

@MainActor
@Suite struct SetupWizardTests {
    // MARK: Parsing and rules

    @Test func skillsParseAndRule() throws {
        let report = try #require(SetupSkillsReport(SetupFixtures.skillsOneMissing))
        #expect(report.skills.count == 5)
        #expect(report.missing.map(\.name) == ["summarize"], "macOS-only and disabled skills aren't missing")
        #expect(report.missing[0].missing == ["summarize"] && report.missing[0].installOptions == ["Install summarize (brew)"])
        #expect(report.ready.map(\.name) == ["github", "weather"])
        let apple = try #require(report.skills.first { $0.name == "apple-notes" })
        #expect(apple.platformIncompatible && !apple.isMissingRequirements)
        // Skills are optional (#175): skills that aren't set up are info, never Needs Attention.
        #expect(SetupRules.skills(report) == .done("2 skills are ready. 1 isn't set up."))
        let ready = try #require(SetupSkillsReport(SetupFixtures.skills([SetupFixtures.skill("github")])))
        #expect(SetupRules.skills(ready) == .done("1 skill is ready."))
        let two = try #require(SetupSkillsReport(SetupFixtures.skills([
            SetupFixtures.skill("a", eligible: false, missingBins: ["a"]), SetupFixtures.skill("b", eligible: false, missingBins: ["b"]),
        ])))
        #expect(SetupRules.skills(two) == .done("0 skills are ready. 2 aren't set up."))
        #expect(!SetupRules.skills(two).needsAttention)
        #expect(SetupRules.skills(nil, failure: "x") == .notChecked("x"))
        #expect(SetupSkillsReport(Fixtures.json("{}")) == nil)
    }

    @Test func agentAndTestMessageRules() {
        let agents = [AgentSummary(Fixtures.json(#"{"id":"main","name":"Claw"}"#))!]
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: "anthropic/claude-opus-4-8", loaded: true)
            == .done("Claw · claude-opus-4-8"))
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: nil, loaded: true).needsAttention)
        #expect(SetupRules.agent(agents: [], defaultAgentId: "main", defaultModelRef: "a/b", loaded: true).needsAttention)
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: "a/b", loaded: false) == .notChecked(nil))

        #expect(SetupRules.testMessage(sent: true) == .done("Your test message was sent."))
        #expect(SetupRules.testMessage(sent: false) == .notChecked(nil))
        #expect(SetupRules.resolved(.needsAttention("x"), skipped: true) == .skipped)
        #expect(SetupRules.resolved(.done("x"), skipped: true).isDone, "done wins over skipped")
        #expect(SetupRules.resolved(.needsAttention("x"), skipped: false).needsAttention)
    }

    @Test func statusPresentation() {
        #expect(SetupStepStatus.done("x").symbol == "checkmark.circle.fill" && SetupStepStatus.done("x").label == "Done")
        #expect(SetupStepStatus.needsAttention("x").symbol == "exclamationmark.triangle.fill")
        #expect(SetupStepStatus.needsAttention("x").label == "Needs Attention")
        #expect(SetupStepStatus.skipped.symbol == "arrow.uturn.forward.circle" && SetupStepStatus.skipped.label == "Skipped")
        #expect(SetupStepStatus.notChecked(nil).symbol == "circle" && SetupStepStatus.notChecked(nil).label == "Not Checked")
        #expect(SetupStep.allCases == [.agent, .skills, .testMessage], "Health moved to Verify, Channels left setup (#175)")
        #expect(SetupStep.allCases.allSatisfy { !$0.summary.isEmpty && !$0.title.isEmpty })
    }

    // MARK: Persistence and offering

    @Test func progressPersistsPerGateway() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (a, b) = (UUID(), UUID())
        #expect(SetupProgress.load(gatewayId: a, defaults: scratch.defaults) == nil)
        SetupProgress(offered: true, skipped: [.skills], testMessageSent: true).save(gatewayId: a, defaults: scratch.defaults)
        let loaded = try #require(SetupProgress.load(gatewayId: a, defaults: scratch.defaults))
        #expect(loaded.offered && !loaded.completed && loaded.skipped == [.skills] && loaded.testMessageSent)
        #expect(SetupProgress.load(gatewayId: b, defaults: scratch.defaults) == nil, "per gateway")
        #expect(SetupProgress.key(for: a) != SetupProgress.key(for: b))
    }

    @Test func progressFromBeforeFirstRunStillLoads() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let id = UUID()
        let old = #"{"offered":true,"completed":false,"skipped":["health","channels","skills"],"testMessageSent":false}"#
        scratch.defaults.set(Data(old.utf8), forKey: SetupProgress.key(for: id))
        let loaded = try #require(SetupProgress.load(gatewayId: id, defaults: scratch.defaults))
        #expect(loaded.offered && loaded.skipped == [.skills], "removed steps are dropped, not a decode failure")
    }

    @Test func shouldOffer() {
        #expect(SetupProgress.shouldOffer(nil, connectedBefore: false, isDemo: false))
        #expect(!SetupProgress.shouldOffer(nil, connectedBefore: true, isDemo: false), "existing gateways aren't nagged")
        #expect(SetupProgress.shouldOffer(nil, connectedBefore: true, isDemo: true))
        #expect(!SetupProgress.shouldOffer(SetupProgress(offered: true), connectedBefore: false, isDemo: false), "Not Now")
        #expect(!SetupProgress.shouldOffer(SetupProgress(completed: true), connectedBefore: false, isDemo: false))
        #expect(SetupProgress.shouldOffer(SetupProgress(), connectedBefore: false, isDemo: false))
    }

    private func model(_ gateway: SetupFakeGateway, id: UUID = UUID(), defaults: UserDefaults, isDemo: Bool = false,
                       agent: SetupStepStatus = .done("Claw"), admin: Bool = true, methods: Set<String>? = nil) -> SetupWizardModel
    {
        SetupWizardModel(gatewayId: id, isDemo: isDemo, defaults: defaults, environment: .init(
            request: { try await gateway.request($0, $1) }, hasAdmin: { admin }, methods: { methods },
            agentStatus: { agent }))
    }

    @Test func offerNotNowAndResume() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let wizard = self.model(gateway, id: id, defaults: scratch.defaults)
        wizard.connected()
        #expect(wizard.isPresented && wizard.showsIntro && wizard.progress.offered)
        await wizard.load()
        #expect(Set(gateway.calls.map(\.0)) == ["skills.status"], "channels.status isn't part of setup any more")
        wizard.notNow()
        #expect(!wizard.isPresented)
        wizard.connected()
        #expect(!wizard.isPresented, "Not Now isn't offered again")

        // Relaunch: still offered, not completed; resume opens on the first step that isn't done.
        let again = self.model(gateway, id: id, defaults: scratch.defaults)
        again.connected()
        #expect(!again.isPresented && again.progress.offered && !again.progress.completed)
        await again.load()
        again.present()
        #expect(again.isPresented && !again.showsIntro && again.currentStep == .testMessage)
        #expect(again.status(of: .skills).isDone && again.status(of: .agent).isDone)
        #expect(!again.status(of: .testMessage).isSettled)
        again.close()
    }

    @Test func skipBackFinish() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let wizard = self.model(gateway, id: id, defaults: scratch.defaults, agent: .needsAttention("No default model"))
        wizard.present(at: .agent)
        await wizard.load()
        #expect(wizard.currentStep == .agent && wizard.previousStep == nil)
        wizard.skipCurrent()
        #expect(wizard.currentStep == .skills && wizard.status(of: .agent) == .skipped)
        wizard.goBack()
        #expect(wizard.currentStep == .agent, "skipped steps can be revisited")
        wizard.unskip(.agent)
        #expect(wizard.status(of: .agent).needsAttention)
        wizard.skip(.agent)
        wizard.present(at: .testMessage)
        #expect(wizard.nextStep == nil)
        wizard.markTestMessageSent()
        #expect(wizard.status(of: .testMessage).isDone)
        wizard.advance()
        #expect(!wizard.isPresented && wizard.progress.completed, "Continue on the last step finishes")
        let reloaded = try #require(SetupProgress.load(gatewayId: id, defaults: scratch.defaults))
        #expect(reloaded.completed && reloaded.testMessageSent)
    }

    @Test func skippingEverythingLeftCompletes() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["skills.status": SetupFixtures.skillsOneMissing]
        let wizard = self.model(gateway, defaults: scratch.defaults, agent: .needsAttention("x"))
        await wizard.load()
        wizard.skip(.agent)
        #expect(!wizard.progress.completed)
        wizard.skip(.testMessage)
        #expect(wizard.progress.completed, "skills are done, the rest skipped")
        #expect(wizard.settledCount == 3)
    }

    @Test func demoProgressIsNeverSaved() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let demo = self.model(gateway, id: id, defaults: scratch.defaults, isDemo: true)
        demo.connected()
        #expect(demo.isPresented && demo.showsIntro, "the demo offers setup right away")
        demo.skip(.testMessage)
        demo.finish()
        #expect(demo.progress.completed)
        #expect(scratch.defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("pincer.setup.") })
        #expect(SetupProgress.load(gatewayId: id, defaults: scratch.defaults) == nil)
    }

    @Test func unadvertisedMethodsAndFailures() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        let old = self.model(gateway, defaults: scratch.defaults, methods: ["health", "chat.send"])
        await old.load()
        #expect(!gateway.calls.contains { $0.0 == "skills.status" }, "not advertised: not called")
        #expect(!old.status(of: .skills).isSettled)

        gateway.failure = GatewayError.rpc(code: "UNAVAILABLE", message: "boom", details: nil)
        let failing = self.model(gateway, defaults: scratch.defaults)
        await failing.load()
        #expect(!failing.status(of: .skills).isSettled)
        #expect(failing.skillsFailure != nil)
    }

    @Test func fullManagementGate() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let reader = self.model(SetupFakeGateway(), defaults: scratch.defaults, admin: false)
        #expect(reader.needsFullManagement(.agent))
        #expect(!reader.needsFullManagement(.skills) && !reader.needsFullManagement(.testMessage))
        let admin = self.model(SetupFakeGateway(), defaults: scratch.defaults, admin: true)
        #expect(!admin.needsFullManagement(.agent))
        #expect(SetupWizardModel.fullManagementTitle == "Needs Full Management")
        #expect(SetupWizardModel.fullManagementMessage
            == "This device can view but not change this. Open Connection to request Full Management.")
    }

    // MARK: Inside the first-run wizard (#175)

    @Test func embeddedInFirstRun() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let wizard = self.model(gateway, id: id, defaults: scratch.defaults)
        wizard.markOffered()
        #expect(wizard.progress.offered && SetupProgress.load(gatewayId: id, defaults: scratch.defaults)?.offered == true)
        wizard.connected()
        #expect(!wizard.isPresented, "the first-run wizard shows these steps; no second offer")
        wizard.beginEmbedded()
        #expect(wizard.isEmbedded && !wizard.showsIntro && !wizard.isPresented)
        #expect(await self.waitFor { !gateway.calls.isEmpty }, "beginning loads the checks")
        #expect(wizard.currentStep != .agent, "starts past the done Agent step (\(wizard.currentStep))")
        wizard.advance()
        let step = wizard.currentStep
        wizard.beginEmbedded()
        #expect(wizard.currentStep == step, "beginning again keeps the step")
        wizard.endEmbedded()
        #expect(!wizard.isEmbedded && !wizard.progress.completed, "leaving keeps progress")
        wizard.beginEmbedded()
        wizard.finish()
        #expect(!wizard.isEmbedded && wizard.progress.completed)
        wizard.beginEmbedded()
        wizard.close()
        #expect(!wizard.isEmbedded)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        await eventually(timeout: .seconds(5), condition)
    }

    // MARK: Tips

    @Test func tipsCopyAndPlatform() {
        #expect(SetupTips.all.map(\.text) == [
            "Type / in the composer for slash commands.",
            "Ask for deeper reasoning with /think; expand a thinking section to read it.",
            "Approvals for commands and tools appear in the chat and as notifications. Allow once or always.",
            "Press ⌘K to jump to any chat, agent, model, or setting.",
            "Press ⌘F to find in the current chat.",
            "Search all messages from ⌘K or the sidebar search field.",
        ])
        let ios = SetupTips.tips(iOS: true).map(\.text)
        #expect(ios[3] == "Press ⌘K to jump to any chat, agent, model, or setting (iPad keyboard).")
        #expect(ios[0] == SetupTips.all[0].text)
        #expect(ios[4] == "Press ⌘F to find in the current chat (iPad keyboard).")
        #expect(ios[5] == SetupTips.all[5].text)
        #expect(SetupTips.tips(iOS: false).map(\.text) == SetupTips.all.map(\.text))
        let iPhone = SetupTips.tips(iOS: true, iPhone: true).map(\.text)
        #expect(!iPhone.contains { $0.contains("⌘") })
        #expect(iPhone == [SetupTips.all[0].text, SetupTips.all[1].text, SetupTips.all[2].text,
                           "Search all messages from the sidebar search field."])
    }

    @Test func tipsShowOnceNeverOverSetup() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        tips.evaluate(connected: true, setupShowingOrPending: true, isDemo: false)
        #expect(!tips.isPresented, "never over the setup sheet")
        tips.evaluate(connected: false, setupShowingOrPending: false, isDemo: false)
        #expect(!tips.isPresented)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPresented)
        tips.evaluate(connected: true, setupShowingOrPending: true, isDemo: false)
        #expect(!tips.isPresented, "setup coming up hides the tips")
        tips.dismiss()
        #expect(tips.hasSeen && scratch.defaults.bool(forKey: SetupTips.seenKey))
        let relaunched = TipsModel(defaults: scratch.defaults, delay: .zero)
        relaunched.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(!relaunched.isPresented, "seen stays seen")
        relaunched.showAgain()
        #expect(!relaunched.hasSeen && !scratch.defaults.bool(forKey: SetupTips.seenKey))
        relaunched.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(relaunched.isPresented, "Show Tips Again")
    }

    /// The delay is a gate the test opens (like BackgroundRefresh's), so no wall-clock waits (#339).
    private func gatedTips(_ scratch: ScratchDefaults) -> (TipsModel, BackgroundRefreshTests.BudgetGate) {
        let gate = BackgroundRefreshTests.BudgetGate()
        return (TipsModel(defaults: scratch.defaults, delay: .seconds(60), sleep: { _ in await gate.wait() }), gate)
    }

    @Test func tipsPresentAfterDelay() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (tips, gate) = self.gatedTips(scratch)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPending && !tips.isPresented)
        let pending = try #require(tips.pendingTask)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPending && !tips.isPresented, "repeat evaluate keeps the timer")
        #expect(tips.pendingTask == pending, "repeat evaluate doesn't restart the timer")
        gate.expire()
        await pending.value
        #expect(tips.isPresented && !tips.isPending)
    }

    @Test func tipsDelayCancelledBySetup() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (tips, gate) = self.gatedTips(scratch)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        let pending = try #require(tips.pendingTask)
        tips.evaluate(connected: true, setupShowingOrPending: true, isDemo: false)
        #expect(!tips.isPending)
        gate.expire()
        await pending.value
        #expect(!tips.isPresented, "setup appearing cancels the pending card")
        tips.evaluate(connected: false, setupShowingOrPending: false, isDemo: false)
        #expect(!tips.isPending)
    }

    @Test func tipsDismissCancelsPending() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (tips, gate) = self.gatedTips(scratch)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        let pending = try #require(tips.pendingTask)
        tips.dismiss()
        #expect(!tips.isPending)
        gate.expire()
        await pending.value
        #expect(!tips.isPresented && tips.hasSeen)
    }

    // MARK: Notification prompt (#332)

    @Test func tipsWaitForThePermissionPrompt() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: true)
        #expect(!tips.isPresented && !tips.isPending, "nothing while the prompt is up")
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: false)
        #expect(tips.isPresented, "the prompt is answered")
    }

    @Test func tipsCountdownDoesNotStartDuringThePromptAndCancelsWhenItAppears() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (tips, gate) = self.gatedTips(scratch)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: true)
        #expect(!tips.isPending && tips.pendingTask == nil)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        let pending = try #require(tips.pendingTask)
        #expect(tips.isPending)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: true)
        #expect(!tips.isPending, "a prompt appearing cancels the countdown")
        gate.expire()
        await pending.value
        #expect(!tips.isPresented)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: false)
        #expect(tips.isPending, "the countdown starts once the prompt is gone")
    }

    @Test func tipsAlreadyShownStayWhenThePromptAppears() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPresented)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false, permissionPromptShowing: true)
        #expect(tips.isPresented, "the prompt doesn't hide a card that's already up")
        tips.evaluate(connected: true, setupShowingOrPending: true, isDemo: false, permissionPromptShowing: true)
        #expect(!tips.isPresented, "setup still does")
    }

    @Test @MainActor func notificationPromptFlagIsSettable() {
        let prompt = NotificationPrompt()
        #expect(!prompt.isShowing)
        prompt.isShowing = true
        #expect(prompt.isShowing)
    }

    @Test func tipsZeroDelayPresentsSynchronously() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let tips = TipsModel(defaults: scratch.defaults, delay: .zero)
        tips.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(tips.isPresented && !tips.isPending)
    }

    // MARK: Config edits and ⌘K

    @Test func defaultsEdits() {
        let config = Fixtures.json(#"{"agents":{"defaults":{"model":{"primary":"anthropic/claude-opus-4-8"}},"entries":{"main":{"default":true},"coder":{}}}}"#)
        let edits = SetupRules.defaultsEdits(config: config, agentId: "coder", modelRef: "openai/gpt-5.6-sol")
        #expect(edits.map(\.path) == [["agents", "entries", "main", "default"], ["agents", "entries", "coder", "default"],
                                      ["agents", "defaults", "model", "primary"]])
        #expect(absent(edits[0].value) && edits[1].value == true && edits[2].value == "openai/gpt-5.6-sol")
        #expect(SetupRules.defaultsEdits(config: config, agentId: "main", modelRef: "anthropic/claude-opus-4-8").isEmpty,
                "nothing to save when already set")
        let plain = Fixtures.json(#"{"agents":{"defaults":{"model":"anthropic/claude-sonnet-4-5"}}}"#)
        #expect(SetupRules.defaultsEdits(config: plain, agentId: nil, modelRef: "a/b").map(\.path) == [["agents", "defaults", "model"]])
    }

    @Test func paletteCommand() {
        let store = GatewayStore(profile: .demo())
        let item = CommandPalette.setupGatewayItem(gateway: store)
        #expect(item?.id == "command:setupGateway" && item?.title == "Set Up Gateway…")
        let keywords = Set(item?.keywords ?? [])
        #expect(keywords.isSuperset(of: ["setup", "wizard", "onboarding", "getting started"]))
        #expect(CommandPalette.setupGatewayItem(gateway: nil) == nil)
        #expect(item?.isEnabled == false && item?.isSelectable == false, "disabled while disconnected")
    }

    // MARK: Offer control (demo)

    @Test func autoOffersOffMeansNoOffer() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let wizard = self.model(SetupFakeGateway(), defaults: scratch.defaults, isDemo: true)
        wizard.autoOffers = false
        #expect(!wizard.isShowingOrPending, "not pending, so tips don't wait for it")
        wizard.connected()
        #expect(!wizard.isPresented && !wizard.progress.offered)
    }

    @Test func requestOfferOffersOnceThenStops() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let wizard = self.model(SetupFakeGateway(), defaults: scratch.defaults, isDemo: true)
        wizard.autoOffers = false
        wizard.requestOffer(connected: false)
        #expect(!wizard.isPresented && wizard.isShowingOrPending, "pending until the connection")
        wizard.connected()
        #expect(wizard.isPresented && wizard.showsIntro && !wizard.autoOffers)
        wizard.notNow()
        wizard.connected()
        #expect(!wizard.isPresented, "a reconnect doesn't offer it again")
        // Try the Demo again while connected offers it at once, even after Not Now.
        wizard.requestOffer(connected: true)
        #expect(wizard.isPresented && wizard.showsIntro)
        #expect(scratch.defaults.object(forKey: SetupProgress.key(for: wizard.gatewayId)) == nil, "demo never saved")
    }

    @Test func withdrawOfferCancelsPendingDemoOffer() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let wizard = self.model(SetupFakeGateway(), defaults: scratch.defaults, isDemo: true)
        wizard.autoOffers = false
        wizard.requestOffer(connected: false)
        wizard.withdrawOffer()
        #expect(!wizard.isShowingOrPending)
        wizard.connected()
        #expect(!wizard.isPresented)
        // A real gateway keeps offering.
        let real = self.model(SetupFakeGateway(), defaults: scratch.defaults)
        real.withdrawOffer()
        #expect(real.autoOffers && real.isShowingOrPending)
    }
}
