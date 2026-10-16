import Foundation
import Observation

/// One open file of the Files tab (`sessions.files.get`, `sessions.files.set`). Created by
/// `SessionFilesModel.open(path:)`; hold it in `@State`. Parsing runs off-main.
@MainActor
@Observable
public final class SessionFileDocument {
    public enum Phase: Equatable, Sendable {
        case loading
        case text
        case image
        /// Binary or otherwise not previewable (`previewKind: "unsupported"`).
        case unsupported
        /// Over the 256 KiB cap; `size` when the Gateway said.
        case tooLarge(size: Int?)
        case missing
        case failed(String)
    }

    public enum SaveResult: Equatable, Sendable {
        case saved
        /// The file changed on the Gateway since it was read. Offer Reload, Overwrite or Cancel.
        case conflict(currentHash: String?)
        case missing
        case tooLarge
        case failed(String)
    }

    public let path: String
    public let name: String
    public private(set) var phase = Phase.loading
    /// The file's text as last read from or saved to the Gateway.
    public private(set) var content = ""
    /// `content` split into lines (normalised to `\n`), computed off-main. Readers use this instead of splitting.
    public private(set) var lines: [String] = []
    /// The file's own separator (`"\n"`, `"\r\n"` or `"\r"`). `content` is always `\n`; saves restore this.
    public private(set) var lineSeparator = "\n"
    /// The Gateway's hash of `content` (SHA-256 hex); the `expectedHash` of the next save.
    public private(set) var hash: String?
    /// Set when `phase == .image`.
    public private(set) var image: ImageRef?
    public private(set) var mimeType: String?
    /// The text has mixed line endings: shown but never editable, so a save can't rewrite them.
    public private(set) var hasMixedLineEndings = false
    public private(set) var isSaving = false

    /// Editable text: has a hash, uniform line endings, and the connection has admin and `sessions.files.set`.
    public var isEditable: Bool {
        self.phase == .text && self.hash != nil && !self.hasMixedLineEndings && (self.model?.canEdit ?? false)
    }

    @ObservationIgnored private let model: SessionFilesModel?
    @ObservationIgnored private var loadGeneration = 0

    init(path: String, name: String, model: SessionFilesModel) {
        self.path = path
        self.name = name
        self.model = model
        Task { await self.reload() }
    }

