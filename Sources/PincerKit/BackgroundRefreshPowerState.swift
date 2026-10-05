import Foundation
import Observation

/// Presentation state only; never changes notification preferences or refresh scheduling.
@MainActor @Observable package final class BackgroundRefreshPowerState {
    package private(set) var isLowPowerModeEnabled: Bool
    @ObservationIgnored private let read: () -> Bool
    package init(read: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }) {
        self.read = read
        self.isLowPowerModeEnabled = read()
    }
    package func refresh() { self.isLowPowerModeEnabled = self.read() }
    package func showsPauseNote(delivery: ClosedAppDelivery) -> Bool {
        delivery == .backgroundRefresh && self.isLowPowerModeEnabled
    }
}
