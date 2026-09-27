import Foundation
import Testing
@testable import PincerKit

/// `channels.status` and `skills.status` fixtures in the Gateway's shapes (as `mock-gateway/setup.mjs`).
enum SetupFixtures {
    static let channelsStatus = Fixtures.json(#"""
    {"ts":1700000000000,"channelOrder":["discord","whatsapp","slack"],
     "channelLabels":{"discord":"Discord","whatsapp":"WhatsApp","slack":"Slack"},
     "channels":{"discord":{"configured":true,"running":true,"connected":true},
                 "whatsapp":{"enabled":true,"configured":false,"linked":false,"running":false,"connected":false},
                 "slack":{"enabled":false,"configured":false}},
     "channelAccounts":{
       "discord":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true}],
       "whatsapp":[{"accountId":"default","enabled":true,"configured":false,"linked":false,"running":false,"connected":false}],
       "slack":[{"accountId":"default","enabled":false,"configured":false,"running":false,"connected":false}]},
     "channelDefaultAccountId":{"discord":"default","whatsapp":"default","slack":"default"},
     "statusIssues":[{"channel":"whatsapp","accountId":"default","kind":"auth",
                      "message":"Not linked (no WhatsApp Web session).","fix":"Run: openclaw channels login"}]}
    """#)

    static let degradedChannels = Fixtures.json(#"""
    {"ts":1,"channelOrder":["discord","telegram"],"channelLabels":{"discord":"Discord","telegram":"Telegram"},
     "channels":{},
     "channelAccounts":{
       "discord":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true}],
       "telegram":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":false,
                    "lastError":"Telegram API timed out (getUpdates). Retrying."}]},
     "channelDefaultAccountId":{"discord":"default","telegram":"default"}}
    """#)

    static let connectedChannels = Fixtures.json(#"""
    {"ts":1,"channelOrder":["discord"],"channelLabels":{"discord":"Discord"},"channels":{},
     "channelAccounts":{"discord":[{"accountId":"default","enabled":true,"configured":true,"running":true,"connected":true}]},
     "channelDefaultAccountId":{"discord":"default"}}
    """#)

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

    @Test func channelsStatusParses() throws {
        let snapshot = try #require(SetupChannelsSnapshot(SetupFixtures.channelsStatus))
        #expect(snapshot.channels.map(\.id) == ["discord", "whatsapp", "slack"])
        #expect(snapshot.channels.map(\.label) == ["Discord", "WhatsApp", "Slack"])
        #expect(snapshot.channels[0].status == .connected)
        #expect(snapshot.issues.count == 1 && snapshot.issues[0].channel == "whatsapp" && snapshot.issues[0].kind == "auth")
        #expect(snapshot.issues[0].fix == "Run: openclaw channels login")
        #expect(SetupChannelsSnapshot(.null) == nil && SetupChannelsSnapshot(Fixtures.json("[]")) == nil)
    }

    @Test func channelsRule() throws {
        #expect(SetupRules.channels(nil) == .notChecked(nil))
        #expect(SetupRules.channels(nil, failure: "nope") == .notChecked("nope"))
        let unlinked = try #require(SetupChannelsSnapshot(SetupFixtures.channelsStatus))
        #expect(SetupRules.channels(unlinked) == .needsAttention("WhatsApp: Not linked (no WhatsApp Web session)."))
        let degraded = try #require(SetupChannelsSnapshot(SetupFixtures.degradedChannels))
        #expect(SetupRules.channels(degraded) == .needsAttention("Telegram: Telegram API timed out (getUpdates). Retrying."))
        let fine = try #require(SetupChannelsSnapshot(SetupFixtures.connectedChannels))
        #expect(SetupRules.channels(fine) == .done("Discord is connected."))
        let empty = try #require(SetupChannelsSnapshot(Fixtures.json(#"{"channelOrder":[],"channelAccounts":{}}"#)))
        #expect(SetupRules.channels(empty).needsAttention)
    }

    @Test func skillsParseAndRule() throws {
        let report = try #require(SetupSkillsReport(SetupFixtures.skillsOneMissing))
        #expect(report.skills.count == 5)
        #expect(report.missing.map(\.name) == ["summarize"], "macOS-only and disabled skills aren't missing")
        #expect(report.missing[0].missing == ["summarize"] && report.missing[0].installOptions == ["Install summarize (brew)"])
        #expect(report.ready.map(\.name) == ["github", "weather"])
        let apple = try #require(report.skills.first { $0.name == "apple-notes" })
        #expect(apple.platformIncompatible && !apple.isMissingRequirements)
        #expect(SetupRules.skills(report) == .needsAttention("summarize is missing requirements (needs summarize)."))
        let ready = try #require(SetupSkillsReport(SetupFixtures.skills([SetupFixtures.skill("github")])))
        #expect(SetupRules.skills(ready) == .done("1 skill is ready."))
        let two = try #require(SetupSkillsReport(SetupFixtures.skills([
            SetupFixtures.skill("a", eligible: false, missingBins: ["a"]), SetupFixtures.skill("b", eligible: false, missingBins: ["b"]),
        ])))
        #expect(SetupRules.skills(two) == .needsAttention("2 skills are missing requirements."))
        #expect(SetupRules.skills(nil, failure: "x") == .notChecked("x"))
        #expect(SetupSkillsReport(Fixtures.json("{}")) == nil)
    }

    @Test func healthAgentAndTestMessageRules() {
        #expect(SetupRules.health(level: .healthy, activeIssues: [], loaded: true).isDone)
        #expect(SetupRules.health(level: .healthy, activeIssues: [], loaded: false) == .notChecked(nil))
        let issue = GatewayHealthIssue(id: "channel:telegram", kind: .channel, title: "Telegram isn't connected")
        #expect(SetupRules.health(level: .degraded, activeIssues: [issue], loaded: true).needsAttention)
        #expect(SetupRules.health(level: .down, activeIssues: [], loaded: true).needsAttention)
        #expect(!SetupRules.health(level: .restarting, activeIssues: [], loaded: true).isSettled)

        let agents = [AgentSummary(Fixtures.json(#"{"id":"main","name":"Claw"}"#))!]
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: "anthropic/claude-opus-4-8", loaded: true)
            == .done("Claw · claude-opus-4-8"))
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: nil, loaded: true).needsAttention)
        #expect(SetupRules.agent(agents: [], defaultAgentId: "main", defaultModelRef: "a/b", loaded: true).needsAttention)
        #expect(SetupRules.agent(agents: agents, defaultAgentId: "main", defaultModelRef: "a/b", loaded: false) == .notChecked(nil))

        #expect(SetupRules.testMessage(sent: true).isDone && !SetupRules.testMessage(sent: false).isSettled)
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
        #expect(SetupStep.allCases == [.health, .channels, .agent, .skills, .testMessage])
    }

    @Test func webLoginResult() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let start = WebLoginResult(Fixtures.json(#"{"qrDataUrl":"data:image/png;base64,\#(png.base64EncodedString())","message":"Scan this QR in WhatsApp → Linked Devices."}"#))
        #expect(start.qrImageData == png && start.connected == nil)
        let linked = WebLoginResult(Fixtures.json(#"{"connected":true,"message":"✅ Linked! WhatsApp is ready."}"#))
        #expect(linked.connected == true && linked.qrImageData == nil)
        #expect(WebLoginResult(Fixtures.json(#"{"qrDataUrl":"https://x/y.png"}"#)).qrImageData == nil)
        #expect(SetupRules.supportsQRLogin("whatsapp") && !SetupRules.supportsQRLogin("discord"))
    }

    // MARK: Persistence and offering

    @Test func progressPersistsPerGateway() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (a, b) = (UUID(), UUID())
        #expect(SetupProgress.load(gatewayId: a, defaults: scratch.defaults) == nil)
        SetupProgress(offered: true, skipped: [.channels], testMessageSent: true).save(gatewayId: a, defaults: scratch.defaults)
        let loaded = try #require(SetupProgress.load(gatewayId: a, defaults: scratch.defaults))
        #expect(loaded.offered && !loaded.completed && loaded.skipped == [.channels] && loaded.testMessageSent)
        #expect(SetupProgress.load(gatewayId: b, defaults: scratch.defaults) == nil, "per gateway")
        #expect(SetupProgress.key(for: a) != SetupProgress.key(for: b))
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
                       health: SetupStepStatus = .done("ok"), agent: SetupStepStatus = .done("Claw"),
                       admin: Bool = true, methods: Set<String>? = nil) -> SetupWizardModel
    {
        SetupWizardModel(gatewayId: id, isDemo: isDemo, defaults: defaults, environment: .init(
            request: { try await gateway.request($0, $1) }, hasAdmin: { admin }, methods: { methods },
            healthStatus: { health }, agentStatus: { agent }))
    }

    @Test func offerNotNowAndResume() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["channels.status": SetupFixtures.channelsStatus, "skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let wizard = self.model(gateway, id: id, defaults: scratch.defaults)
        wizard.connected()
        #expect(wizard.isPresented && wizard.showsIntro && wizard.progress.offered)
        await wizard.load()
        #expect(Set(gateway.calls.map(\.0)) == ["channels.status", "skills.status"])
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
        #expect(again.isPresented && !again.showsIntro && again.currentStep == .channels)
        #expect(again.status(of: .health).isDone && again.status(of: .channels).needsAttention)
        #expect(again.status(of: .skills).needsAttention && again.status(of: .agent).isDone)
        #expect(!again.status(of: .testMessage).isSettled)
        again.close()
    }

    @Test func skipBackFinish() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["channels.status": SetupFixtures.channelsStatus, "skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let wizard = self.model(gateway, id: id, defaults: scratch.defaults)
        wizard.present(at: .channels)
        await wizard.load()
        #expect(wizard.currentStep == .channels && wizard.previousStep == .health)
        wizard.skipCurrent()
        #expect(wizard.currentStep == .agent && wizard.status(of: .channels) == .skipped)
        wizard.goBack()
        #expect(wizard.currentStep == .channels, "skipped steps can be revisited")
        wizard.unskip(.channels)
        #expect(wizard.status(of: .channels).needsAttention)
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
        gateway.results = ["channels.status": SetupFixtures.channelsStatus, "skills.status": SetupFixtures.skillsOneMissing]
        let wizard = self.model(gateway, defaults: scratch.defaults)
        await wizard.load()
        wizard.skip(.channels)
        wizard.skip(.skills)
        #expect(!wizard.progress.completed)
        wizard.skip(.testMessage)
        #expect(wizard.progress.completed, "health and agent are done, the rest skipped")
        #expect(wizard.settledCount == 5)
    }

    @Test func demoProgressIsNeverSaved() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        gateway.results = ["channels.status": SetupFixtures.channelsStatus, "skills.status": SetupFixtures.skillsOneMissing]
        let id = UUID()
        let demo = self.model(gateway, id: id, defaults: scratch.defaults, isDemo: true)
        demo.connected()
        #expect(demo.isPresented && demo.showsIntro, "the demo offers setup right away")
        demo.skip(.channels)
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
        #expect(!gateway.calls.contains { $0.0 == "channels.status" || $0.0 == "skills.status" }, "not advertised: not called")
        #expect(!old.status(of: .channels).isSettled && !old.status(of: .skills).isSettled)

        gateway.failure = GatewayError.rpc(code: "UNAVAILABLE", message: "boom", details: nil)
        let failing = self.model(gateway, defaults: scratch.defaults)
        await failing.load()
        #expect(!failing.status(of: .channels).isSettled && !failing.status(of: .skills).isSettled)
        #expect(failing.skillsFailure != nil)
    }

    @Test func fullManagementGate() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let reader = self.model(SetupFakeGateway(), defaults: scratch.defaults, admin: false)
        #expect(reader.needsFullManagement(.channels) && reader.needsFullManagement(.agent))
        #expect(!reader.needsFullManagement(.health) && !reader.needsFullManagement(.testMessage))
        #expect(!reader.canStartQRLogin(channel: "whatsapp"))
        let admin = self.model(SetupFakeGateway(), defaults: scratch.defaults, admin: true)
        #expect(!admin.needsFullManagement(.channels) && admin.canStartQRLogin(channel: "whatsapp"))
        #expect(!admin.canStartQRLogin(channel: "discord"))
        #expect(SetupWizardModel.fullManagementTitle == "Needs Full Management")
        #expect(SetupWizardModel.fullManagementMessage
            == "This device can view but not change this. Open Connection to request Full Management.")
    }

    // MARK: QR login

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func qrLoginRefreshesThenLinks() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = SetupFakeGateway()
        let qr1 = "data:image/png;base64,\(Data([1, 2, 3]).base64EncodedString())"
        let qr2 = "data:image/png;base64,\(Data([4, 5, 6]).base64EncodedString())"
        let script: [JSONValue] = [
            ["connected": false, "message": "Still waiting for the QR scan. Let me know when you’ve scanned it."],
            ["connected": false, "message": "QR refreshed. Scan the latest code in WhatsApp → Linked Devices.", "qrDataUrl": .string(qr2)],
            ["connected": true, "message": "✅ Linked! WhatsApp is ready."],
        ]
        var waits = 0
        let wizard = SetupWizardModel(gatewayId: UUID(), defaults: scratch.defaults, environment: .init(
            request: { method, params in
                gateway.calls.append((method, params))
                switch method {
                case "web.login.start": return ["qrDataUrl": .string(qr1), "message": "Scan this QR in WhatsApp → Linked Devices."]
                case "web.login.wait":
                    defer { waits += 1 }
                    return script[min(waits, script.count - 1)]
                case "channels.status": return SetupFixtures.connectedChannels
                default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: method, details: nil)
                }
            }, hasAdmin: { true }))
        wizard.startQRLogin(channel: "whatsapp")
        let linked = await self.waitFor { if case .connected = wizard.qrLogin(channel: "whatsapp") { true } else { false } }
        #expect(linked, "a still-waiting wait keeps polling (got \(wizard.qrLogin(channel: "whatsapp")))")
        let start = gateway.calls.first { $0.0 == "web.login.start" }?.1
        #expect(start?["channel"] == "whatsapp")
        let waitParams = gateway.calls.filter { $0.0 == "web.login.wait" }.map(\.1)
        #expect(waitParams.first?["currentQrDataUrl"]?.text == qr1)
        #expect(waitParams.last?["currentQrDataUrl"]?.text == qr2, "the refreshed QR is sent back")
        #expect(gateway.calls.contains { $0.0 == "channels.status" }, "channels reload once linked")
    }

    @Test func qrLoginFailuresAndCancel() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let expired = SetupWizardModel(gatewayId: UUID(), defaults: scratch.defaults, environment: .init(
            request: { method, _ in
                method == "web.login.start"
                    ? ["qrDataUrl": .string("data:image/png;base64,AQID"), "message": "Scan"]
                    : ["connected": false, "message": "The login QR expired. Ask me to generate a new one."]
            }, hasAdmin: { true }))
        expired.startQRLogin(channel: "whatsapp")
        let failed = await self.waitFor { if case .failed = expired.qrLogin(channel: "whatsapp") { true } else { false } }
        #expect(failed && expired.qrLogin(channel: "whatsapp") == .failed("The login QR expired. Ask me to generate a new one."))

        let denied = SetupWizardModel(gatewayId: UUID(), defaults: scratch.defaults, environment: .init(
            request: { _, _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: nil) },
            hasAdmin: { true }))
        denied.startQRLogin(channel: "whatsapp")
        let deniedFailed = await self.waitFor { if case .failed = denied.qrLogin(channel: "whatsapp") { true } else { false } }
        #expect(deniedFailed)

        let hanging = SetupWizardModel(gatewayId: UUID(), defaults: scratch.defaults, environment: .init(
            request: { method, _ in
                if method == "web.login.wait" { try await Task.sleep(for: .seconds(30)) }
                return ["qrDataUrl": .string("data:image/png;base64,AQID"), "message": "Scan"]
            }, hasAdmin: { true }))
        hanging.startQRLogin(channel: "whatsapp")
        let showing = await self.waitFor { if case .showing = hanging.qrLogin(channel: "whatsapp") { true } else { false } }
        #expect(showing)
        hanging.cancelQRLogin(channel: "whatsapp")
        #expect(hanging.qrLogin(channel: "whatsapp") == .idle)
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
        let tips = TipsModel(defaults: scratch.defaults)
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
        let relaunched = TipsModel(defaults: scratch.defaults)
        relaunched.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(!relaunched.isPresented, "seen stays seen")
        relaunched.showAgain()
        #expect(!relaunched.hasSeen && !scratch.defaults.bool(forKey: SetupTips.seenKey))
        relaunched.evaluate(connected: true, setupShowingOrPending: false, isDemo: false)
        #expect(relaunched.isPresented, "Show Tips Again")
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

    @Test func stillWaitingMessages() {
        #expect(SetupWizardModel.isStillWaiting("Still waiting for the QR scan. Let me know when you’ve scanned it."))
        #expect(SetupWizardModel.isStillWaiting("  still waiting…"))
        #expect(!SetupWizardModel.isStillWaiting("The login QR expired. Ask me to generate a new one."))
        #expect(!SetupWizardModel.isStillWaiting("No active WhatsApp login in progress."))
        #expect(!SetupWizardModel.isStillWaiting(""))
    }
}
