import Foundation
import UniformTypeIdentifiers

/// Files handed to Quick Look: a downloaded attachment is written to its own folder under a
/// private temporary directory, named so Quick Look picks the right viewer, and removed again when
/// the preview closes.
public enum FilePreviewFiles {
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PincerQuickLook", isDirectory: true)
    }

    /// Attachments Quick Look shows. Text and code already expand inline in the transcript.
    public static func isPreviewable(_ file: FileRef) -> Bool {
        file.isDownloadable && !file.isText
    }

    /// Writes `data` as `name` (made safe, with an extension from `mimeType` when it has none) in a
    /// fresh folder inside `root`, replacing earlier previews.
    public static func write(_ data: Data, name: String, mimeType: String?, in root: URL = Self.root) throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(self.fileName(name, mimeType: mimeType), isDirectory: false)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }

    /// Removes every preview file.
    public static func clear(in root: URL = Self.root) {
        try? FileManager.default.removeItem(at: root)
    }

    /// A single path component: no folders, no leading dot, at most 120 characters, and an
    /// extension that matches the MIME type when the name has none.
    public static func fileName(_ name: String, mimeType: String?) -> String {
        var base = (name as NSString).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty || base == ".." { base = "file" }
        var ext = (base as NSString).pathExtension
        if ext.isEmpty, let mime = mimeType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           let preferred = UTType(mimeType: mime)?.preferredFilenameExtension
        {
            base += "." + preferred
            ext = preferred
        }
        if base.count > 120 {
            let suffix = ext.isEmpty ? "" : "." + ext
            base = String(base.prefix(120 - suffix.count)) + suffix
        }
        return base
    }
}
