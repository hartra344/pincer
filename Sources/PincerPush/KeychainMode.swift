import Foundation
import Synchronization

/// Decides whether secrets go to the real Keychain or a process-local store, shared by
/// `Keychain` (PincerKit) and `PushKeyStore`. The memory store is used when
/// `PINCER_KEYCHAIN=memory` is set, when running under a test runner (`swift test`), or after
/// `useInMemoryStore()` is called, so checks and tests never touch or prompt for the real Keychain.
public enum KeychainMode {
    private static let forced = Atomic<Bool>(false)
    private static let realCalls = Atomic<Int>(0)

    /// Whether the process started in memory mode (environment or test runner).
    static let startsInMemory: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["PINCER_KEYCHAIN"] == "memory" { return true }
        return isTestProcess(environment: env, processName: ProcessInfo.processInfo.processName)
    }()

    static func isTestProcess(environment env: [String: String], processName: String) -> Bool {
        if ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains(where: { env[$0] != nil }) { return true }
        if ["xctest", "swiftpm-testing-helper"].contains(processName) { return true }
        return NSClassFromString("XCTestCase") != nil
    }

    /// Switches every secret store in this process to memory. Call before touching any secret.
    public static func useInMemoryStore() {
        self.forced.store(true, ordering: .sequentiallyConsistent)
    }

    public static var isInMemory: Bool {
        self.startsInMemory || self.forced.load(ordering: .sequentiallyConsistent)
    }

    /// Number of real `SecItem*` calls made by this process, for guards in checks and tests.
    public static var realKeychainCalls: Int {
        self.realCalls.load(ordering: .sequentiallyConsistent)
    }

    package static func recordRealAccess() {
        self.realCalls.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }
}
