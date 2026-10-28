import PincerKit
import SwiftUI

/// Shows a session's thinking level and changes it, next to the model picker. Slow, costly levels
/// (high and up) are tinted and marked, so a chat left on Ultra doesn't go unnoticed.
struct ThinkingLevelPicker: View {
    let row: SessionRow
    var showsActionTitle = false
    @Environment(GatewayStore.self) private var gateway

    private var menu: ThinkingLevelMenu { ThinkingLevelMenu(row: self.row) }
    private var isDisabled: Bool { !self.gateway.state.isConnected || self.row.isPlaceholder }

    var body: some View {
        let menu = self.menu
        Menu {
            self.content(menu)
        } label: {
            Label {
                Text(self.showsActionTitle ? L("Thinking Level") : (menu.currentLabel ?? L("Thinking")))
            } icon: {
                Image(systemName: menu.currentIsExpensive ? "exclamationmark.triangle.fill" : "brain.head.profile")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(menu.currentIsExpensive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
        }
        .tint(menu.currentIsExpensive ? .orange : nil)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(self.isDisabled)
        .help(Self.summary(menu))
        .accessibilityLabel(L("Thinking Level"))
        .accessibilityValue(Self.accessibilityValue(menu))
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
        if !menu.reportsLevels {
            Text(L("This Gateway did not report thinking levels; use /think instead."))
        }
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
