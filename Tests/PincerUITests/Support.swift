import Foundation

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
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            try? await Task.sleep(for: .milliseconds(50))
            return condition()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
