import Foundation

// MARK: Tools

/// What kind of tool the agent is running, for the avatar's badge. Mirrors the Tool card's symbols.
public enum AvatarTool: String, Sendable, Hashable, CaseIterable, Codable {
    case question, exec, read, write, search, web, image, agent, memory, message, generic

    /// Guesses the kind from a tool name (`exec`, `web_fetch`, `memory_search`…); first match wins.
    public static func kind(forToolName name: String) -> AvatarTool {
        let lower = name.lowercased()
        if lower == "ask_user" || lower.contains("question") { return .question }
        if lower.contains("exec") || lower.contains("bash") || lower.contains("shell") || lower.contains("process") { return .exec }
        if lower.contains("read") || lower.contains("view") { return .read }
        if lower.contains("write") || lower.contains("edit") || lower.contains("patch") { return .write }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") { return .search }
        if lower.contains("web") || lower.contains("fetch") || lower.contains("browser") { return .web }
        if lower.contains("image") || lower.contains("canvas") { return .image }
        if lower.contains("session") || lower.contains("spawn") || lower.contains("agent") { return .agent }
        if lower.contains("memory") { return .memory }
        if lower.contains("message") || lower.contains("send") { return .message }
        return .generic
    }

    /// SF Symbol shown for this kind of tool.
    public var symbolName: String {
        switch self {
        case .question: "questionmark.bubble"
        case .exec: "terminal"
        case .read: "doc.text"
        case .write: "pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .image: "photo"
        case .agent: "person.2"
        case .memory: "brain.head.profile"
        case .message: "paperplane"
        case .generic: "wrench.and.screwdriver"
        }
    }

    var phrase: String {
        switch self {
        case .question: "Asking you a question"
        case .exec: "Running a command"
        case .read: "Reading"
        case .write: "Editing"
        case .search: "Searching"
        case .web: "Browsing the web"
        case .image: "Working on an image"
        case .agent: "Working with another agent"
        case .memory: "Checking its memory"
        case .message: "Sending a message"
        case .generic: "Using a tool"
        }
    }
}

// MARK: State

/// What the avatar is showing.
public enum AvatarState: Hashable, Sendable {
    case idle, thinking, streaming, tool(AvatarTool), awaitingApproval, success, error, compacting

    /// Short VoiceOver description, e.g. "Thinking".
    public var accessibilityPhrase: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .streaming: "Replying"
        case let .tool(tool): tool.phrase
        case .awaitingApproval: "Waiting for your approval"
        case .success: "Finished"
        case .error: "Something went wrong"
        case .compacting: "Tidying up its memory"
        }
    }

    /// Full VoiceOver label naming the agent, e.g. "Nova is running a tool: exec".
    public func accessibilityLabel(agentName name: String) -> String {
        switch self {
        case .idle: "\(name) is idle"
        case .thinking: "\(name) is thinking"
        case .streaming: "\(name) is replying"
        case let .tool(tool): "\(name) is running a tool: \(tool.rawValue)"
        case .awaitingApproval: "\(name) is waiting for your approval"
        case .success: "\(name) finished"
        case .error: "\(name) ran into a problem"
        case .compacting: "\(name) is tidying up its memory"
        }
    }

    /// Every state once, with one tool, for previews and snapshots.
    public static let gallery: [AvatarState] = [
        .idle, .thinking, .streaming, .tool(.exec), .awaitingApproval, .success, .error, .compacting,
    ]
}

/// How the last run ended.
public enum AvatarOutcome: String, Hashable, Sendable {
    case none, success, error
}

/// Raw inputs the avatar's state is derived from.
public struct AvatarSignals: Hashable, Sendable {
    public var isRunning: Bool
    public var isThinking: Bool
    public var isStreaming: Bool
    public var runningToolName: String?
    public var awaitingApproval: Bool
    public var isCompacting: Bool
    public var lastOutcome: AvatarOutcome
    public var outcomeAt: Date?

    public init(
        isRunning: Bool = false, isThinking: Bool = false, isStreaming: Bool = false,
        runningToolName: String? = nil, awaitingApproval: Bool = false, isCompacting: Bool = false,
        lastOutcome: AvatarOutcome = .none, outcomeAt: Date? = nil)
    {
        self.isRunning = isRunning
        self.isThinking = isThinking
        self.isStreaming = isStreaming
        self.runningToolName = runningToolName
        self.awaitingApproval = awaitingApproval
        self.isCompacting = isCompacting
        self.lastOutcome = lastOutcome
        self.outcomeAt = outcomeAt
    }

