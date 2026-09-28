import Foundation
import Observation

// MARK: Steps and status

/// The first-run setup wizard's steps, in order.
public enum SetupStep: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case health
    case channels
    case agent
    case skills
    case testMessage

    public var id: String { self.rawValue }

    public var title: String {
        switch self {
        case .health: "Gateway Health"
        case .channels: "Channels"
        case .agent: "Agent & Model"
        case .skills: "Skills"
        case .testMessage: "Test Message"
        }
    }

    public var symbol: String {
        switch self {
        case .health: "stethoscope"
        case .channels: "bubble.left.and.bubble.right"
        case .agent: "person.crop.circle"
        case .skills: "wrench.and.screwdriver"
        case .testMessage: "paperplane"
        }
    }

    /// The step has actions that need `operator.admin` (QR login, `config.patch`).
    public var hasAdminActions: Bool { self == .channels || self == .agent }
}

/// What a step shows next to its title: exactly one of four.
public enum SetupStepStatus: Hashable, Sendable {
    /// Not checked yet: still loading, can't be checked on this Gateway, or not done (the test message).
    case notChecked(String?)
    case done(String)
    case needsAttention(String)
    case skipped

    public var label: String {
        switch self {
        case .notChecked: "Not Checked"
        case .done: "Done"
        case .needsAttention: "Needs Attention"
        case .skipped: "Skipped"
        }
    }

    public var detail: String? {
        switch self {
        case let .notChecked(text): text
        case let .done(text), let .needsAttention(text): text
        case .skipped: nil
        }
    }

    public var symbol: String {
        switch self {
        case .notChecked: "circle"
        case .done: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .skipped: "arrow.uturn.forward.circle"
        }
    }

    public var isDone: Bool { if case .done = self { true } else { false } }
    public var isSkipped: Bool { self == .skipped }
    /// Done or skipped: nothing left for the user here.
    public var isSettled: Bool { self.isDone || self.isSkipped }
    public var needsAttention: Bool { if case .needsAttention = self { true } else { false } }
}

// MARK: Gateway results

/// One entry of `skills.status` (operator.read) `skills[]`.
public struct SetupSkill: Identifiable, Hashable, Sendable {
    public let name: String
    public let skillKey: String
    public let emoji: String?
    public let eligible: Bool
    public let disabled: Bool
    public let blocked: Bool
    public let platformIncompatible: Bool
    /// `missing.bins`, `missing.anyBins`, `missing.env`, `missing.config`, flattened for display.
    public let missing: [String]
    /// `install[].label`: ways the Gateway can install what's missing (`skills.install`, admin).
    public let installOptions: [String]

    public var id: String { self.skillKey }

    public init?(_ json: JSONValue) {
        guard let name = json["name"]?.text else { return nil }
        self.name = name
        self.skillKey = json["skillKey"]?.text ?? name
        self.emoji = json["emoji"]?.text
        self.eligible = json["eligible"]?.bool ?? true
        self.disabled = json["disabled"]?.bool == true
        self.blocked = json["blockedByAllowlist"]?.bool == true || json["blockedByAgentFilter"]?.bool == true
        self.platformIncompatible = json["platformIncompatible"]?.bool == true
        let missing = json["missing"]
        var parts: [String] = []
        parts += (missing?["bins"]?.array ?? []).compactMap(\.text)
        let anyBins = (missing?["anyBins"]?.array ?? []).compactMap(\.text)
        if !anyBins.isEmpty { parts.append(anyBins.joined(separator: " or ")) }
        parts += (missing?["env"]?.array ?? []).compactMap(\.text)
        parts += (missing?["config"]?.array ?? []).compactMap(\.text)
        self.missing = parts
        self.installOptions = (json["install"]?.array ?? []).compactMap { $0["label"]?.text }
    }

    /// Wanted but unusable: not eligible, and not because it's off, blocked or for another OS.
    public var isMissingRequirements: Bool {
        !self.eligible && !self.disabled && !self.blocked && !self.platformIncompatible
    }
}

