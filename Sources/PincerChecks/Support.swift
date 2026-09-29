import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
    if condition() {
        passes += 1
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)  (line \(line))")
    }
}

let skipPerfBudgets = CommandLine.arguments.contains("--skip-perf-budgets")

/// Wall-clock ratios (one timing vs. another from the same run) swing with a shared CI runner's noise
/// even in the solo perf-smoke lane, so on CI they're only reported unless opted in with
/// `PINCER_WALL_CLOCK_CHECKS=1`. The counters and absolute ceilings are always enforced.
let enforceWallClockRatios: Bool = {
    let env = ProcessInfo.processInfo.environment
    if skipPerfBudgets { return false }
    return env["PINCER_WALL_CLOCK_CHECKS"] == "1" || env["CI"] == nil
}()

/// A wall-clock ratio check: enforced per `enforceWallClockRatios`, otherwise just reported.
@MainActor
func checkWallClockRatio(_ condition: @autoclosure () -> Bool, _ label: String, line: UInt = #line) {
    if enforceWallClockRatios { return check(condition(), label, line: line) }
    if !skipPerfBudgets, !condition() { print("  · \(label) (over the ratio, not enforced on CI)") }
}

/// A wall-clock budget. With --skip-perf-budgets, only going over `hardLimit` fails; over the
/// budget is just reported.
@MainActor
func checkBudget(_ elapsed: Duration, _ budget: Duration, hardLimit: Duration, _ label: String, line: UInt = #line) {
    if skipPerfBudgets, elapsed > budget, elapsed <= hardLimit {
        print("  · \(label) (over the \(budget.formatted(.units(allowed: [.milliseconds]))) budget, not enforced with --skip-perf-budgets)")
        return
    }
    check(elapsed <= (skipPerfBudgets ? hardLimit : budget), label, line: line)
}

func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@MainActor
func waitFor(_ label: String, timeout: Double = 15, every interval: Int = 100, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(interval))
    }
    print("    … timed out waiting for \(label)")
    return condition()
}

/// Waits until `value` stops changing for `quiet` seconds (or `timeout` passes).
@MainActor
func waitForQuiet(_ label: String, quiet: Double = 1, timeout: Double = 10, _ value: () -> Int) async {
    let deadline = Date().addingTimeInterval(timeout)
    var last = value(), since = Date()
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
        let now = value()
        if now != last { last = now; since = Date() } else if Date().timeIntervalSince(since) >= quiet { return }
    }
    print("    … timed out waiting for \(label) to settle")
}

/// Mutable script state for fake Gateways, shared with their request closures.
@MainActor
final class Scripted<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
}
