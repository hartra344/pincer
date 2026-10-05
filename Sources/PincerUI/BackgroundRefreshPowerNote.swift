#if os(iOS)
import PincerKit
import SwiftUI

struct BackgroundRefreshPowerNote: View {
    let delivery: ClosedAppDelivery
    let power: BackgroundRefreshPowerState
    var body: some View {
        Group {
            if self.power.showsPauseNote(delivery: self.delivery) {
                Label(L("Low Power Mode is on, so iOS won't check until it's off."), systemImage: "battery.25percent")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-refresh-low-power-note")
            }
        }

    }
}
#endif