public struct SetupSkillsReport: Hashable, Sendable {
    public let skills: [SetupSkill]

    public init(skills: [SetupSkill]) { self.skills = skills }

    public init?(_ json: JSONValue) {
        guard let skills = json["skills"]?.array else { return nil }
        self.skills = skills.compactMap(SetupSkill.init)
    }

    public var missing: [SetupSkill] { self.skills.filter(\.isMissingRequirements) }
    public var ready: [SetupSkill] { self.skills.filter { $0.eligible && !$0.disabled } }
}

// MARK: Rules

/// How each step's status follows from what the Gateway reports. Pure, for tests.
public enum SetupRules {
    /// Channels whose plugin implements QR login (`loginWithQrStart`) upstream.
    public static var qrLoginChannels: Set<String> { ChannelRules.qrLoginChannels }

    public static func supportsQRLogin(_ channelId: String) -> Bool { ChannelRules.supportsQRLogin(channelId) }

    /// Healthy: done; degraded or down: attention (the first active issue); restarting: not checked.
    /// With `channelsSeparate`, channel issues are left to the Channels step: a Gateway degraded only by
    /// channels counts as healthy here.
    public static func health(level: GatewayHealthLevel, activeIssues: [GatewayHealthIssue], loaded: Bool,
                              channelsSeparate: Bool = false) -> SetupStepStatus {
        if channelsSeparate, level == .degraded, !activeIssues.isEmpty, activeIssues.allSatisfy({ $0.kind == .channel }) {
            return loaded ? .done("The Gateway is healthy. Channel problems are covered in Channels.") : .notChecked(nil)
        }
        let activeIssues = channelsSeparate ? activeIssues.filter { $0.kind != .channel } : activeIssues
        switch level {
        case .healthy:
            return loaded ? .done("The Gateway is healthy.") : .notChecked(nil)
        case .degraded:
            guard let first = activeIssues.first else { return .needsAttention("The Gateway's health check isn't available.") }
            let count = activeIssues.count
            return .needsAttention(count == 1 ? first.title : "\(first.title) and \(count - 1) more")
        case .down:
            return .needsAttention("The Gateway isn't connected.")
        case .restarting:
            return .notChecked("The Gateway is restarting.")
        }
    }

    /// Done when some channel is connected (or running) and none has a problem or status issue.
    public static func channels(_ snapshot: SetupChannelsSnapshot?, failure: String? = nil) -> SetupStepStatus {
        guard let snapshot else { return .notChecked(failure) }
        let active = snapshot.channels.filter { $0.effectiveAccounts.contains(where: \.isActive) }
        let problems = active.filter { !$0.problemAccounts.isEmpty }
        if let channel = problems.first {
            guard problems.count == 1 else { return .needsAttention("\(problems.count) channels need attention.") }
            return .needsAttention("\(channel.label): \(channel.lastError ?? "not connected")")
        }
        if let issue = snapshot.issues.first {
            let label = snapshot.channels.first { $0.id == issue.channel }?.label ?? ApprovalRecord.humanized(issue.channel)
            return .needsAttention("\(label): \(issue.message)")
        }
        guard !active.isEmpty else { return .needsAttention("No channels are set up yet.") }
        let names = active.map(\.label)
        return .done(names.count == 1 ? "\(names[0]) is connected." : "\(names.count) channels are connected.")
    }

    /// Done when there's a default agent and a default model.
    public static func agent(agents: [AgentSummary], defaultAgentId: String, defaultModelRef: String?, loaded: Bool) -> SetupStepStatus {
        guard loaded else { return .notChecked(nil) }
        guard !agents.isEmpty else { return .needsAttention("No agents are set up.") }
        guard let model = defaultModelRef else { return .needsAttention("No default model is set.") }
        let agent = agents.first { $0.id == defaultAgentId }?.name ?? defaultAgentId
        return .done("\(agent) · \(ModelRef.shortName(model))")
    }

