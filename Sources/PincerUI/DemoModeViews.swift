import PincerKit
import SwiftUI

/// Top of the demo's chat list: says this is the demo and offers the way out to a real Gateway (#954).
struct DemoModeRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                self.label
                Spacer(minLength: 4)
                self.connect
            }
            VStack(alignment: .leading, spacing: 4) {
                self.label
                self.connect
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-demo-banner")
    }

    private var label: some View {
        Label(L("You're in the Demo"), systemImage: "play.circle")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var connect: some View {
        Button(L("Connect Your Gateway…")) { self.app.leaveDemo(connect: true) }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("demo-connect-gateway")
    }
}
