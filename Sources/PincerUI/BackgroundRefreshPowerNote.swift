#if os(iOS)
import PincerKit
import SwiftUI

struct BackgroundRefreshPowerNote: View {
    let delivery: ClosedAppDelivery
    @State private var power: BackgroundRefreshPowerState
    private let center: NotificationCenter
    init(delivery: ClosedAppDelivery, power: BackgroundRefreshPowerState? = nil, center: NotificationCenter = .default) {
        self.delivery = delivery
        self._power = State(initialValue: power ?? BackgroundRefreshPowerState())
        self.center = center
    }
    var body: some View {
        Group {
            if self.power.showsPauseNote(delivery: self.delivery) {
                Label(L("Low Power Mode is on, so iOS won't check until it's off."), systemImage: "battery.25percent")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-refresh-low-power-note")
            }
        }
        .onAppear { self.power.refresh() }
        .onReceive(self.center.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in self.power.refresh() }
    }
}
#endif