    /// Done when no wanted skill is missing requirements.
    public static func skills(_ report: SetupSkillsReport?, failure: String? = nil) -> SetupStepStatus {
        guard let report else { return .notChecked(failure) }
        let missing = report.missing
        guard let first = missing.first else {
            let count = report.ready.count
            return .done(count == 1 ? "1 skill is ready." : "\(count) skills are ready.")
        }
        guard missing.count == 1 else { return .needsAttention("\(missing.count) skills are missing requirements.") }
        let needs = first.missing.isEmpty ? "" : " (needs \(first.missing.joined(separator: ", ")))"
        return .needsAttention("\(first.name) is missing requirements\(needs).")
    }

    /// Done once a send was accepted (the reply isn't awaited).
    public static func testMessage(sent: Bool) -> SetupStepStatus {
        sent ? .done("A test message was sent.") : .notChecked("Say hello to your agent.")
    }

    /// A step the user skipped shows Skipped unless it has become done since.
    public static func resolved(_ status: SetupStepStatus, skipped: Bool) -> SetupStepStatus {
        skipped && !status.isDone ? .skipped : status
    }
}

// MARK: Progress

/// Per-gateway wizard progress, persisted as JSON under `SetupProgress.key(for:)`.
public struct SetupProgress: Codable, Hashable, Sendable {
    /// The wizard was offered (shown once after the first successful connection; "Not Now" keeps this).
    public var offered = false
    /// Finished, or every step is done or skipped.
    public var completed = false
    public var skipped: Set<SetupStep> = []
    public var testMessageSent = false

    public init(offered: Bool = false, completed: Bool = false, skipped: Set<SetupStep> = [],
                testMessageSent: Bool = false) {
        self.offered = offered
        self.completed = completed
        self.skipped = skipped
        self.testMessageSent = testMessageSent
    }

    public static func key(for gatewayId: UUID) -> String { "pincer.setup.v1.\(gatewayId.uuidString)" }

    public static func load(gatewayId: UUID, defaults: UserDefaults) -> SetupProgress? {
        guard let data = defaults.data(forKey: self.key(for: gatewayId)) else { return nil }
        return try? JSONDecoder().decode(SetupProgress.self, from: data)
    }

    public func save(gatewayId: UUID, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(for: gatewayId))
    }

    /// Whether to offer the wizard now that the gateway connected. Gateways connected before the
    /// wizard existed (`connectedBefore`) aren't offered it; the demo (never persisted) always is, but only
    /// right after "Try the Demo" (see `SetupWizardModel.autoOffers`).
    public static func shouldOffer(_ progress: SetupProgress?, connectedBefore: Bool, isDemo: Bool) -> Bool {
        if let progress { return !progress.offered && !progress.completed }
        return isDemo || !connectedBefore
    }
}

// MARK: Tips

/// The one-time tips card (app-wide, not per gateway), backed by `seenKey` in UserDefaults.
public enum SetupTips {
    public struct Tip: Identifiable, Hashable, Sendable {
        public let id: String
        public let text: String
        public let symbol: String
        /// Mentions a keyboard shortcut (on iOS it gets "(iPad keyboard)").
        public let usesKeyboard: Bool
    }

    public static let seenKey = "pincer.tips.seen.v1"

    public static let all: [Tip] = [
        Tip(id: "slash", text: "Type / in the composer for slash commands.", symbol: "slash.circle", usesKeyboard: false),
        Tip(id: "thinking", text: "Ask for deeper reasoning with /think; expand a thinking section to read it.",
            symbol: "brain.head.profile", usesKeyboard: false),
        Tip(id: "approvals", text: "Approvals for commands and tools appear in the chat and as notifications. Allow once or always.",
            symbol: "checkmark.shield", usesKeyboard: false),
        Tip(id: "palette", text: "Press ⌘K to jump to any chat, agent, model, or setting.", symbol: "command", usesKeyboard: true),
        Tip(id: "find", text: "Press ⌘F to find in the current chat.", symbol: "text.magnifyingglass", usesKeyboard: true),
        Tip(id: "search", text: "Search all messages from ⌘K or the sidebar search field.", symbol: "magnifyingglass",
            usesKeyboard: false),
    ]

