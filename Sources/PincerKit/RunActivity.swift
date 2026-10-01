import Foundation

// Live Activities for running agent turns (#50): a Lock Screen / Dynamic Island card showing what the
// agent is doing, how long the turn has run, when it waits for approval, and how it ended. Everything
// here is platform-neutral so tests can drive it; ActivityKit lives in the iOS app (`RunActivityHost`).

// MARK: State

/// What the activity shows. Codable because it's the `ActivityAttributes.ContentState`.
public struct RunActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case thinking, replying, tool, compacting, awaitingApproval, completed, failed, stopped

        /// The turn is over.
        public var isFinal: Bool { self == .completed || self == .failed || self == .stopped }
    }

    public var phase: Phase
    /// A short, already localized line like "Running exec" or "Waiting for your approval".
    public var status: String
    /// The running tool's name while `phase` is `.tool`.
    public var toolName: String?
    /// When the turn began; the activity counts up from here on its own.
    public var startedAt: Date
    /// When the turn ended, once it has.
    public var endedAt: Date?

    public init(phase: Phase, status: String, toolName: String? = nil, startedAt: Date, endedAt: Date? = nil) {
        self.phase = phase
        self.status = status
        self.toolName = toolName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// The state of a turn in progress. Mirrors the avatar's priority: approval, tool, reply, compaction, thinking.
    public static func running(_ signals: AvatarSignals, startedAt: Date) -> RunActivityState {
        if signals.awaitingApproval {
            return Self(phase: .awaitingApproval, status: L("Waiting for your approval"), startedAt: startedAt)
        }
        if let tool = signals.runningToolName {
            let name = Self.displayName(ofTool: tool)
            return Self(phase: .tool, status: L("Running \(name)"), toolName: name, startedAt: startedAt)
        }
        if signals.isStreaming { return Self(phase: .replying, status: L("Replying"), startedAt: startedAt) }
        if signals.isCompacting {
            return Self(phase: .compacting, status: L("Tidying up its memory"), startedAt: startedAt)
        }
        return Self(phase: .thinking, status: L("Thinking"), startedAt: startedAt)
    }

    /// The final state of a turn that was `state` and ended with `outcome` at `date`. A run that was
    /// stopped (neither success nor error) reads as stopped.
    public static func finished(_ state: RunActivityState, outcome: AvatarOutcome, at date: Date) -> RunActivityState {
        var final = state
        final.toolName = nil
        final.endedAt = date
        switch outcome {
        case .success:
            final.phase = .completed
            final.status = L("Finished")
        case .error:
            final.phase = .failed
            final.status = L("Something went wrong")
        case .none:
            final.phase = .stopped
            final.status = L("Stopped")
        }
        return final
    }

    /// A tool's name as people read it: an MCP tool is shown without its server prefix.
    static func displayName(ofTool name: String) -> String {
        name.contains("__") ? MCPToolName.split(name).tool : name
    }
}

/// Which chat an activity is about; fixed for the activity's lifetime.
public struct RunActivityIdentity: Codable, Hashable, Sendable {
    public var gatewayId: UUID
    public var sessionKey: String
    public var agentName: String
    public var chatTitle: String
    public var emoji: String?
    /// The `pincer://open` link a tap on the activity follows.
    public var url: URL

    public init(gatewayId: UUID, sessionKey: String, agentName: String, chatTitle: String, emoji: String? = nil, url: URL) {
        self.gatewayId = gatewayId
        self.sessionKey = sessionKey
        self.agentName = agentName
        self.chatTitle = chatTitle
        self.emoji = emoji
        self.url = url
    }
}

// MARK: Host

/// Shows the activities. The iOS app implements it with ActivityKit; nothing else needs to.
@MainActor
public protocol RunActivityHost: AnyObject {
    /// Starts an activity and returns its id, or nil when it can't be shown (Live Activities off,
    /// the app isn't in the foreground, too many already).
    func start(_ identity: RunActivityIdentity, state: RunActivityState) -> String?
    func update(id: String, state: RunActivityState)
    /// Ends the activity showing `state`, and removes it from the Lock Screen `dismissAfter` seconds later.
    func end(id: String, state: RunActivityState, dismissAfter: TimeInterval)
}

// MARK: Coordinator

/// Tracks which turns are running and keeps one activity per turn in step with it. A turn only gets
/// an activity once it has run for `startDelay`, so quick replies never flash one.
@MainActor
public final class RunActivityCoordinator {
    public static let shared = RunActivityCoordinator()

