import CryptoKit
import Foundation

/// A Web Push subscription's receiving keys (RFC 8291): a P-256 key pair and a 16-byte auth secret.
/// The Gateway encrypts each notification to these, so only this device can read it. The relay
/// that forwards it to APNs sees only ciphertext.
public struct WebPushKeys: Sendable {
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let authSecret: Data

    public init(privateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) {
        self.privateKey = privateKey
        self.authSecret = authSecret
    }

    public static func generate() -> WebPushKeys {
        WebPushKeys(privateKey: P256.KeyAgreement.PrivateKey(), authSecret: WebPush.randomBytes(16))
    }

    /// Uncompressed public point, base64url, as `PushSubscription.keys.p256dh`.
    public var p256dh: String { self.privateKey.publicKey.x963Representation.base64URL }
    public var auth: String { self.authSecret.base64URL }

    /// Serialized form for the Keychain.
    public var stored: String { "\(self.privateKey.rawRepresentation.base64URL).\(self.auth)" }

    public init?(stored: String) {
        let parts = stored.split(separator: ".").map(String.init)
        guard parts.count == 2,
              let raw = Data(base64URL: parts[0]),
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw),
              let auth = Data(base64URL: parts[1]), auth.count == 16
        else { return nil }
        self.init(privateKey: key, authSecret: auth)
    }
}

public enum WebPushError: Error, Equatable {
    case malformed
    case decryptionFailed
}

/// `Content-Encoding: aes128gcm` (RFC 8188) with Web Push key derivation (RFC 8291).
public enum WebPush {
    private static let headerLength = 21

    public static func decrypt(_ body: Data, keys: WebPushKeys) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count > self.headerLength else { throw WebPushError.malformed }
        let salt = Data(bytes[0 ..< 16])
        let recordSize = bytes[16 ..< 20].reduce(0) { $0 << 8 | Int($1) }
        let idLength = Int(bytes[20])
        guard recordSize > 17, bytes.count > self.headerLength + idLength else { throw WebPushError.malformed }
        let senderKeyData = Data(bytes[self.headerLength ..< self.headerLength + idLength])
        guard let senderKey = try? P256.KeyAgreement.PublicKey(x963Representation: senderKeyData) else {
            throw WebPushError.malformed
        }
        guard let shared = try? keys.privateKey.sharedSecretFromKeyAgreement(with: senderKey) else {
            throw WebPushError.malformed
        }
        let (cek, baseNonce) = self.contentKeys(
            shared: shared, salt: salt, receiverPublic: keys.privateKey.publicKey,
            senderPublic: senderKey, auth: keys.authSecret)

        var plaintext = Data()
        var offset = self.headerLength + idLength
        var sequence: UInt64 = 0
        while offset < bytes.count {
            let end = min(offset + recordSize, bytes.count)
            let record = Data(bytes[offset ..< end])
            guard record.count > 16 else { throw WebPushError.malformed }
            let opened: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: self.nonce(baseNonce, sequence: sequence)),
                    ciphertext: record.dropLast(16), tag: record.suffix(16))
                opened = try AES.GCM.open(box, using: cek)
            } catch {
                throw WebPushError.decryptionFailed
            }
            // Padding is trailing zeros after a delimiter: 0x02 on the last record, 0x01 before it.
            guard let delimiter = opened.lastIndex(where: { $0 != 0 }),
                  opened[delimiter] == (end == bytes.count ? 2 : 1)
            else { throw WebPushError.malformed }
            plaintext.append(opened[opened.startIndex ..< delimiter])
            offset = end
            sequence += 1
        }
        return plaintext
    }

    /// Single-record encryption, as the Gateway does it. Used by the checks.
    public static func encrypt(
        _ plaintext: Data,
        p256dh: Data,
        auth: Data,
        senderPrivate: P256.KeyAgreement.PrivateKey = .init(),
        salt: Data = WebPush.randomBytes(16)) throws -> Data
    {
        let receiver = try P256.KeyAgreement.PublicKey(x963Representation: p256dh)
        let shared = try senderPrivate.sharedSecretFromKeyAgreement(with: receiver)
        let (cek, nonce) = self.contentKeys(
            shared: shared, salt: salt, receiverPublic: receiver,
            senderPublic: senderPrivate.publicKey, auth: auth)
        let sealed = try AES.GCM.seal(plaintext + [2], using: cek, nonce: AES.GCM.Nonce(data: nonce))
        let senderKey = senderPrivate.publicKey.x963Representation
        return salt + [0x00, 0x00, 0x10, 0x00, UInt8(senderKey.count)] + senderKey + sealed.ciphertext + sealed.tag
    }

    private static func contentKeys(
        shared: SharedSecret,
        salt: Data,
        receiverPublic: P256.KeyAgreement.PublicKey,
        senderPublic: P256.KeyAgreement.PublicKey,
        auth: Data) -> (SymmetricKey, Data)
    {
        let keyInfo = Data("WebPush: info\0".utf8) + receiverPublic.x963Representation + senderPublic.x963Representation
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32)
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        return (cek, nonce.withUnsafeBytes { Data($0) })
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }

    private static func nonce(_ base: Data, sequence: UInt64) -> Data {
        var nonce = [UInt8](base)
        for index in 0 ..< 8 {
            nonce[11 - index] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(index)))
        }
        return Data(nonce)
    }
}

extension Data {
    public init?(base64URL text: String) {
        var base64 = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        self.init(base64Encoded: base64)
    }

    public var base64URL: String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