    /// The tips as shown on this platform. iPad marks keyboard tips "(iPad keyboard)"; iPhone leaves them out.
    public static func tips(iOS: Bool, iPhone: Bool = false) -> [(tip: Tip, text: String)] {
        if iOS, iPhone {
            return self.all.filter { !$0.usesKeyboard }.map {
                ($0, $0.id == "search" ? "Search all messages from the sidebar search field." : $0.text)
            }
        }
        return self.all.map { ($0, iOS && $0.usesKeyboard ? "\($0.text.dropLast()) (iPad keyboard)." : $0.text) }
    }

    /// Show once the gateway connected and setup isn't showing or about to be offered; the demo
    /// shows them once per launch even after they were seen.
    public static func shouldShow(seen: Bool, connected: Bool, setupShowingOrPending: Bool, isDemo: Bool,
                                  shownThisLaunch: Bool) -> Bool {
        guard connected, !setupShowingOrPending, !shownThisLaunch else { return false }
        return !seen || isDemo
    }
}

/// Whether the tips card is up. One for the app.
@MainActor
@Observable
public final class TipsModel {
    public static let shared = TipsModel(defaults: .standard)

    public private(set) var isPresented = false
    public private(set) var hasSeen: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var shownThisLaunch = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.hasSeen = defaults.bool(forKey: SetupTips.seenKey)
    }

    /// Call when the main window appears, a gateway connects, or its setup sheet closes.
    public func evaluate(connected: Bool, setupShowingOrPending: Bool, isDemo: Bool) {
        guard !self.isPresented else {
            if setupShowingOrPending { self.isPresented = false }
            return
        }
        guard SetupTips.shouldShow(seen: self.hasSeen, connected: connected, setupShowingOrPending: setupShowingOrPending,
                                   isDemo: isDemo, shownThisLaunch: self.shownThisLaunch) else { return }
        self.shownThisLaunch = true
        self.isPresented = true
    }

    /// "Got It".
    public func dismiss() {
        self.isPresented = false
        self.hasSeen = true
        self.defaults.set(true, forKey: SetupTips.seenKey)
    }

    /// "Show Tips Again" in Settings: forgets they were seen and shows them on the next evaluate.
    public func showAgain() {
        self.defaults.removeObject(forKey: SetupTips.seenKey)
        self.hasSeen = false
        self.shownThisLaunch = false
    }
}

// MARK: Model

/// The setup wizard for one gateway: step statuses, persisted progress, and the checks it runs
/// (`channels.status`, `skills.status`, QR login). Health and agent status come from the store's
/// existing models through `Environment`.
@MainActor
@Observable
public final class SetupWizardModel {
    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    /// What the wizard reads from the rest of the app. Closures, so checks can fake them.
    public struct Environment {
        public var request: Request
        public var hasAdmin: @MainActor () -> Bool
        /// `hello.methods` (nil or empty when unknown).
        public var methods: @MainActor () -> Set<String>?
        public var healthStatus: @MainActor () -> SetupStepStatus
        public var agentStatus: @MainActor () -> SetupStepStatus
        /// `health.channels`, for when `channels.status` isn't available.
        public var healthChannels: @MainActor () -> GatewayHealthSummary?
        /// Refreshes what the store keeps (health, agents); run alongside `load()`'s own checks.
        public var refresh: @MainActor () async -> Void

