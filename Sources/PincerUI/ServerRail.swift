import PincerKit
import SwiftUI

/// Discord-style server rail: one icon per Gateway, unread dots, add button.
struct ServerRail: View {
    @Environment(AppModel.self) private var app
    @Binding var editing: GatewayProfile?
    @Binding var addingGateway: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(self.app.gateways) { gateway in
                    ServerIcon(gateway: gateway, isSelected: gateway.id == self.app.selectedGatewayId)
                        .onTapGesture { self.app.selectedGatewayId = gateway.id }
                        .contextMenu {
                            Button("Edit Connection…") { self.editing = gateway.profile }
                            Button("Reconnect") { gateway.stop(); gateway.start() }
                            Divider()
                            Button("Move Up") { self.app.move(gateway.id, by: -1) }
                            Button("Move Down") { self.app.move(gateway.id, by: 1) }
                        }
                }
                Button {
                    self.addingGateway = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: 44, height: 44)
                        .background(.quinary, in: Circle())
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Add a Gateway")
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: Theme.railWidth)
        .background(.background.secondary)
    }
}

private struct ServerIcon: View {
    let gateway: GatewayStore
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(.primary)
                .frame(width: 4, height: self.isSelected ? 36 : (self.gateway.totalUnread > 0 ? 8 : 0))
                .offset(x: -8)
            ZStack(alignment: .bottomTrailing) {
                Text(self.gateway.profile.initials)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(self.isSelected ? .white : .primary)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: self.isSelected ? 14 : 22, style: .continuous)
                            .fill(self.isSelected ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(.quaternary)))
                Circle()
                    .fill(self.statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .animation(.snappy, value: self.isSelected)
        .contentShape(Rectangle())
        .help("\(self.gateway.profile.name) — \(self.statusText)")
        .accessibilityElement()
        .accessibilityLabel("\(self.gateway.profile.name), \(self.statusText)")
        .accessibilityAddTraits(self.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var statusColor: Color {
        switch self.gateway.state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .awaitingPairing: .orange
        case .failed: .red
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch self.gateway.state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .awaitingPairing: "Waiting for approval"
        case .failed: "Connection failed"
        case .idle: "Offline"
        }
    }
}
