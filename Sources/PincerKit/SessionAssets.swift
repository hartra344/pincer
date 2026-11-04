import Foundation

/// A file or image the agent sent in a chat: a `MEDIA:` line, a file or image block on an assistant
/// message, or an `artifacts.list` entry the cached transcript doesn't reach.
public struct SessionAsset: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case image(ImageRef)
        case file(FileRef)
    }

    /// The content's cache key, or the Gateway artifact id for a Gateway-only entry.
    public let id: String
    public var content: Content
    public var name: String
    public var mimeType: String?
    public var sizeBytes: Int?
    public var timestamp: Date?
    /// Transcript id of the assistant message that sent it; nil when only the Gateway listed it.
    public var messageId: String?

    public init(id: String, content: Content, name: String, mimeType: String? = nil, sizeBytes: Int? = nil,
                timestamp: Date? = nil, messageId: String? = nil) {
        self.id = id
        self.content = content
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.timestamp = timestamp
        self.messageId = messageId
    }

    /// A Gateway-listed artifact (`artifacts.list`), fetched with `artifacts.download`.
    public init(artifact: SessionArtifactItem) {
        let content: Content = artifact.type == "image"
            ? .image(ImageRef(artifactId: artifact.id, base64: nil, url: nil, mimeType: artifact.mimeType, alt: artifact.title,
                              width: nil, height: nil))
            : .file(FileRef(name: artifact.title, artifactId: artifact.id, mimeType: artifact.mimeType))
        self.init(id: "artifact:\(artifact.id)", content: content, name: artifact.title, mimeType: artifact.mimeType,
                  sizeBytes: artifact.sizeBytes)
    }

    public var isImage: Bool { if case .image = self.content { true } else { false } }

    public var artifactId: String? {
        switch self.content {
        case let .image(ref): ref.artifactId
        case let .file(ref): ref.artifactId
        }
    }

    /// The file to Quick Look or save, for either kind.
    public var fileRef: FileRef {
        switch self.content {
        case let .file(ref): ref
        case let .image(ref): FileRef(name: self.name, url: ref.url, artifactId: ref.artifactId, mimeType: ref.mimeType)
        }
    }

    /// Something can fetch its bytes (inline images always can).
    public var isDownloadable: Bool {
        switch self.content {
        case let .file(ref): ref.isDownloadable
        case let .image(ref): ref.artifactId != nil || ref.url != nil || ref.base64 != nil
        }
    }
}

public enum SessionAssetFilter: String, CaseIterable, Sendable {
    case all, files, images
}

/// Pure, `nonisolated` scanning and merging; run it off the main actor.
public enum SessionAssetScanner {
    /// Assets the assistant sent in `items` (oldest first), newest first. Only assistant messages
    /// count, as with upstream's `messageRole: "assistant"`: uploads and tool observations don't.
    /// A file sent twice is listed once, at its latest message.
    public static func scan(_ items: [ChatItem]) -> [SessionAsset] {
        var found: [SessionAsset] = []
        func add(_ asset: SessionAsset) { found.append(asset) }
        for item in items where item.role == .assistant && !item.isPending {
            for block in item.blocks {
                switch block {
                case let .text(text):
                    guard text.range(of: "MEDIA:", options: .caseInsensitive) != nil else { continue }
                    let parsed = MediaDirectives.extract(from: text)
                    for image in parsed.images { add(self.asset(image: image, item: item)) }
                    for file in parsed.files { add(self.asset(file: file, item: item)) }
                case let .image(ref): add(self.asset(image: ref, item: item))
                case let .file(ref): add(self.asset(file: ref, item: item))
                case .thinking, .toolCall: continue
                }
            }
        }
        var seen = Set<String>()
        return found.reversed().filter { seen.insert($0.id).inserted }
    }

    /// Adds `artifacts.list` entries to the transcript's assets. One that matches a transcript asset (by
    /// artifact id, else by kind and name, one to one) only fills in its size; the rest follow, as older.
    public static func merge(_ local: [SessionAsset], server: [SessionArtifactItem]) -> [SessionAsset] {
        guard !server.isEmpty else { return local }
        var merged = local
        var matched = Set<Int>()
        var byArtifact: [String: Int] = [:]
        for (i, asset) in local.enumerated() { if let id = asset.artifactId { byArtifact[id] = i } }
        var extra: [SessionAsset] = []
        for item in server {
            let isImage = item.type == "image"
            let hit = byArtifact[item.id].flatMap { matched.contains($0) ? nil : $0 }
                ?? local.indices.first { !matched.contains($0) && local[$0].isImage == isImage
                    && local[$0].name.caseInsensitiveCompare(item.title) == .orderedSame }
            if let hit {
                matched.insert(hit)
                if merged[hit].sizeBytes == nil { merged[hit].sizeBytes = item.sizeBytes }
                if merged[hit].mimeType == nil { merged[hit].mimeType = item.mimeType }
                continue
            }
            extra.append(SessionAsset(artifact: item))
        }
        return merged + extra
    }

    /// The assets a filter chip and search box leave, in order.
    public static func filter(_ assets: [SessionAsset], filter: SessionAssetFilter, search: String) -> [SessionAsset] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return assets.filter { asset in
            switch filter {
            case .all: break
            case .files: if asset.isImage { return false }
            case .images: if !asset.isImage { return false }
            }
            return query.isEmpty || asset.name.localizedCaseInsensitiveContains(query)
                || (asset.mimeType?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: Helpers

    private static func asset(image: ImageRef, item: ChatItem) -> SessionAsset {
        let name = image.alt.flatMap { $0.isEmpty ? nil : $0 } ?? image.url.flatMap(MediaDirectives.fileName) ?? L("Image")
        return SessionAsset(id: image.cacheKey, content: .image(image), name: name, mimeType: image.mimeType,
                            timestamp: item.timestamp, messageId: item.transcriptId)
    }

    private static func asset(file: FileRef, item: ChatItem) -> SessionAsset {
        SessionAsset(id: file.cacheKey, content: .file(file), name: file.name, mimeType: file.mimeType,
                     timestamp: item.timestamp, messageId: item.transcriptId)
    }
}