        public init(request: @escaping Request,
                    hasAdmin: @escaping @MainActor () -> Bool = { false },
                    methods: @escaping @MainActor () -> Set<String>? = { nil },
                    healthStatus: @escaping @MainActor () -> SetupStepStatus = { .notChecked(nil) },
                    agentStatus: @escaping @MainActor () -> SetupStepStatus = { .notChecked(nil) },
                    healthChannels: @escaping @MainActor () -> GatewayHealthSummary? = { nil },
                    refresh: @escaping @MainActor () async -> Void = {})
        {
            self.refresh = refresh
            self.request = request
            self.hasAdmin = hasAdmin
            self.methods = methods
            self.healthStatus = healthStatus
            self.agentStatus = agentStatus
            self.healthChannels = healthChannels
        }
    }

    /// QR login for one channel account (`web.login.start`, then `web.login.wait`).
    public typealias QRLoginState = ChannelQRLoginState

    public static let testMessageText = "hello"

    public let gatewayId: UUID
    public let isDemo: Bool
    public private(set) var progress: SetupProgress
    /// Shown as a sheet over the main window.
    public var isPresented = false
    /// The offer page ("Set Up <Gateway>", Start Setup / Not Now) instead of the steps.
    public var showsIntro = false
    public var currentStep: SetupStep = .health
    public private(set) var channels: SetupChannelsSnapshot?
    public private(set) var channelsFailure: String?
    public private(set) var skills: SetupSkillsReport?
    public private(set) var skillsFailure: String?
    public private(set) var loadState = OperationState.idle
    /// QR logins, keyed by `"<channel>/<accountId>"` (accountId `default` when omitted).
    public let qr: ChannelQRLoginController
    public var qrLogins: [String: QRLoginState] { self.qr.logins }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connectedBefore: Bool
    @ObservationIgnored private let environment: Environment

    /// `connectedBefore`: this gateway connected before the wizard existed, so it isn't offered.
    /// The demo's progress lives in memory only, so every "Try the Demo" offers it again.
    public init(gatewayId: UUID, isDemo: Bool = false, defaults: UserDefaults, connectedBefore: Bool = false,
                environment: Environment)
    {
        self.gatewayId = gatewayId
        self.isDemo = isDemo
        self.defaults = defaults
        self.connectedBefore = connectedBefore
        self.environment = environment
        self.qr = ChannelQRLoginController(request: environment.request)
        let saved = isDemo ? nil : SetupProgress.load(gatewayId: gatewayId, defaults: defaults)
        self.progress = saved ?? SetupProgress()
        self.hasSavedProgress = saved != nil
        self.qr.onLinked = { [weak self] _ in await self?.loadChannels() }
    }

    @ObservationIgnored private var hasSavedProgress: Bool

    // MARK: Status

    public var hasAdmin: Bool { self.environment.hasAdmin() }

    public func status(of step: SetupStep) -> SetupStepStatus {
        SetupRules.resolved(self.evaluated(step, progress: self.progress), skipped: self.progress.skipped.contains(step))
    }

    /// What the Gateway reports for `step`, ignoring whether it was skipped.
    public func evaluated(_ step: SetupStep) -> SetupStepStatus { self.evaluated(step, progress: self.progress) }

    private func evaluated(_ step: SetupStep, progress: SetupProgress) -> SetupStepStatus {
        switch step {
        case .health: self.environment.healthStatus()
        case .channels: SetupRules.channels(self.channelsSnapshot, failure: self.channelsFailure)
        case .agent: self.environment.agentStatus()
        case .skills: SetupRules.skills(self.skills, failure: self.skillsFailure)
        case .testMessage: SetupRules.testMessage(sent: progress.testMessageSent)
        }
    }

    /// `channels.status`, else the channels in the `health` payload.
    public var channelsSnapshot: SetupChannelsSnapshot? {
        self.channels ?? self.environment.healthChannels().map(SetupChannelsSnapshot.init(health:))
    }

    /// Steps done or skipped, for "3 of 5".
    public var settledCount: Int { SetupStep.allCases.count { self.status(of: $0).isSettled } }

    public var attentionCount: Int { SetupStep.allCases.count { self.status(of: $0).needsAttention } }

    // MARK: Offering and navigation

