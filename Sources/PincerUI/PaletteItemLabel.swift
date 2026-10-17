import SwiftUI

/// The title with its optional one-line subtitle, as shown in the command palette and quick capture rows.
struct PaletteItemLabel: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            Text(self.title).lineLimit(1)
            if let subtitle = self.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
