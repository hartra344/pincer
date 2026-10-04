import Foundation
import PincerKit

@MainActor func runRunDurationBoundsChecks() {
    let saturated = "2562047788015215:30:07"
    check([1e30, Double(Int.max), Double.greatestFiniteMagnitude].allSatisfy { RunDuration.format($0) == saturated },
          "Runs duration clamps finite overflow before conversion while retaining existing format")
    check(RunDuration.format(Double(Int.max).nextDown) == "2562047788015215:13:04",
          "Runs representable integer boundary retains exact output")
    check(RunDuration.format(Double(2_147_483_648) * 3600) == "2147483648:00:00", "Runs hours retain the full nonnegative decimal above Int32")
    check(RunDuration.format(65.9) == "1:05" && RunDuration.format(3601.9) == "1:00:01", "Runs ordinary fractional durations retain flooring")
    check([Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.999].allSatisfy { RunDuration.format($0) == "<1s" },
          "Runs nonfinite and subsecond output remains unchanged")
}