    public static let idle = AvatarSignals()
}

/// Picks the avatar's state from signals. Pure: callers pass the clock.
public enum AvatarStateMachine {
    public static let successDuration: TimeInterval = 1.5
    public static let errorDuration: TimeInterval = 3

    /// Approval > error (transient) > tool > streaming > thinking > compacting > success (transient) > idle.
    public static func state(for signals: AvatarSignals, now: Date) -> AvatarState {
        if signals.awaitingApproval { return .awaitingApproval }
        if self.transientActive(.error, signals, now) { return .error }
        if let tool = signals.runningToolName { return .tool(AvatarTool.kind(forToolName: tool)) }
        if signals.isStreaming { return .streaming }
        if signals.isThinking { return .thinking }
        if signals.isCompacting { return .compacting }
        if signals.isRunning { return .thinking }
        if self.transientActive(.success, signals, now) { return .success }
        return .idle
    }

    /// When the current transient (success or error) expires, so the caller can re-derive then; nil if none is showing.
    public static func nextTransition(for signals: AvatarSignals, now: Date) -> Date? {
        guard let at = signals.outcomeAt, let duration = self.duration(signals.lastOutcome) else { return nil }
        let end = at.addingTimeInterval(duration)
        return end > now ? end : nil
    }

    private static func duration(_ outcome: AvatarOutcome) -> TimeInterval? {
        switch outcome {
        case .none: nil
        case .success: self.successDuration
        case .error: self.errorDuration
        }
    }

    private static func transientActive(_ outcome: AvatarOutcome, _ signals: AvatarSignals, _ now: Date) -> Bool {
        guard signals.lastOutcome == outcome, let at = signals.outcomeAt, let duration = self.duration(outcome) else {
            return false
        }
        return now >= at && now < at.addingTimeInterval(duration)
    }
}

// MARK: Style

/// Which companion creature the avatar is.
public enum AvatarCreature: String, Sendable, Hashable, CaseIterable, Codable {
    case blob, owl, rock, sprout
    case cat, bunny, bear, frog, fox, mouse, penguin, chick, pig, ghost, mushroom, cloud, axolotl, hedgehog, octopus
}

/// Something the creature wears.
public enum AvatarAccessory: String, Sendable, Hashable, CaseIterable, Codable {
    /// `leaf` is a little flower clip; `hat` a beanie; `antenna` a nub with a bobble.
    case none, hat, glasses, leaf, bow, antenna

    /// Accessories that suit a creature: nothing that fights its ears, tufts, stem, spikes or cap.
    public static func allowed(for creature: AvatarCreature) -> [AvatarAccessory] {
        switch creature {
        case .blob, .ghost, .cloud, .octopus: [.none, .hat, .glasses, .leaf, .bow, .antenna]
        case .owl: [.none, .glasses, .leaf, .bow]
        case .rock: [.none, .hat, .leaf, .bow, .antenna]
        case .sprout: [.none, .bow]
        case .cat, .bunny, .fox, .chick: [.none, .glasses, .leaf, .bow]
        case .bear, .penguin, .axolotl: [.none, .hat, .glasses, .leaf, .bow]
        case .mouse, .pig: [.none, .hat, .glasses, .leaf]
        case .frog: [.none, .hat, .glasses]
        case .hedgehog: [.none, .glasses, .leaf]
        case .mushroom: [.none, .glasses]
        }
    }
}

/// Soft, warm colour set for the creature's body.
public enum AvatarPalette: String, Sendable, Hashable, CaseIterable, Codable {
    case cream, apricot, moss, stone, peach, lilac, sky, lemon
}

/// How the creature is drawn.
public enum AvatarRenderStyle: String, Sendable, Hashable, CaseIterable, Codable {
    case pixel, plush
}

/// Look of an agent's avatar. Seeded from its identity so every agent gets its own companion.
public struct AvatarStyle: Hashable, Sendable, Codable {
    public var creature: AvatarCreature
    public var accessory: AvatarAccessory
    public var palette: AvatarPalette
    public var renderStyle: AvatarRenderStyle

    /// An accessory that doesn't suit the creature is dropped.
    public init(
        creature: AvatarCreature, accessory: AvatarAccessory = .none, palette: AvatarPalette = .cream,
        renderStyle: AvatarRenderStyle = .pixel)
    {
        self.creature = creature
        self.accessory = AvatarAccessory.allowed(for: creature).contains(accessory) ? accessory : .none
        self.palette = palette
        self.renderStyle = renderStyle
    }

