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
