import Foundation
import PincerKit

@MainActor func runSessionSpokenDurationSafetyChecks() {
    let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
    check([1e30, Double.greatestFiniteMagnitude, Double(Int.max)].allSatisfy {
        SessionManager.spokenDuration($0) == Duration.seconds(Int.max).formatted(style)
    }, "oversized finite spoken durations use the exact supported integer limit")
    // Local formatter inputs, not nonfinite Gateway JSON values.
    check([Double.nan, Double.infinity, -Double.infinity, -1, 0].allSatisfy {
        SessionManager.spokenDuration($0) == Duration.seconds(0).formatted(style)
    }, "local invalid and negative spoken durations use zero")
    check(SessionManager.spokenDuration(94.9) == Duration.seconds(94).formatted(style)
          && SessionManager.formatDuration(94.9) == "1 min 34 sec", "ordinary spoken and visual duration flooring is unchanged")
}
