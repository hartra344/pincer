import PincerKit
import SwiftUI

/// Slash command (and argument) suggestions shown above the composer while typing `/…`.
struct SlashCommandMenu: View {
    let suggestions: [SlashSuggestion]
    @Binding var selection: Int
    let onPick: (SlashSuggestion) -> Void
    @State private var contentHeight: CGFloat = 0

    private static let corner: CGFloat = 16
    static let maxHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = self.header {
                Text(header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ScrollViewReader { proxy in
                // As tall as the rows, up to `maxHeight`; only then does it scroll.
                ScrollView {
                    self.rows
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.contentHeight = $0 }
                }
                .scrollDisabled(self.contentHeight <= Self.maxHeight)
                .frame(height: min(max(self.contentHeight, 1), Self.maxHeight))
                .onChange(of: self.selection) { _, index in
                    guard self.suggestions.indices.contains(index) else { return }
                    proxy.scrollTo(self.suggestions[index].id)
                }
            }
        }
        .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command suggestions")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(self.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SlashSuggestionRow(suggestion: suggestion, isSelected: index == self.selection)
                    .id(suggestion.id)
                    .contentShape(Rectangle())
                    .onTapGesture { self.onPick(suggestion) }
                    #if os(macOS)
                    .onHover { if $0 { self.selection = index } }
                    #endif
            }
        }
        .padding(6)
    }

    /// For argument suggestions: which command and argument they fill in.
    private var header: String? {
        guard case let .argument(_, command, arg)? = self.suggestions.first?.kind else { return nil }
        let description = arg.description.isEmpty ? "" : " — \(arg.description)"
        return "/\(command.name) \(arg.name)\(description)"
    }
}

private struct SlashSuggestionRow: View {
    let suggestion: SlashSuggestion
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch self.suggestion.kind {
            case let .command(command):
                Text("/\(command.name)")
                    .font(.body.monospaced().weight(.medium))
                if !command.usage.isEmpty {
                    Text(command.usage)
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(command.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge = Self.badge(command.source) {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            case let .argument(choice, _, _):
                Text(choice.value)
                    .font(.body.monospaced().weight(.medium))
                    .lineLimit(1)
                if choice.label != choice.value {
                    Text(choice.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let detail = choice.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private static func badge(_ source: String) -> String? {
        switch source {
        case "skill": "Skill"
        case "plugin": "Plugin"
        default: nil
        }
    }
}
