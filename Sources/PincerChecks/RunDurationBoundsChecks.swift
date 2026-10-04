import Foundation
import PincerKit

@MainActor func runRunDurationBoundsChecks() {
    let hours = Int.max / 3600, minutes = Int.max / 60 % 60, seconds = Int.max % 60
    let saturated = String(format: "%d:%02d:%02d", hours, minutes, seconds)
    check([1e30, Double(Int.max), Double.greatestFiniteMagnitude].allSatisfy { RunDuration.format($0) == saturated },
          "Runs duration clamps finite overflow before conversion while retaining existing format")
    let total = Int(Double(Int.max).nextDown)
    check(RunDuration.format(Double(Int.max).nextDown) == String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60),
          "Runs representable integer boundary retains exact output")
    check(RunDuration.format(65.9) == "1:05" && RunDuration.format(3601.9) == "1:00:01", "Runs ordinary fractional durations retain flooring")
    check([Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.999].allSatisfy { RunDuration.format($0) == "<1s" },
          "Runs nonfinite and subsecond output remains unchanged")
}