    /// Fetches the file again, discarding unsaved edits (the UI owns the draft text).
    public func reload() async {
        guard let model else { return }
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.phase = .loading
        let params = JSONValue.object(model.fileParams(path: self.path))
        let request = model.request
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, SessionFilesError> in
            do { return .success(Loaded(try await request(SessionFilesModel.getMethod, params))) } catch {
                return .failure(SessionFilesError.map(error))
            }
        }.value
        guard generation == self.loadGeneration else { return }
        switch outcome {
        case let .success(loaded): self.apply(loaded)
        case .failure(.notFound): self.phase = .missing
        case let .failure(.tooLarge(size)): self.phase = .tooLarge(size: size)
        case let .failure(failure): self.phase = .failed(failure.message)
        }
    }

    /// Saves `text` against the hash it was read with. A conflict leaves the document untouched.
    public func save(_ text: String) async -> SaveResult {
        await self.write(text, expectedHash: self.hash)
    }

    /// Overwrites the Gateway's newer version after a conflict: re-reads for its current hash, then saves.
    public func overwrite(_ text: String) async -> SaveResult {
        guard let model else { return .failed(SessionFilesError.notConnected.message) }
        let params = JSONValue.object(model.fileParams(path: self.path))
        let request = model.request
        let latest = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, SessionFilesError> in
            do { return .success(Loaded(try await request(SessionFilesModel.getMethod, params))) } catch {
                return .failure(SessionFilesError.map(error))
            }
        }.value
        switch latest {
        case let .success(loaded):
            guard let currentHash = loaded.hash else { return .failed(L("This file can't be overwritten.")) }
            return await self.write(text, expectedHash: currentHash)
        case .failure(.notFound): return .missing
        case let .failure(failure): return .failed(failure.message)
        }
    }

    private func write(_ text: String, expectedHash: String?) async -> SaveResult {
        guard let model, let expectedHash, !self.isSaving else { return .failed(L("This file can't be edited.")) }
        if Self.serialize(text, separator: self.lineSeparator).utf8.count > SessionFilesModel.maxPreviewBytes { return .tooLarge }
        self.isSaving = true
        defer { self.isSaving = false }
        var params = model.fileParams(path: self.path)
        let wire = Self.serialize(text, separator: self.lineSeparator)
        params["content"] = .string(wire)
        params["expectedHash"] = .string(expectedHash)
        let payload = JSONValue.object(params)
        let request = model.request
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String?, SessionFilesError> in
            do { return .success(Loaded(try await request(SessionFilesModel.setMethod, payload)).hash) } catch {
                return .failure(SessionFilesError.map(error))
            }
        }.value
        switch outcome {
        case let .success(newHash):
            self.content = Self.normalize(text)
            self.lines = Self.splitLines(self.content)
            self.hash = newHash ?? self.hash
            model.fileSaved()
            return .saved
        case let .failure(.conflict(currentHash)): return .conflict(currentHash: currentHash)
        case .failure(.notFound): return .missing
        case .failure(.tooLarge): return .tooLarge
        case let .failure(failure): return .failed(failure.message)
        }
    }

    /// Upstream's `detectLineSeparator`: the first line break's kind, `\n` when there is none.
    nonisolated static func detectLineSeparator(_ text: String) -> String {
        var sawCR = false
        for byte in text.utf8 {
            if sawCR { return byte == 0x0A ? "\r\n" : "\r" }
            if byte == 0x0A { return "\n" }
            if byte == 0x0D { sawCR = true }
        }
        return sawCR ? "\r" : "\n"
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.utf8.contains(0x0D) ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
    }

    nonisolated static func serialize(_ text: String, separator: String) -> String {
        let normal = Self.normalize(text)
        return separator == "\n" ? normal : normal.replacingOccurrences(of: "\n", with: separator)
    }

    nonisolated static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func apply(_ loaded: Loaded) {
        self.mimeType = loaded.mimeType
        self.hash = loaded.hash
        switch loaded.kind {
        case .text:
            self.content = loaded.text ?? ""
            self.lines = loaded.lines
            self.lineSeparator = loaded.separator
            self.hasMixedLineEndings = loaded.mixedLineEndings
            self.image = nil
            self.phase = .text
        case .image:
            self.image = loaded.image
            self.phase = loaded.image == nil ? .unsupported : .image
        case .unsupported: self.phase = .unsupported
        case .missing: self.phase = .missing
        case let .tooLarge(size): self.phase = .tooLarge(size: size)
        }
    }

    /// A parsed `sessions.files.get` / `set` reply (`{sessionKey, root?, file}`).
    struct Loaded: Sendable {
        enum Kind: Sendable { case text, image, unsupported, missing, tooLarge(Int?) }

        var kind = Kind.unsupported
        var text: String?
        var hash: String?
        var mimeType: String?
        var image: ImageRef?
        var mixedLineEndings = false
        var separator = "\n"
        var lines: [String] = []

        init(_ value: JSONValue) {
            let file = value["file"] ?? value
            self.hash = file["hash"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            self.mimeType = file["mimeType"]?.string
            if file["missing"]?.bool == true {
                self.kind = .missing
                return
            }
            switch file["previewKind"]?.string {
            case "text":
                self.kind = .text
                let raw = file["content"]?.string ?? ""
                if file["contentEncoding"]?.string == "base64" {
                    self.text = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    self.text = raw
                }
                let original = self.text ?? ""
                self.mixedLineEndings = Self.hasMixedLineEndings(original)
                self.separator = SessionFileDocument.detectLineSeparator(original)
                let normalized = SessionFileDocument.normalize(original)
                self.text = normalized
                self.lines = SessionFileDocument.splitLines(normalized)
            case "image":
                if file["contentEncoding"]?.string == "base64", let raw = file["content"]?.string, !raw.isEmpty {
                    self.kind = .image
                    self.image = ImageRef(artifactId: nil, base64: raw, url: nil, mimeType: file["mimeType"]?.string,
                                          alt: file["name"]?.string, width: nil, height: nil)
                }
            default:
                // Over 256 KiB a text file carries no previewKind and no content.
                if file["content"] == nil, let size = file["size"]?.int, size > SessionFilesModel.maxPreviewBytes {
                    self.kind = .tooLarge(size)
                }
            }
        }

        /// Upstream's `hasUniformLineEndings`: more than one distinct line ending kind blocks editing.
        static func hasMixedLineEndings(_ text: String) -> Bool {
            var kinds = Set<UInt8>()
            var previousCR = false
            for byte in text.utf8 {
                if previousCR {
                    kinds.insert(byte == 0x0A ? 2 : 1)
                    previousCR = false
                    if byte == 0x0A { continue }
                }
                if byte == 0x0D { previousCR = true } else if byte == 0x0A { kinds.insert(0) }
            }
            if previousCR { kinds.insert(1) }
            return kinds.count > 1
        }
    }
}