    /// UserDefaults key of the "Live Activities" setting; on unless switched off.
    public static let enabledKey = "pincer.liveActivities"
    /// How long a turn runs before it gets an activity.
    public static let defaultStartDelay: TimeInterval = 3
    /// How long a finished turn's card stays on the Lock Screen.
    public static let finishedDismissDelay: TimeInterval = 8

    /// Who shows the activities; nil (the default, and always on macOS) turns the whole thing off.
    public var host: (any RunActivityHost)? {
        didSet { if self.host == nil { self.tracked.removeAll() } }
    }
    public var startDelay: TimeInterval = RunActivityCoordinator.defaultStartDelay
    private let defaults: UserDefaults

    /// Whether any activity could be shown; cheap, so callers can skip work when it's false.
    public var isActive: Bool { self.host != nil }

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        get { self.defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            self.defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { self.endAll() }
        }
    }

    struct Key: Hashable {
        let gatewayId: UUID
        let sessionKey: String
    }

    struct Tracked {
        var identity: RunActivityIdentity
        var state: RunActivityState
        var activityId: String?
        var startTask: Task<Void, Never>?
        var startFailed = false
    }

    private(set) var tracked: [Key: Tracked] = [:]

    /// Whether a turn in this chat is being tracked, whether or not its activity has started yet.
    func isTracking(gatewayId: UUID, sessionKey: String) -> Bool {
        self.tracked[Key(gatewayId: gatewayId, sessionKey: sessionKey)] != nil
    }

    /// The activity id showing a chat's turn, if one is on screen.
    public func activityId(gatewayId: UUID, sessionKey: String) -> String? {
        self.tracked[Key(gatewayId: gatewayId, sessionKey: sessionKey)]?.activityId
    }

    /// Brings a chat's activity in step with its signals. `identity` is only read when a turn begins.
    func refresh(
        gatewayId: UUID, sessionKey: String, signals: AvatarSignals, startedAt: @autoclosure () -> Date,
        eligible: @autoclosure () -> Bool, identity: @autoclosure () -> RunActivityIdentity, now: Date = Date())
    {
        guard let host = self.host else { return }
        let key = Key(gatewayId: gatewayId, sessionKey: sessionKey)
        guard self.isEnabled, signals.isRunning else {
            self.end(key, signals: signals, now: now)
            return
        }
        if var current = self.tracked[key] {
            let state = RunActivityState.running(signals, startedAt: current.state.startedAt)
            guard state != current.state else { return }
            current.state = state
            self.tracked[key] = current
            if let id = current.activityId { host.update(id: id, state: state) }
            return
        }
        guard eligible() else { return }
        let state = RunActivityState.running(signals, startedAt: startedAt())
        self.tracked[key] = Tracked(identity: identity(), state: state)
        if self.startDelay <= 0 {
            self.startActivity(key)
        } else {
            let delay = self.startDelay
            self.tracked[key]?.startTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.startActivity(key)
            }
        }
    }

    private func startActivity(_ key: Key) {
        guard let host = self.host, var current = self.tracked[key], current.activityId == nil, !current.startFailed else { return }
        current.startTask = nil
        if let id = host.start(current.identity, state: current.state) {
            current.activityId = id
        } else {
            // Starting needs the app in the foreground; a turn that began elsewhere just goes without.
            current.startFailed = true
        }
        self.tracked[key] = current
    }

    /// The turn ended (or can't be shown anymore): finish its activity, if it ever had one.
    private func end(_ key: Key, signals: AvatarSignals, now: Date) {
        guard let host = self.host, let current = self.tracked.removeValue(forKey: key) else { return }
        current.startTask?.cancel()
        guard let id = current.activityId else { return }
        // The last outcome belongs to this turn only if it was recorded after the turn began.
        let outcome: AvatarOutcome = (signals.outcomeAt ?? .distantPast) >= current.state.startedAt ? signals.lastOutcome : .none
        let final = RunActivityState.finished(current.state, outcome: outcome, at: now)
        host.end(id: id, state: final, dismissAfter: outcome == .none ? 0 : Self.finishedDismissDelay)
    }

    /// Ends every activity, e.g. when the setting is turned off.
    public func endAll() {
        guard let host = self.host else { return }
        let all = self.tracked
        self.tracked.removeAll()
        let now = Date()
        for (_, current) in all {
            current.startTask?.cancel()
            guard let id = current.activityId else { continue }
            host.end(id: id, state: RunActivityState.finished(current.state, outcome: .none, at: now), dismissAfter: 0)
        }
    }
}
