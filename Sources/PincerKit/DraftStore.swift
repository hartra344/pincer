import CryptoKit
import Foundation

/// Unsent composer contents for one chat.
public struct ComposerDraft: Hashable, Sendable {
    public var text: String
    public var attachments: [OutgoingAttachment]

    public init(text: String = "", attachments: [OutgoingAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool { self.text.isEmpty && self.attachments.isEmpty }
}

/// On-disk drafts, one folder per chat: `draft.json` plus one file per attachment, so typing never
/// rewrites attachment bytes. Drafts are user content, so they live in Application Support.
enum DraftStore {
    private struct Manifest: Codable {
        struct Attachment: Codable {
            var id: UUID
            var fileName: String
            var mimeType: String
        }

        var version = Self.currentVersion
        var text: String
        var attachments: [Attachment]

        static let currentVersion = 1
    }

    private static let manifestName = "draft.json"
    private static let attachmentExtension = "bin"

    /// `PINCER_DRAFTS_DIR` redirects drafts (checks); `PINCER_DRAFTS_DIR=off` disables them.
    static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["PINCER_DRAFTS_DIR"] {
            return override == "off" ? nil : URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Pincer/Drafts", directoryHint: .isDirectory)
    }

    static func directory(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        root?.appending(path: gatewayId.uuidString, directoryHint: .isDirectory)
    }

    static func directory(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) -> URL? {
        let digest = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return self.directory(gatewayId: gatewayId, root: root)?.appending(path: digest, directoryHint: .isDirectory)
    }

    static func load(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async -> ComposerDraft? {
        guard let directory = self.directory(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: directory.appending(path: Self.manifestName)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.version == Manifest.currentVersion
            else { return nil }
            let attachments = manifest.attachments.compactMap { attachment -> OutgoingAttachment? in
                let file = directory.appending(path: "\(attachment.id.uuidString).\(Self.attachmentExtension)")
                guard let bytes = try? Data(contentsOf: file) else { return nil }
                return OutgoingAttachment(id: attachment.id, fileName: attachment.fileName, mimeType: attachment.mimeType, data: bytes)
            }
            let draft = ComposerDraft(text: manifest.text, attachments: attachments)
            return draft.isEmpty ? nil : draft
        }.value
    }

    /// Writes `draft`, or removes the chat's folder when it's empty.
    static func save(_ draft: ComposerDraft, gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async {
        guard let directory = self.directory(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return }
        await Writer.shared.write(draft, to: directory)
    }

    static func remove(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async {
        await self.save(ComposerDraft(), gatewayId: gatewayId, sessionKey: sessionKey, root: root)
    }

    static func removeAll(gatewayId: UUID, root: URL? = Self.root) {
        guard let directory = self.directory(gatewayId: gatewayId, root: root) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private actor Writer {
        static let shared = Writer()

        func write(_ draft: ComposerDraft, to directory: URL) {
            let files = FileManager.default
            guard !draft.isEmpty else {
                try? files.removeItem(at: directory)
                return
            }
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                var kept: Set<String> = [DraftStore.manifestName]
                for attachment in draft.attachments {
                    let name = "\(attachment.id.uuidString).\(DraftStore.attachmentExtension)"
                    kept.insert(name)
                    let file = directory.appending(path: name)
                    // An attachment's bytes never change, so each is written once.
                    if !files.fileExists(atPath: file.path(percentEncoded: false)) {
                        try attachment.data.write(to: file, options: [.atomic, .completeFileProtection])
                    }
                }
                let manifest = Manifest(text: draft.text, attachments: draft.attachments.map {
                    Manifest.Attachment(id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType)
                })
                try JSONEncoder().encode(manifest)
                    .write(to: directory.appending(path: DraftStore.manifestName), options: [.atomic, .completeFileProtection])
                for name in (try? files.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [] where !kept.contains(name) {
                    try? files.removeItem(at: directory.appending(path: name))
                }
            } catch {
                // A lost draft only costs retyping.
            }
        }
    }
}
