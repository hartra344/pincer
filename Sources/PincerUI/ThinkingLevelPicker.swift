import PincerKit
import SwiftUI

/// Shows a session's thinking level and changes it, next to the model picker. Slow, costly levels
/// (high and up) are tinted and marked, so a chat left on Ultra doesn't go unnoticed.
struct ThinkingLevelPicker: View {
    let row: SessionRow
    var showsActionTitle = false
    @Environment(GatewayStore.self) private var gateway

    private var menu: ThinkingLevelMenu { ThinkingLevelMenu(row: self.row) }
    /// Why the picker can't be used right now; nil when it can.
    enum Unavailable: Equatable {
        case disconnected, placeholder, unsupported
    }

    static func unavailable(isConnected: Bool, row: SessionRow, menu: ThinkingLevelMenu) -> Unavailable? {
        if !isConnected { return .disconnected }
        if row.isPlaceholder { return .placeholder }
        // With no levels reported "Default" isn't callable either, so the whole picker is off.
        if !menu.reportsLevels { return .unsupported }
        return nil
    }

    var body: some View {
        let menu = self.menu
        let unavailable = Self.unavailable(isConnected: self.gateway.state.isConnected, row: self.row, menu: menu)
        Menu {
            self.content(menu)
        } label: {
            Label {
                Text(self.title(menu))
            } icon: {
                Image(systemName: menu.currentIsExpensive ? "exclamationmark.triangle.fill" : "brain.head.profile")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(menu.currentIsExpensive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        }
        .tint(menu.currentIsExpensive ? .orange : nil)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(unavailable != nil)
        .help(Self.summary(menu, unavailable: unavailable))
        .accessibilityLabel(L("Thinking Level"))
        .accessibilityValue(Self.accessibilityValue(menu))
        .accessibilityHint(unavailable.map(Self.reason) ?? "")
    }

    private func title(_ menu: ThinkingLevelMenu) -> String {
        if self.showsActionTitle {
            return menu.currentLabel.map { L("Thinking Level: \($0)") } ?? L("Thinking Level")
        }
        return menu.currentLabel ?? L("Thinking")
    }

    static func reason(_ unavailable: Unavailable) -> String {
        switch unavailable {
        case .disconnected: L("Connect to the Gateway to change the thinking level.")
        case .placeholder: L("Send a message first to change this chat's thinking level.")
        case .unsupported: L("This Gateway did not report thinking levels; use /think instead.")
        }
    }

    private static func summary(_ menu: ThinkingLevelMenu, unavailable: Unavailable?) -> String {
        let base = self.summary(menu)
        guard let unavailable else { return base }
        return menu.currentLabel == nil ? self.reason(unavailable) : base + "\n" + self.reason(unavailable)
    }

    private static func summary(_ menu: ThinkingLevelMenu) -> String {
        guard let label = menu.currentLabel else { return L("Choose the thinking level for new messages") }
        var text = menu.followsDefault ? L("Thinking level: \(label) (inherited default)") : L("Thinking level: \(label)")
        if menu.currentIsExpensive { text += " — " + L("May be slower and cost more") }
        return text
    }

    private static func accessibilityValue(_ menu: ThinkingLevelMenu) -> String {
        guard let label = menu.currentLabel else { return L("Default") }
        var value = menu.followsDefault ? L("\(label) (inherited default)") : label
        if menu.currentIsExpensive { value += ", " + L("May be slower and cost more") }
        return value
    }

    @ViewBuilder private func content(_ menu: ThinkingLevelMenu) -> some View {
        Button {
            self.select(nil)
        } label: {
            let title = menu.defaultLabel.map { L("Default (\($0))") } ?? L("Default")
            if menu.followsDefault { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        Divider()
        ForEach(menu.items) { item in
            Button {
                self.select(item.id)
            } label: {
                let title = item.isExpensive ? L("\(item.label) (slower, costs more)") : item.label
                if item.isSelected {
                    Label(title, systemImage: "checkmark")
                } else if item.isExpensive {
                    Label(title, systemImage: "exclamationmark.triangle")
                } else {
                    Text(title)
                }
            }
            .disabled(!item.isEnabled)
        }
    }

    private func select(_ level: String?) {
        let key = self.row.key
        Task { await self.gateway.setThinkingLevel(key, to: level) }
    }
}