    /// What an agent's companion is seeded from: its identity name (from `agents.list` /
    /// `agent.identity.get`), so two users' "main" agents with different identities differ, or its
    /// id when it has no name.
    public static func identitySeed(name: String?, agentId: String) -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? agentId : name
    }

    /// Same seed, same companion, on every device and launch (FNV-1a, not `hashValue`).
    public static func seeded(from identitySeed: String, renderStyle: AvatarRenderStyle = .pixel) -> AvatarStyle {
        let hash = self.fnv1a(identitySeed)
        func pick<T>(_ all: [T], _ shift: UInt64) -> T { all[Int((hash >> shift) % UInt64(all.count))] }
        let creature = pick(AvatarCreature.allCases, 0)
        return AvatarStyle(
            creature: creature,
            accessory: pick(AvatarAccessory.allowed(for: creature), 16),
            palette: pick(AvatarPalette.allCases, 32),
            renderStyle: renderStyle)
    }

    /// The seeded style with the creature swapped, keeping an accessory only if it suits it.
    public func with(creature: AvatarCreature) -> AvatarStyle {
        var style = self
        style.creature = creature
        if !AvatarAccessory.allowed(for: creature).contains(style.accessory) { style.accessory = .none }
        return style
    }

    /// Spoken name for the accessibility hint, e.g. "Owl avatar".
    public var accessibilityName: String { "\(self.creature.rawValue.capitalized) avatar" }

    /// 64-bit FNV-1a over the string's UTF-8 bytes.
    public static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: Preferences

/// Where avatar choices live: this device's `UserDefaults`, which the views read, mirrored to each
/// Gateway's `users.prefs` (`pincer.avatars`) so every device signed in as you shows the same pets.
public enum AvatarPreferences {
    /// The `users.prefs` key: agent ids to creature names, plus `renderStyleEntry`.
    public static let prefKey = "pincer.avatars"
    /// The entry holding Pixel or Plush. Agent ids can't contain `@`.
    public static let renderStyleEntry = "@style"
    public static let animatedKey = "pincer.animatedAvatars"
    public static let renderStyleKey = "pincer.avatarRenderStyle"
    static let creaturePrefix = "pincer.avatarCreature."
    /// Entries `seed@<agentId>` hold the identity seed an agent had when its Gateway first saw it,
    /// so a rename keeps its pet. Per Gateway: they never reach this device's defaults.
    public static let seedEntryPrefix = "seed@"

    public static func seedEntry(for agentId: String) -> String { self.seedEntryPrefix + agentId }

    /// The agent id a seed entry belongs to, or nil for any other entry.
    public static func agentId(fromSeedEntry entry: String) -> String? {
        entry.hasPrefix(self.seedEntryPrefix) ? String(entry.dropFirst(self.seedEntryPrefix.count)) : nil
    }

    /// Per-agent creature override on this device; missing means seeded from the agent.
    public static func creatureKey(for agentId: String) -> String { self.creaturePrefix + agentId }

    /// The choices already made on this device, as a synced map, for a Gateway's first sync.
    static func local(in defaults: UserDefaults) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(self.creaturePrefix) {
            if key.hasPrefix(self.creaturePrefix + self.seedEntryPrefix) { continue }
            if let name = value as? String, !name.isEmpty { map[String(key.dropFirst(self.creaturePrefix.count))] = name }
        }
        if let style = defaults.string(forKey: self.renderStyleKey), !style.isEmpty { map[self.renderStyleEntry] = style }
        return map
    }

    /// Mirrors a synced map into device defaults. Render style is device-wide; GatewayStore keeps
    /// creature choices in its per-profile map and never writes them over the legacy global keys.
    /// Callers without Gateway context retain the old creature mirror behavior.
    static func apply(
        _ map: [String: String],
        previous: [String: String],
        to defaults: UserDefaults,
        gatewayId: UUID? = nil)
    {
        for entry in Set(map.keys).union(previous.keys) where map[entry] != previous[entry] {
            if entry.hasPrefix(self.seedEntryPrefix) { continue }
            guard entry == self.renderStyleEntry || gatewayId == nil else { continue }
            let key = entry == self.renderStyleEntry ? self.renderStyleKey : self.creatureKey(for: entry)
            if let value = map[entry] {
                if defaults.string(forKey: key) != value { defaults.set(value, forKey: key) }
            } else if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
