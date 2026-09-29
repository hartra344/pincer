import PincerKit
import SwiftUI

/// "Editing message" above the composer, with the start of the original text and a cancel button.
struct MessageEditChip: View {
    let originalText: String
    let onCancel: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "pencil")
                .foregroundStyle(self.theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text("Editing message", bundle: .module)
                    .font(.caption)
                Text(Replies.previewLine(self.originalText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button(action: self.onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel edit", bundle: .module))
            .accessibilityLabel(Text("Cancel edit", bundle: .module))
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