    /// Showing, or going to be offered on this connection: tips wait for it.
    public var isShowingOrPending: Bool {
        self.isPresented || self.wouldOffer
    }

    /// Whether a connection offers the wizard on its own. The store turns this off for the demo, which
    /// is offered only right after "Try the Demo" (`requestOffer()`); it's always resumable.
    public var autoOffers = true

    private var wouldOffer: Bool {
        self.autoOffers && SetupProgress.shouldOffer(self.hasSavedProgress || self.progress.offered ? self.progress : nil,
                                                     connectedBefore: self.connectedBefore, isDemo: self.isDemo)
    }

    /// "Try the Demo": offer on this connection (now, if already connected), then stop auto-offering.
    public func requestOffer(connected: Bool) {
        self.autoOffers = true
        if self.isDemo { self.progress.offered = false }
        if connected { self.connected() }
    }

    /// Withdraws a pending demo offer, e.g. when another gateway is selected before it connects.
    public func withdrawOffer() {
        if self.isDemo { self.autoOffers = false }
    }

    /// The step has admin-only actions this connection can't use: they show a lock badge.
    public func needsFullManagement(_ step: SetupStep) -> Bool { step.hasAdminActions && !self.hasAdmin }

    public nonisolated static let fullManagementTitle = "Needs Full Management"
    public nonisolated static let fullManagementMessage =
        "This device can view but not change this. Open Connection to request Full Management."

    /// Called once per successful connection: offers the wizard the first time.
    public func connected() {
        guard !self.isPresented, self.wouldOffer else { return }
        if self.isDemo { self.autoOffers = false }
        self.update { $0.offered = true }
        self.showsIntro = true
        self.isPresented = true
        Task { await self.load() }
    }

    /// "Start Setup" on the offer page.
    public func startSetup() {
        self.showsIntro = false
        self.currentStep = self.resumeStep
    }

    /// "Not Now": closes; still offered from the gateway menu and ⌘K, not popped up again.
    public func notNow() {
        self.close()
    }

    /// "Set Up Gateway…": the steps, at `step` or the first not done.
    public func present(at step: SetupStep? = nil) {
        self.update { $0.offered = true }
        self.showsIntro = false
        self.currentStep = step ?? self.resumeStep
        self.isPresented = true
        Task { await self.load() }
    }

    /// The first step neither done nor skipped, else the first not done, else the first.
    public var resumeStep: SetupStep {
        let statuses = SetupStep.allCases.map { ($0, self.status(of: $0)) }
        return statuses.first { !$0.1.isSettled }?.0 ?? statuses.first { !$0.1.isDone }?.0 ?? .health
    }

