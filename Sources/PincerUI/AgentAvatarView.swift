import PincerKit
import SwiftUI

/// An agent's companion creature, acting out what the agent is doing.
///
/// Animation runs only while it's enabled, Reduce Motion is off, the scene is active and the view
/// is on screen; otherwise each state holds a still key pose. Frames come from a schedule that
/// only fires when the pose changes (idle is just blinks and breaths), and nothing in `body`
/// reads the clock: poses come from the timeline's date.
struct AgentAvatarView: View {
    let state: AvatarState
    let style: AvatarStyle
    var size: CGFloat = 32
    var animated = true
    /// Staggers blinks between avatars, e.g. the agent id.
    var seed = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @State private var onscreen = false
    /// When the avatar entered `state`, for one-shot moves (the success hop, the error wobble).
    @State private var since = Date.distantPast

    private var active: Bool { self.animated && !self.reduceMotion && self.scenePhase == .active && self.onscreen }

    var body: some View {
        Group {
            if self.active {
                TimelineView(AvatarSchedule(state: self.state, plush: self.style.renderStyle == .plush,
                                            phase: AvatarMotion.phase(for: self.seed)))
                { context in
                    let pose = AvatarMotion.pose(
                        for: self.state, time: context.date.timeIntervalSinceReferenceDate,
                        elapsed: context.date.timeIntervalSince(self.since), animated: true,
                        phase: AvatarMotion.phase(for: self.seed))
                    // Timeline ticks that land on the same pose skip the redraw.
                    AvatarCanvas(style: self.style, pose: pose, dark: self.colorScheme == .dark)
                        .equatable()
                }
            } else {
                // Still poses crossfade from one state to the next.
                ZStack {
                    AvatarCanvas(style: self.style, pose: AvatarMotion.keyPose(for: self.state), dark: self.colorScheme == .dark)
                        .id(self.state)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.25), value: self.state)
            }
        }
        .frame(width: self.size, height: self.size)
        .background { self.glow }
        .animation(.easeInOut(duration: 0.25), value: AvatarArt.showsGlow(self.state))
        .overlay(alignment: .bottomTrailing) { self.badge }
        .onAppear { self.onscreen = true }
        .onDisappear { self.onscreen = false }
        .onChange(of: self.state, initial: true) { self.since = .now }
    }

    /// Matches `AvatarArt.drawGlow`, the bitmap version.
    @ViewBuilder private var glow: some View {
        if AvatarArt.showsGlow(self.state) {
            let accent = self.theme.accent
            Circle()
                .fill(RadialGradient(stops: [.init(color: accent.opacity(0.2), location: 0.55),
                                             .init(color: accent.opacity(0.02), location: 1)],
                                     center: .center, startRadius: 0, endRadius: self.size / 2))
                .overlay(Circle().strokeBorder(accent.opacity(0.4), lineWidth: max(self.size / 36, 0.75)))
                .transition(.opacity)
        }
    }

    @ViewBuilder private var badge: some View {
        if let symbol = Self.badgeSymbol(for: self.state) {
            let side = max(self.size * 0.42, 9)
            Image(systemName: symbol)
                .font(.system(size: side * 0.58, weight: .bold))
                .foregroundStyle(self.theme.accent)
                .frame(width: side, height: side)
                .background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(self.theme.accent.opacity(0.45), lineWidth: max(side * 0.07, 0.75)))
                .offset(x: side * 0.12, y: side * 0.08)
                .transition(.scale.combined(with: .opacity))
        }
    }

    static func badgeSymbol(for state: AvatarState) -> String? {
        switch state {
        case let .tool(tool): tool.symbolName
        case .awaitingApproval: "hand.raised.fill"
        case .error: "exclamationmark"
        default: nil
        }
    }
}

/// Draws one pose.
private struct AvatarCanvas: View, Equatable {
    let style: AvatarStyle
    let pose: AvatarPose
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                AvatarArt.draw(self.style, pose: self.pose, dark: self.dark, in: cg, rect: CGRect(origin: .zero, size: size))
            }
        }
    }
}

/// Timeline dates at which the pose changes: blink and breath edges when idle, a steady low frame
/// rate otherwise. Nothing while the display is in low-frequency mode.
private struct AvatarSchedule: TimelineSchedule {
    let state: AvatarState
    let plush: Bool
    let phase: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, interval: mode == .lowFrequency ? nil : AvatarMotion.frameInterval(for: self.state, plush: self.plush),
                phase: self.phase, stopped: mode == .lowFrequency)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let interval: TimeInterval?
        let phase: TimeInterval
        let stopped: Bool

        mutating func next() -> Date? {
            guard let date = self.upcoming else { return nil }
            if self.stopped {
                self.upcoming = nil
            } else if let interval {
                self.upcoming = date.addingTimeInterval(interval)
            } else {
                let t = AvatarMotion.nextIdleChange(after: date.timeIntervalSinceReferenceDate, phase: self.phase)
                self.upcoming = Date(timeIntervalSinceReferenceDate: t)
            }
            return date
        }
    }
}

// MARK: - Chat avatar

/// The agent's avatar for a chat: the creature acting out the chat's current run when animated
/// avatars are on, or the classic initial or emoji circle when they're off.
struct ChatAgentAvatar: View {
    let chat: ChatStore
    let agent: AgentSummary
    var size: CGFloat = 28
    /// Tells VoiceOver when the agent starts waiting for approval or hits an error.
    var announces = false

    @AppStorage(AvatarSettings.animatedKey) private var enabled = true
    @AppStorage(AvatarSettings.renderStyleKey) private var renderStyle = AvatarRenderStyle.pixel.rawValue
    @Environment(\.appTheme) private var theme
    @Environment(GatewayStore.self) private var gateway: GatewayStore?

