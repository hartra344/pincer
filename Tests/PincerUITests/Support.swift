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
