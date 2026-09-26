import Foundation
import UniformTypeIdentifiers

/// A file handed over by the share sheet, before it's sized for the Gateway.
public struct SharedFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let typeIdentifier: String?
    public let data: Data

    public init(name: String, typeIdentifier: String?, data: Data) {
        self.name = name
        self.typeIdentifier = typeIdentifier
        self.data = data
    }

    public var type: UTType? { self.typeIdentifier.flatMap(UTType.init) }
    public var isImage: Bool { self.type?.conforms(to: .image) == true }
}

/// What the share sheet handed over, reduced to what `chat.send` takes: text for the message
/// and files for attachments.
public struct SharedContent: Hashable, Sendable {
    public var texts: [String] = []
    public var urls: [URL] = []
    public var files: [SharedFile] = []
    /// Items that couldn't be read, shown to the user.
    public var problems: [String] = []

    public init(texts: [String] = [], urls: [URL] = [], files: [SharedFile] = [], problems: [String] = []) {
        self.texts = texts
        self.urls = urls
        self.files = files
        self.problems = problems
    }

    public var isEmpty: Bool { self.texts.isEmpty && self.urls.isEmpty && self.files.isEmpty }

    /// The message body: the user's note first, then shared text, then links. Links already
    /// present in the note or text (Safari often shares both) aren't repeated.
    public func message(note: String) -> String {
        var parts: [String] = []
        for text in [note] + self.texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !parts.contains(trimmed) { parts.append(trimmed) }
        }
        var links: [String] = []
        for url in self.urls {
            let link = url.absoluteString
            if links.contains(link) || parts.contains(where: { $0.contains(link) }) { continue }
            links.append(link)
        }
        if !links.isEmpty { parts.append(links.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// Sizes files for the Gateway: images are downscaled, other files must already fit.
    public func attachments(limits: UploadLimits) -> (attachments: [OutgoingAttachment], problems: [String]) {
        var attachments: [OutgoingAttachment] = []
        var problems: [String] = []
        for file in self.files {
            if file.isImage {
                if let prepared = ImageCodec.prepareForUpload(file.data, fileName: file.name, maxBytes: limits.imageBytes) {
                    attachments.append(prepared)
                } else {
                    problems.append("Couldn’t prepare \(file.name) for upload.")
                }
            } else if file.data.count > limits.fileBytes {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(limits.fileBytes), countStyle: .file)
                problems.append("\(file.name) is larger than the Gateway allows (\(limit)).")
            } else {
                attachments.append(OutgoingAttachment(
                    fileName: file.name,
                    mimeType: file.type?.preferredMIMEType ?? "application/octet-stream",
                    data: file.data))
            }
        }
        return (attachments, problems)
    }
}

/// Reads the share sheet's item providers into `SharedContent`. Main-actor bound because the
/// host's items aren't `Sendable`; the providers call back on their own queues.
@MainActor
public enum SharedContentLoader {
    /// Files past this are refused before they're read; share extensions have little memory.
    public nonisolated static let maxFileBytes = 50_000_000

    public static func load(_ items: [NSExtensionItem], maxFileBytes: Int = maxFileBytes) async -> SharedContent {
        var content = SharedContent()
        for item in items {
            if let text = item.attributedContentText?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.texts.append(text)
            }
            for provider in item.attachments ?? [] {
                await self.load(provider, into: &content, maxFileBytes: maxFileBytes)
            }
        }
        return content
    }

    public static func load(providers: [NSItemProvider], maxFileBytes: Int = maxFileBytes) async -> SharedContent {
        var content = SharedContent()
        for provider in providers {
            await self.load(provider, into: &content, maxFileBytes: maxFileBytes)
        }
        return content
    }

    private static func load(_ provider: NSItemProvider, into content: inout SharedContent, maxFileBytes: Int) async {
        let name = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await self.loadURL(provider, type: .fileURL) {
                self.append(self.readFile(url, maxFileBytes: maxFileBytes), to: &content)
                return
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await self.loadURL(provider, type: .url)
        {
            if url.isFileURL {
                self.append(self.readFile(url, maxFileBytes: maxFileBytes), to: &content)
            } else {
                content.urls.append(url)
            }
            return
        }
        if let type = self.firstType(of: provider, conformingTo: .image) {
            self.append(await self.loadFile(provider, type: type, name: name, maxFileBytes: maxFileBytes), to: &content)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await self.loadText(provider) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.texts.append(text) }
                return
            }
        }
        if let type = self.firstType(of: provider, conformingTo: .data) ?? self.firstType(of: provider, conformingTo: .item) {
            self.append(await self.loadFile(provider, type: type, name: name, maxFileBytes: maxFileBytes), to: &content)
            return
        }
        content.problems.append("\(name ?? "An item") can’t be shared to Pincer.")
    }

    private static func append(_ result: Result<SharedFile, ShareLoadError>, to content: inout SharedContent) {
        switch result {
        case let .success(file): content.files.append(file)
        case let .failure(error): content.problems.append(error.message)
        }
    }

    private static func firstType(of provider: NSItemProvider, conformingTo parent: UTType) -> UTType? {
        provider.registeredTypeIdentifiers.lazy.compactMap(UTType.init).first { $0.conforms(to: parent) }
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { @Sendable item, _ in
                let url: URL? = switch item {
                case let url as URL: url
                case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
                case let string as String: URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
                default: nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { @Sendable item, _ in
                let text: String? = switch item {
                case let string as String: string
                case let attributed as NSAttributedString: attributed.string
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// Copies the provider's file while it's still valid (only inside the callback).
    private static func loadFile(_ provider: NSItemProvider, type: UTType, name: String?, maxFileBytes: Int) async
        -> Result<SharedFile, ShareLoadError>
    {
        let fallbackName = self.fileName(name, type: type)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable url, _ in
                guard let url else {
                    continuation.resume(returning: .failure(ShareLoadError(message: "Couldn’t read \(fallbackName).")))
                    return
                }
                let result = self.readFile(url, maxFileBytes: maxFileBytes, type: type)
                    .map { SharedFile(name: name.map { self.fileName($0, type: type) } ?? $0.name, typeIdentifier: $0.typeIdentifier, data: $0.data) }
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated static func readFile(_ url: URL, maxFileBytes: Int, type: UTType? = nil) -> Result<SharedFile, ShareLoadError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true {
            return .failure(ShareLoadError(message: "\(name) is a folder; share files instead."))
        }
        if let size = values?.fileSize, size > maxFileBytes {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maxFileBytes), countStyle: .file)
            return .failure(ShareLoadError(message: "\(name) is too large to share (over \(limit))."))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ShareLoadError(message: "Couldn’t read \(name)."))
        }
        let resolved = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? type
        return .success(SharedFile(name: name, typeIdentifier: resolved?.identifier, data: data))
    }

    nonisolated static func fileName(_ suggested: String?, type: UTType) -> String {
        let base = suggested?.nilIfEmpty ?? (type.conforms(to: .image) ? "Shared Image" : "Shared File")
        guard (base as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }
}

struct ShareLoadError: Error, Sendable {
    let message: String
}
