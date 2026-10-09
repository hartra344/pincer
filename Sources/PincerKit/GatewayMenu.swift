import Foundation

/// The Gateway switcher's rows: pure, so the menu and its shortcuts are testable without an `AppModel`.
public struct GatewayMenuModel: Sendable, Equatable {
    public struct Input: Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var state: ConnectionState
        public var healthLevel: GatewayHealthLevel
        public var isDemo: Bool

        public init(id: UUID = UUID(), name: String, state: ConnectionState, healthLevel: GatewayHealthLevel = .healthy,
                    isDemo: Bool = false)
        {
            self.id = id
            self.name = name
            self.state = state
            self.healthLevel = healthLevel
            self.isDemo = isDemo
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var statusText: String
        public var symbol: String
        public var level: MenuBarInbox.GatewayStatus.Level
        public var isDemo: Bool
        public var isSelected: Bool

        public var accessibilityLabel: String {
            self.isDemo && self.statusText == L("Demo")
                ? "\(self.name), \(L("demo gateway"))"
                : "\(self.name), \(self.statusText.lowercased())"
        }

        /// One-line menu item, matching the menu bar extra's "Name — Status".
        public var menuTitle: String {
            self.isDemo && self.statusText == L("Demo") ? self.name : "\(self.name) — \(self.statusText)"
        }
    }

    public enum AddAction: Sendable, Equatable {
        case connectYourGateway, addGateway
    }

    public var entries: [Entry]

    public static func build(_ inputs: [Input], selectedId: UUID?) -> GatewayMenuModel {
        GatewayMenuModel(entries: inputs.map { input in
            var status = MenuBarInbox.statusText(state: input.state, healthLevel: input.healthLevel)
            if input.isDemo, !Self.isFailed(input.state) { status.text = L("Demo") }
            return Entry(id: input.id, name: input.name, statusText: status.text, symbol: status.symbol, level: status.level,
                         isDemo: input.isDemo, isSelected: input.id == selectedId)
        })
    }

    private static func isFailed(_ state: ConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    public var selected: Entry? { self.entries.first { $0.isSelected } }
    public var showsDemoBadge: Bool { self.selected?.isDemo == true }
    public var hasDemo: Bool { self.entries.contains { $0.isDemo } }

    /// Connecting replaces the demo, so only offer it when the demo is selected and nothing else is saved.
    public var addAction: AddAction {
        self.showsDemoBadge && !self.entries.contains { !$0.isDemo } ? .connectYourGateway : .addGateway
    }
    public var addActionTitle: String {
        self.addAction == .connectYourGateway ? L("Connect Your Gateway…") : L("Add Gateway…")
    }

    public var canCycle: Bool { self.entries.count >= 2 }

    /// The next Gateway in saved order, wrapping; nil or unknown ids start at the first.
    public func next(after id: UUID?) -> UUID? {
        guard self.canCycle else { return nil }
        guard let id, let index = self.entries.firstIndex(where: { $0.id == id }) else { return self.entries.first?.id }
        return self.entries[(index + 1) % self.entries.count].id
    }

    /// The previous Gateway in saved order, wrapping; nil or unknown ids start at the last.
    public func previous(before id: UUID?) -> UUID? {
        guard self.canCycle else { return nil }
        guard let id, let index = self.entries.firstIndex(where: { $0.id == id }) else { return self.entries.last?.id }
        return self.entries[(index + self.entries.count - 1) % self.entries.count].id
    }
}

extension AppModel {
    /// The switcher's rows for the saved Gateways, in saved order.
    public var gatewayMenu: GatewayMenuModel {
        let now = Date()
        return GatewayMenuModel.build(self.gateways.map {
            GatewayMenuModel.Input(id: $0.id, name: $0.profile.name, state: $0.state,
                                   healthLevel: $0.health.level(now: now), isDemo: $0.profile.isDemo)
        }, selectedId: self.selectedGatewayId)
    }

    public func selectNextGateway() {
        if let id = self.gatewayMenu.next(after: self.selectedGatewayId) { self.selectedGatewayId = id }
    }

    public func selectPreviousGateway() {
        if let id = self.gatewayMenu.previous(before: self.selectedGatewayId) { self.selectedGatewayId = id }
    }
}