    public var nextStep: SetupStep? {
        let all = SetupStep.allCases
        guard let index = all.firstIndex(of: self.currentStep), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    public var previousStep: SetupStep? {
        let all = SetupStep.allCases
        guard let index = all.firstIndex(of: self.currentStep), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Continue: to the next step; Finish after the last.
    public func advance() {
        if let next = self.nextStep { self.currentStep = next } else { self.finish() }
    }

    public func goBack() {
        if let previous = self.previousStep { self.currentStep = previous }
    }

    /// Skip: marks the current step skipped and moves on.
    public func skipCurrent() {
        self.skip(self.currentStep)
        self.advance()
    }

    public func skip(_ step: SetupStep) {
        self.update { $0.skipped.insert(step) }
    }

    public func unskip(_ step: SetupStep) {
        self.update { $0.skipped.remove(step) }
    }

    /// Finish: remembered, so it isn't offered again.
    public func finish() {
        self.update { $0.completed = true }
        self.close()
    }

    /// Closes, keeping progress to resume later.
    public func close() {
        self.isPresented = false
        self.showsIntro = false
        self.cancelQRLogins()
    }

    public func markTestMessageSent() {
        self.update { $0.testMessageSent = true }
    }

    /// Forgets this gateway's progress, so the wizard is offered again.
    public func reset() {
        self.progress = SetupProgress()
        self.defaults.removeObject(forKey: SetupProgress.key(for: self.gatewayId))
        self.hasSavedProgress = false
    }

    private func update(_ change: (inout SetupProgress) -> Void) {
        var next = self.progress
        change(&next)
        // Every step done or skipped completes setup.
        if !next.completed, SetupStep.allCases.allSatisfy({ next.skipped.contains($0) || self.evaluated($0, progress: next).isDone }) {
            next.completed = true
        }
        guard next != self.progress else { return }
        self.progress = next
        guard !self.isDemo else { return }
        next.save(gatewayId: self.gatewayId, defaults: self.defaults)
        self.hasSavedProgress = true
    }

    // MARK: Loading

    private func isAdvertised(_ method: String) -> Bool {
        guard let methods = self.environment.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    /// Runs the channel and skill checks (health and agents are kept current by the store).
    public func load() async {
        guard !self.loadState.isRunning else { return }
        self.loadState = .running
        async let channels: Void = self.loadChannels()
        async let skills: Void = self.loadSkills()
        let refresh = self.environment.refresh
        async let store: Void = refresh()
        _ = await (channels, skills, store)
        self.loadState = .idle
    }

    private func loadChannels() async {
        guard self.isAdvertised("channels.status") else {
            self.channels = nil
            self.channelsFailure = self.environment.healthChannels() == nil ? "This Gateway doesn't report channel status." : nil
            return
        }
        do {
            let result = try await self.environment.request("channels.status", ["probe": false])
            self.channels = SetupChannelsSnapshot(result)
            self.channelsFailure = self.channels == nil ? "The Gateway sent an unexpected channel status." : nil
        } catch {
            self.channels = nil
            self.channelsFailure = self.environment.healthChannels() == nil ? Self.message(error) : nil
        }
    }

    private func loadSkills() async {
        guard self.isAdvertised("skills.status") else {
            self.skills = nil
            self.skillsFailure = "This Gateway doesn't report skill status."
            return
        }
        do {
            let result = try await self.environment.request("skills.status", [:])
            self.skills = SetupSkillsReport(result)
            self.skillsFailure = self.skills == nil ? "The Gateway sent an unexpected skill status." : nil
        } catch {
            self.skills = nil
            self.skillsFailure = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        if case let GatewayError.rpc(_, message, _) = error { return message }
        return error.localizedDescription
    }

    // MARK: QR login

    public static func qrKey(channel: String, accountId: String?) -> String {
        ChannelQRLoginController.key(channel: channel, accountId: accountId)
    }

    public func qrLogin(channel: String, accountId: String? = nil) -> QRLoginState {
        self.qr.state(channel: channel, accountId: accountId)
    }

    /// QR login needs Full Management and a channel whose plugin supports it.
    public func canStartQRLogin(channel: String) -> Bool {
        self.hasAdmin && SetupRules.supportsQRLogin(channel)
    }

    /// `web.login.start` then `web.login.wait` (see `ChannelQRLoginController`).
    public func startQRLogin(channel: String, accountId: String? = nil, force: Bool = false) {
        self.qr.start(channel: channel, accountId: accountId, force: force)
    }

    public func cancelQRLogin(channel: String, accountId: String? = nil) {
        self.qr.cancel(channel: channel, accountId: accountId)
    }

    private func cancelQRLogins() {
        self.qr.cancelAll()
    }

    public nonisolated static let qrStartTimeoutMs = ChannelQRLoginController.startTimeoutMs
    public nonisolated static let qrWaitTimeoutMs = ChannelQRLoginController.waitTimeoutMs
    public nonisolated static let qrMaxRounds = ChannelQRLoginController.maxRounds

    public nonisolated static func isStillWaiting(_ message: String) -> Bool {
        ChannelQRLoginController.isStillWaiting(message)
    }

    public nonisolated static func isAlreadyLinked(_ message: String) -> Bool {
        ChannelQRLoginController.isAlreadyLinked(message)
    }
}
