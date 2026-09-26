import Foundation
import Observation

// MARK: Shortcut

/// A global keyboard shortcut: a virtual key code (`kVK_*`) plus modifiers. Kept free of Carbon and
/// AppKit so it can be stored, shown and validated anywhere; the macOS app registers it with Carbon.
public struct HotKeyShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let control = Self(rawValue: 1 << 2)
        public static let shift = Self(rawValue: 1 << 3)

        /// Carbon's `cmdKey`, `shiftKey`, `optionKey` and `controlKey`.
        static let carbon: [(Self, UInt32)] = [(.command, 0x100), (.shift, 0x200), (.option, 0x800), (.control, 0x1000)]
        /// `NSEvent.ModifierFlags` raw values.
        static let event: [(Self, UInt)] = [(.shift, 1 << 17), (.control, 1 << 18), (.option, 1 << 19), (.command, 1 << 20)]
        /// Storage names, in display order.
        static let names: [(Self, String, String)] = [
            (.control, "control", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.command, "command", "⌘"),
        ]

        public init(carbonModifiers: UInt32) {
            self = Self.carbon.reduce(into: []) { result, pair in
                if carbonModifiers & pair.1 != 0 { result.insert(pair.0) }
            }
        }

        /// From `NSEvent.modifierFlags.rawValue`; other flags (caps lock, fn…) are ignored.
        public init(eventModifierFlags: UInt) {
            self = Self.event.reduce(into: []) { result, pair in
                if eventModifierFlags & pair.1 != 0 { result.insert(pair.0) }
            }
        }

        public var carbonValue: UInt32 {
            Self.carbon.reduce(0) { self.contains($1.0) ? $0 | $1.1 : $0 }
        }

        /// ⌃⌥⇧⌘, in Apple's order.
        public var symbols: String {
            Self.names.filter { self.contains($0.0) }.map(\.2).joined()
        }
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Returns nil for a modifier key on its own (⌘, ⇧, fn…), which can't be a hotkey.
    public init?(keyCode: UInt32, carbonModifiers: UInt32) {
        guard !Self.modifierKeyCodes.contains(keyCode) else { return nil }
        self.init(keyCode: keyCode, modifiers: Modifiers(carbonModifiers: carbonModifiers))
    }

    /// From an `NSEvent`'s `keyCode` and `modifierFlags.rawValue`.
    public init?(keyCode: UInt16, eventModifierFlags: UInt) {
        guard !Self.modifierKeyCodes.contains(UInt32(keyCode)) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: Modifiers(eventModifierFlags: eventModifierFlags))
    }

    /// ⌃⇧Space: types nothing and has no system binding (⌃Space, ⌃⌥Space, ⌘Space… do).
    public static let `default` = HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.control, .shift])

    public var carbonModifiers: UInt32 { self.modifiers.carbonValue }

    public var keyName: String { Self.keyName(for: self.keyCode) }

    /// For example `⌃⇧Space` or `⌃⌥⌘N`.
    public var displayString: String { self.modifiers.symbols + self.keyName }

    public var isFunctionKey: Bool { Self.functionKeys[self.keyCode] != nil }

    // MARK: Storage

    /// Compact stored form, e.g. `49:control,shift`.
    public var storageValue: String {
        let names = Modifiers.names.filter { self.modifiers.contains($0.0) }.map(\.1)
        return "\(self.keyCode):\(names.joined(separator: ","))"
    }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let keyCode = UInt32(parts[0]), keyCode < 0x80,
              !Self.modifierKeyCodes.contains(keyCode) else { return nil }
        var modifiers: Modifiers = []
        for name in parts[1].split(separator: ",") {
            guard let modifier = Modifiers.names.first(where: { $0.1 == name })?.0 else { return nil }
            modifiers.insert(modifier)
        }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: Validation

    /// Combos macOS already uses (Spotlight, input sources, app switching, Quit/Close/Hide/Minimize).
    public static let reserved: Set<HotKeyShortcut> = [
        HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.command]),
        HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.control]),
        HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.control, .option]),
        HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.option, .command]),
        HotKeyShortcut(keyCode: KeyCode.space, modifiers: [.control, .command]),
        HotKeyShortcut(keyCode: KeyCode.tab, modifiers: [.command]),
        HotKeyShortcut(keyCode: 12, modifiers: [.command]), // Q
        HotKeyShortcut(keyCode: 13, modifiers: [.command]), // W
        HotKeyShortcut(keyCode: 4, modifiers: [.command]), // H
        HotKeyShortcut(keyCode: 46, modifiers: [.command]), // M
    ]

    /// Why this combo can't be a global shortcut, or nil when it can.
    public var validationError: String? {
        if Self.modifierKeyCodes.contains(self.keyCode) { return "Press a key, not just modifiers." }
        if self.isFunctionKey { return nil }
        if self.keyCode == KeyCode.escape, self.modifiers.isEmpty { return "Esc can’t be a shortcut on its own." }
        if self.modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "Use at least one of ⌘, ⌃ or ⌥."
        }
        if Self.reserved.contains(self) { return "\(self.displayString) is used by macOS. Choose another shortcut." }
        return nil
    }

    // MARK: Key names

    public enum KeyCode {
        public static let `return`: UInt32 = 36
        public static let tab: UInt32 = 48
        public static let space: UInt32 = 49
        public static let delete: UInt32 = 51
        public static let escape: UInt32 = 53
        public static let forwardDelete: UInt32 = 117
        public static let keypadEnter: UInt32 = 76
    }

    /// Command, shift, caps lock, option, control (left and right) and fn.
    static let modifierKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    static let functionKeys: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// US-ANSI names for virtual key codes.
    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "⌧", 75: "Keypad /", 76: "⌤", 78: "Keypad -",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func keyName(for keyCode: UInt32) -> String {
        if let number = self.functionKeys[keyCode] { return "F\(number)" }
        return self.keyNames[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: Settings

/// The Quick Capture shortcut and last target, in the app's own defaults (the extensions don't
/// need them). Turning the shortcut off keeps the recorded combo, so turning it on restores it.
public struct QuickCaptureSettings {
    public static let enabledKey = "pincer.quickCapture.enabled"
    public static let shortcutKey = "pincer.quickCapture.shortcut"
    public static let lastTargetKey = "pincer.quickCapture.lastTarget"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// On unless the user turned it off.
    public var isEnabled: Bool {
        get { self.defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { self.defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The recorded combo, or the default when none is saved (or it can't be read).
    public var shortcut: HotKeyShortcut {
        get { self.defaults.string(forKey: Self.shortcutKey).flatMap(HotKeyShortcut.init(storageValue:)) ?? .default }
        nonmutating set { self.defaults.set(newValue.storageValue, forKey: Self.shortcutKey) }
    }

    /// What to register: the shortcut while enabled, nil while off.
    public var activeShortcut: HotKeyShortcut? { self.isEnabled ? self.shortcut : nil }

    public var isDefault: Bool { self.shortcut == .default }

    /// Back to ⌃⇧Space, turned on.
    public func reset() {
        self.defaults.removeObject(forKey: Self.shortcutKey)
        self.defaults.set(true, forKey: Self.enabledKey)
    }

    /// Where the last successful Quick Capture went.
    public var lastTarget: QuickCaptureTarget? {
        get { self.defaults.string(forKey: Self.lastTargetKey).flatMap(QuickCaptureTarget.init(storageValue:)) }
        nonmutating set { self.defaults.set(newValue?.storageValue, forKey: Self.lastTargetKey) }
    }
}

// MARK: Target

/// A chat (or new chat with an agent) on a particular Gateway.
public struct QuickCaptureTarget: Hashable, Sendable {
    public let gatewayId: UUID
    public let target: ShareTarget

    public init(gatewayId: UUID, target: ShareTarget) {
        self.gatewayId = gatewayId
        self.target = target
    }

    public var sessionKey: String? {
        if case let .chat(key) = self.target { key } else { nil }
    }

    /// `<gatewayUUID>|<ShareTarget.storageValue>`.
    public var storageValue: String { "\(self.gatewayId.uuidString)|\(self.target.storageValue)" }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let target = ShareTarget(storageValue: String(parts[1])) else { return nil }
        self.init(gatewayId: id, target: target)
    }

    /// The palette item's target, for chat and New Chat items.
    public init?(item: PaletteItem) {
        switch item.action {
        case let .openChat(target): self.init(gatewayId: target.gatewayId, target: .chat(target.sessionKey))
        case let .newChat(gatewayId, agentId): self.init(gatewayId: gatewayId, target: .newChat(agentId: agentId))
        default: return nil
        }
    }

    /// The id `QuickCapture.targetItems` gives this target's row.
    public var itemId: String {
        switch self.target {
        case let .chat(key): "chat:\(self.gatewayId.uuidString):\(key)"
        case let .newChat(agentId): "new:\(self.gatewayId.uuidString):\(agentId)"
        }
    }
}

// MARK: Pure helpers

public enum QuickCapture {
    /// Chats Quick Capture offers: the same rules as sharing (no helper runs, automations,
    /// slash-command sessions or archived chats).
    public static func isEligible(_ row: SessionRow) -> Bool {
        !row.isSubagent && !row.isAutomation && !row.isSlashCommands && !row.isArchived && !row.key.isEmpty
    }

    /// What to show instead of "connected", in `ConnectionStateText`'s words.
    public static func statusText(_ state: ConnectionState) -> String? {
        switch state {
        case .connected: nil
        case .idle, .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .awaitingPairing: "Waiting for approval"
        case .failed: "Offline"
        }
    }

    /// Chats (recently visited first, then pinned and most recently active, selected Gateway
    /// first), then "New Chat with …" for every connected Gateway's agents, filtered by `query`.
    /// Rows on a Gateway that isn't connected are disabled.
    @MainActor
    public static func targetItems(gateways: [GatewayStore], selectedGatewayId: UUID?, recent: [Notifier.Target],
                                   current: Notifier.Target? = nil, query: String = "", chatLimit: Int = 50) -> [PaletteItem]
    {
        let multiple = gateways.count > 1
        let byId = Dictionary(uniqueKeysWithValues: gateways.map { ($0.id, $0) })
        let visited = (current.map { [$0] } ?? []) + recent
        let chats = CommandPalette.chatItems(
            gateways: gateways, selectedGatewayId: selectedGatewayId, recent: visited,
            include: self.isEligible, order: { ShareModel.shareableChats(Array($0.sessions.values)) })
            .prefix(query.trimmingCharacters(in: .whitespaces).isEmpty ? chatLimit : .max)
            .map { item -> PaletteItem in
                guard case let .openChat(target) = item.action, let gateway = byId[target.gatewayId],
                      let status = self.statusText(gateway.state) else { return item }
                return item.with(subtitle: [item.subtitle, status].compactMap(\.self).joined(separator: " · "), isEnabled: false)
            }
        let ordered = gateways.sorted { lhs, _ in lhs.id == selectedGatewayId }
        let newChats = ordered.flatMap { gateway in
            CommandPalette.newChatItems(gateway: gateway).map { item in
                guard multiple else { return item }
                return item.with(subtitle: [item.subtitle, gateway.profile.name].compactMap(\.self).joined(separator: " · "),
                                 isEnabled: item.isEnabled)
            }
        }
        return PaletteMatcher.rank(Array(chats) + newChats, query: query)
    }

    /// Whether `target` can still be used: its Gateway is saved and, once sessions are listed,
    /// the chat is still there (or, for a new chat, the agent is).
    @MainActor
    public static func isAvailable(_ target: QuickCaptureTarget, gateways: [GatewayStore]) -> Bool {
        guard let gateway = gateways.first(where: { $0.id == target.gatewayId }) else { return false }
        switch target.target {
        case let .chat(key):
            guard !gateway.sessions.isEmpty else { return true }
            return gateway.sessions[key].map(self.isEligible) ?? false
        case .newChat:
            return ShareModel.isAvailable(target.target, chats: [], agents: gateway.agents)
        }
    }

    /// Where the panel starts: the target still in the panel's draft, else the last Quick Capture
    /// target, else the chat open in the main window, else the selected Gateway's default (its
    /// default agent's main chat, or a new chat with that agent). Unavailable ones are skipped.
    @MainActor
    public static func defaultTarget(draft: QuickCaptureTarget?, lastTarget: QuickCaptureTarget?, current: Notifier.Target?,
                                     gateways: [GatewayStore], selectedGatewayId: UUID?) -> QuickCaptureTarget?
    {
        let currentTarget = current.map { QuickCaptureTarget(gatewayId: $0.gatewayId, target: .chat($0.sessionKey)) }
        for candidate in [draft, lastTarget, currentTarget] {
            if let candidate, self.isAvailable(candidate, gateways: gateways) { return candidate }
        }
        guard let gateway = gateways.first(where: { $0.id == selectedGatewayId }) ?? gateways.first else { return nil }
        let target = ShareModel.defaultTarget(
            remembered: nil, chats: ShareModel.shareableChats(Array(gateway.sessions.values)),
            agents: gateway.agents, defaultAgentId: gateway.defaultAgentId)
        return QuickCaptureTarget(gatewayId: gateway.id, target: target)
    }
}

extension PaletteItem {
    func with(subtitle: String?, isEnabled: Bool) -> PaletteItem {
        PaletteItem(id: self.id, title: self.title, subtitle: subtitle, symbol: self.symbol, keywords: self.keywords,
                    shortcut: self.shortcut, section: self.section, action: self.action, isEnabled: isEnabled)
    }
}

// MARK: Model

/// State behind the Quick Capture panel: a draft (text, attachments, target) that lives for the
/// app's lifetime, the target picker, and sending through the Gateway's `ChatStore`. It never
/// touches the per-chat composer drafts, and it only changes the main window's selection when
/// the user asks to reveal the chat.
@MainActor
@Observable
public final class QuickCaptureModel {
    public let app: AppModel
    public var text = ""
    public var attachments: [OutgoingAttachment] = []
    public var target: QuickCaptureTarget?
    /// The picker's search text.
    public var query = "" {
        didSet { if oldValue != self.query { self.highlightedId = nil } }
    }
    public private(set) var isPickerOpen = false
    /// The picker row ↑/↓ moved to; nil means the first enabled row.
    public var highlightedId: String?
    public private(set) var isSending = false
    /// "Couldn’t send: …", shown until the next send or edit of the target.
    public var error: String?

    @ObservationIgnored public let settings: QuickCaptureSettings

    public init(app: AppModel, defaults: UserDefaults = .standard) {
        self.app = app
        self.settings = QuickCaptureSettings(defaults: defaults)
    }

    public var hasGateways: Bool { !self.app.gateways.isEmpty }

    public var gateway: GatewayStore? {
        self.target.flatMap { target in self.app.gateways.first { $0.id == target.gatewayId } }
    }

    /// The chat open in the main window.
    public var currentChat: Notifier.Target? {
        guard let gateway = self.app.selectedGateway, let key = gateway.selectedKey else { return nil }
        return Notifier.Target(gatewayId: gateway.id, sessionKey: key)
    }

    /// Call each time the panel opens: keeps the draft's target if it's still there, otherwise
    /// picks the default, and nudges Gateways that aren't connected. Doesn't mark anything read.
    public func prepare() {
        self.target = QuickCapture.defaultTarget(
            draft: self.target, lastTarget: self.settings.lastTarget, current: self.currentChat,
            gateways: self.app.gateways, selectedGatewayId: self.app.selectedGatewayId)
        for gateway in self.app.gateways where !gateway.state.isConnected {
            gateway.reconnectIfNeeded()
        }
    }

    // MARK: Target display

    public var targetTitle: String {
        guard let target, let gateway else { return "Choose a chat" }
        switch target.target {
        case let .chat(key): return gateway.sessions[key]?.title ?? SessionKey.agentId(from: key).map { gateway.agent($0).name } ?? key
        case let .newChat(agentId): return "New Chat with \(gateway.agent(agentId).name)"
        }
    }

    /// Agent name (for a chat), then the Gateway's name when more than one is saved.
    public var targetSubtitle: String? {
        guard let target, let gateway else { return nil }
        var parts: [String] = []
        if case let .chat(key) = target.target,
           let agentId = gateway.sessions[key]?.agentId ?? SessionKey.agentId(from: key) {
            parts.append(gateway.agent(agentId).name)
        }
        if self.app.gateways.count > 1 { parts.append(gateway.profile.name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var placeholder: String {
        guard let target, let gateway else { return "Message" }
        switch target.target {
        case .chat: return "Message \(self.targetTitle)"
        case let .newChat(agentId): return "Message \(gateway.agent(agentId).name) (new chat)"
        }
    }

    /// Why the target's Gateway can't take a message right now, or nil when it's connected.
    public var connectionStatus: String? {
        guard let gateway else { return nil }
        if case let .failed(message) = gateway.state { return message }
        return QuickCapture.statusText(gateway.state)
    }

    public var hasContent: Bool {
        !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.attachments.isEmpty
    }

    public var canSend: Bool {
        self.hasContent && self.target != nil && self.gateway?.state.isConnected == true && !self.isSending
    }

    // MARK: Picker

    public var items: [PaletteItem] {
        QuickCapture.targetItems(
            gateways: self.app.gateways, selectedGatewayId: self.app.selectedGatewayId,
            recent: self.app.history.recent, current: self.app.history.current, query: self.query)
    }

    /// The highlighted row: the one ↑/↓ moved to, else the current target's, else the first enabled.
    public func highlighted(in items: [PaletteItem]) -> PaletteItem? {
        if let highlightedId, let item = items.first(where: { $0.id == highlightedId }) { return item }
        if self.query.isEmpty, let id = self.target?.itemId, let item = items.first(where: { $0.id == id && $0.isEnabled }) {
            return item
        }
        return items.first(where: \.isEnabled)
    }

    public func openPicker() {
        self.query = ""
        self.highlightedId = nil
        self.isPickerOpen = true
    }

    public func closePicker() {
        self.isPickerOpen = false
        self.query = ""
        self.highlightedId = nil
    }

    public func togglePicker() {
        if self.isPickerOpen { self.closePicker() } else { self.openPicker() }
    }

    /// Moves the highlight, wrapping around and skipping disabled rows.
    public func moveHighlight(by offset: Int) {
        let items = self.items
        guard items.contains(where: \.isEnabled) else { return }
        var index = self.highlighted(in: items).flatMap { item in items.firstIndex { $0.id == item.id } } ?? 0
        repeat {
            index = (index + offset.signum() + items.count) % items.count
        } while !items[index].isEnabled
        self.highlightedId = items[index].id
    }

    /// Makes `item` the target and closes the picker. Disabled rows can't be picked.
    @discardableResult
    public func pick(_ item: PaletteItem) -> Bool {
        guard item.isEnabled, let target = QuickCaptureTarget(item: item) else { return false }
        self.target = target
        self.error = nil
        self.closePicker()
        return true
    }

    @discardableResult
    public func pickHighlighted() -> Bool {
        guard let item = self.highlighted(in: self.items) else { return false }
        return self.pick(item)
    }

    /// ⌘1–⌘9: the selected Gateway's pinned chats.
    @discardableResult
    public func pickPinned(_ number: Int) -> Bool {
        guard let item = self.items.first(where: { $0.shortcut == "⌘\(number)" }) else { return false }
        return self.pick(item)
    }

    // MARK: Sending

    /// Sends the draft: `chat.send` for a chat, or `sessions.create` then `chat.send` for a new one.
    /// On success the draft is cleared, the target remembered, and with `reveal` the chat opened in
    /// the main window. On failure everything is kept and `error` says why.
    @discardableResult
    public func send(reveal: Bool = false) async -> Bool {
        guard self.canSend, let picked = self.target, let gateway else { return false }
        self.isSending = true
        self.error = nil
        defer { self.isSending = false }
        let key: String
        switch picked.target {
        case let .chat(existing):
            key = existing
        case let .newChat(agentId):
            guard let created = await gateway.createSession(agentId: agentId, label: nil, select: false) else {
                self.error = "Couldn’t send: \(gateway.lastError ?? "the Gateway didn’t create a chat.")"
                return false
            }
            key = created
            // A retry after a failed send goes to this chat instead of creating another one.
            self.target = QuickCaptureTarget(gatewayId: gateway.id, target: .chat(created))
        }
        let text = SlashCommand.outgoingText(self.text, commands: gateway.slashCommands(for: key))
        let outcome = await gateway.chat(for: key).sendMessage(text, attachments: self.attachments)
        if case let .failed(message) = outcome {
            self.error = message
            return false
        }
        // A new chat is remembered as the chat it became, so the next capture continues it.
        self.settings.lastTarget = QuickCaptureTarget(gatewayId: gateway.id, target: .chat(key))
        self.text = ""
        self.attachments = []
        self.target = nil
        self.closePicker()
        if reveal { self.app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: key)) }
        return true
    }

    /// Opens the target chat in the main window without sending; the draft stays.
    @discardableResult
    public func revealTarget() -> Bool {
        guard let target, let key = target.sessionKey, self.gateway != nil else { return false }
        self.app.open(Notifier.Target(gatewayId: target.gatewayId, sessionKey: key))
        return true
    }
}