    init(chat: ChatStore, agent: AgentSummary, size: CGFloat = 28, announces: Bool = false) {
        self.chat = chat
        self.agent = agent
        self.size = size
        self.announces = announces
    }

    var body: some View {
        if self.enabled {
            // Reading the signals re-runs this body on every streamed delta; the content below
            // only updates when the signals themselves change.
            ChatAgentAvatarContent(
                signals: self.chat.avatarSignals, agent: self.agent,
                style: AvatarSettings.style(
                    for: self.agent,
                    seed: self.gateway?.avatarSeed(for: self.agent)
                        ?? AvatarStyle.identitySeed(name: self.agent.name, agentId: self.agent.id),
                    creature: self.gateway.map { $0.avatarCreature(for: self.agent.id)?.rawValue ?? "" }
                        ?? UserDefaults.standard.string(forKey: AvatarSettings.creatureKey(for: self.agent.id)) ?? "",
                    renderStyle: self.renderStyle),
                size: self.size, announces: self.announces)
                .equatable()
        } else {
            Avatar(text: String(self.agent.name.prefix(1)).uppercased(), emoji: self.agent.emoji,
                   color: self.theme.color(.agentAvatar), size: self.size)
        }
    }
}

private struct ChatAgentAvatarContent: View, Equatable {
    let signals: AvatarSignals
    let agent: AgentSummary
    let style: AvatarStyle
    let size: CGFloat
    let announces: Bool
    /// The clock the transient success and error poses are judged against, advanced by a task
    /// when one expires rather than read in `body`.
    @State private var clock = Date.distantPast

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signals == rhs.signals && lhs.agent == rhs.agent && lhs.style == rhs.style && lhs.size == rhs.size
            && lhs.announces == rhs.announces
    }

    var body: some View {
        let signals = self.signals
        let state = AvatarStateMachine.state(for: signals, now: self.clock)
        AgentAvatarView(state: state, style: self.style, size: self.size, seed: self.agent.id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityLabel(agentName: self.agent.name))
            .accessibilityHint(self.style.accessibilityName)
            .onChange(of: state) { _, new in
                guard self.announces, new == .awaitingApproval || new == .error else { return }
                AccessibilityNotification.Announcement(new.accessibilityLabel(agentName: self.agent.name)).post()
            }
            .task(id: signals) {
                self.clock = .now
                while let next = AvatarStateMachine.nextTransition(for: signals, now: self.clock) {
                    try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0.01)))
                    if Task.isCancelled { return }
                    self.clock = .now
                }
            }
    }
}

/// The selected chat's agent, animated, beside the title. Nothing when animated avatars are off.
struct ChatHeaderAvatar: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey
    @AppStorage(AvatarSettings.animatedKey) private var enabled = true

    var body: some View {
        if self.enabled, let key = self.windowKey ?? self.gateway.selectedKey {
            let agentId = self.gateway.sessions[key]?.agentId ?? SessionKey.agentId(from: key) ?? "main"
            // The per-chat `.id` (it resets the per-agent creature and pose state) stays inside a
            // stable container. If the toolbar item's root view took the `.id`, macOS would remove
            // and re-add the item on every chat switch and redraw every toolbar button, the
            // sidebar's included (#262). `ToolbarStabilityCheck` guards this.
            ZStack {
                // The chat already exists: the detail view made it for this key.
                ChatAgentAvatar(chat: self.gateway.chat(for: key), agent: self.gateway.agent(agentId), size: 26, announces: true)
                    .id(key)
            }
            .frame(width: 26, height: 26)
        }
    }
}

/// Where the avatar preferences live: this device's defaults, which Gateways keep in sync through
/// `users.prefs` (see `AvatarPreferences`). Animated on or off stays per device.
enum AvatarSettings {
    static let animatedKey = AvatarPreferences.animatedKey
    static let renderStyleKey = AvatarPreferences.renderStyleKey

    /// Per-agent creature override; empty means seeded from the agent.
    static func creatureKey(for agentId: String) -> String { AvatarPreferences.creatureKey(for: agentId) }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: self.animatedKey) as? Bool ?? true }

    /// Seeded from the Gateway's recorded identity seed, so a rename keeps the pet; the creature
    /// override is keyed by the agent id.
    static func style(for agent: AgentSummary, seed: String, creature: String, renderStyle: String) -> AvatarStyle {
        let seeded = AvatarStyle.seeded(from: seed, renderStyle: AvatarRenderStyle(rawValue: renderStyle) ?? .pixel)
        return AvatarCreature(rawValue: creature).map(seeded.with(creature:)) ?? seeded
    }

    /// Kept until `AvatarCharacterRow` passes the Gateway's seed.
    static func style(for agent: AgentSummary, creature: String, renderStyle: String) -> AvatarStyle {
        self.style(for: agent, seed: AvatarStyle.identitySeed(name: agent.name, agentId: agent.id),
                   creature: creature, renderStyle: renderStyle)
    }

    /// The agent's style as currently set in defaults, seeded by the Gateway when given.
    @MainActor static func style(for agent: AgentSummary, in gateway: GatewayStore?, defaults: UserDefaults = .standard) -> AvatarStyle {
        let creature = if let gateway {
            gateway.avatarCreature(for: agent.id)?.rawValue ?? ""
        } else {
            defaults.string(forKey: self.creatureKey(for: agent.id)) ?? ""
        }
        return self.style(for: agent, seed: gateway?.avatarSeed(for: agent) ?? AvatarStyle.identitySeed(name: agent.name, agentId: agent.id),
                          creature: creature,
                          renderStyle: defaults.string(forKey: self.renderStyleKey) ?? "")
    }
}
