import CryptoKit
import Foundation
@testable import PincerKit

/// Fixed Ed25519 key (bytes 1…32), so ids and public keys are known constants. Never touches the Keychain.
enum Fixtures {
    static let rawKey = Data((1...32).map { UInt8($0) })
    static let otherRawKey = Data((33...64).map { UInt8($0) })

    /// hex(sha256(publicKey)) for `rawKey`.
    static let deviceId = "65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8"
    /// Unpadded base64url of `rawKey`'s public key (its standard base64 contains `/` and `=`).
    static let publicKeyBase64Url = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"

    static func identity(_ raw: Data = rawKey) -> DeviceIdentity {
        DeviceIdentity(privateKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: raw))
    }

    static func json(_ text: String) -> JSONValue {
        try! JSONValue.decode(Data(text.utf8))
    }
}

/// Decodes unpadded base64url.
func base64UrlDecode(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
}

/// A unique folder under the system temp directory, removed by `remove()`.
struct TempDir {
    let url: URL

    init() {
        self.url = FileManager.default.temporaryDirectory
            .appending(path: "pincer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.url)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func contents(of url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? [])
    }
}

/// A throwaway defaults suite; call `remove()` when done.
struct ScratchDefaults {
    let name = "pincer.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        self.defaults = UserDefaults(suiteName: self.name)!
    }

    func remove() {
        self.defaults.removePersistentDomain(forName: self.name)
        // removePersistentDomain leaves an empty plist behind.
        try? FileManager.default.removeItem(
            at: URL.libraryDirectory.appending(path: "Preferences/\(self.name).plist"))
    }
}

/// True for a missing key. (`== nil` is ambiguous because `JSONValue` is `ExpressibleByNilLiteral`.)
func absent(_ value: JSONValue?) -> Bool {
    if case .none = value { true } else { false }
}

/// Wall-clock budgets for perf tests. `swift test --parallel` shares the CPU with the other check
/// lanes, so there only a generous ceiling applies (it still catches a quadratic blow-up); the
/// budget itself is enforced when `PINCER_STRICT_PERF=1`, as in the solo `perf-tests` lane of
/// `scripts/run-checks.sh`.
enum PerfBudget {
    static let isStrict = ProcessInfo.processInfo.environment["PINCER_STRICT_PERF"] == "1"
    static let sharedCPUFactor = 5

    static func limit(_ budget: Duration) -> Duration {
        self.isStrict ? budget : budget * self.sharedCPUFactor
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes. The short sleep is
/// only the poll interval; the wait ends as soon as the condition is true.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        // One last look after the deadline: a starved main actor may run the awaited work late.
        if ContinuousClock.now >= deadline {
            try? await Task.sleep(for: .milliseconds(50))
            return condition()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// One-shot latch: `wait()` suspends until `open()`; later waits return at once.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        for waiter in self.waiters { waiter.resume() }
        self.waiters = []
    }
}
