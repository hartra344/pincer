import Foundation
import PincerKit

/// A throwaway defaults suite; call `remove()` when done.
struct ScratchDefaults {
    let name = "pincer.uitests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { self.defaults = UserDefaults(suiteName: self.name)! }

    func remove() {
        self.defaults.removePersistentDomain(forName: self.name)
        try? FileManager.default.removeItem(
            at: URL.libraryDirectory.appending(path: "Preferences/\(self.name).plist"))
    }
}

import CryptoKit
@testable import PincerKit

enum UIFixtures {
    /// Fixed key, so tests never touch the Keychain.
    static func identity() -> DeviceIdentity {
        DeviceIdentity(privateKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map { UInt8($0) })))
    }
}

/// Same convention as Tests/PincerKitTests/Support.swift: the budget is enforced only when
/// `PINCER_STRICT_PERF=1` (the solo perf lane); otherwise a 5x ceiling applies.
enum PerfBudget {
    static let isStrict = ProcessInfo.processInfo.environment["PINCER_STRICT_PERF"] == "1"
    static let sharedCPUFactor = 5

    static func limit(_ budget: Duration) -> Duration {
        self.isStrict ? budget : budget * self.sharedCPUFactor
    }

    /// Wall-clock ratios between two timings (e.g. "25 KB p95 ≤ 1.5× 10 KB p95") swing with a shared
    /// runner's noise even when run solo, so they're enforced only in the local solo perf lane
    /// (`PINCER_STRICT_PERF=1` outside CI) or when opted in with `PINCER_WALL_CLOCK_CHECKS=1`. Elsewhere
    /// the probes rely on their counter-based checks and just print the timings.
    static var enforcesWallClockRatios: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["PINCER_WALL_CLOCK_CHECKS"] == "1" { return true }
        return self.isStrict && env["CI"] == nil
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    #if DEBUG
    return await uiTestEventually(timeout: timeout, condition)
    #else
    let deadline = ContinuousClock.now + timeout
    while true {
        guard !Task.isCancelled else { return false }
        let ready = condition()
        guard !Task.isCancelled else { return false }
        if ready { return true }
        if ContinuousClock.now >= deadline {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
            guard !Task.isCancelled else { return false }
            let finalReady = condition()
            return !Task.isCancelled && finalReady
        }
        do { try await Task.sleep(for: .milliseconds(5)) }
        catch { return false }
        guard !Task.isCancelled else { return false }
    }
    #endif
}
