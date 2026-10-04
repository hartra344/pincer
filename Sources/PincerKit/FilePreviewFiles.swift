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
    /// fresh folder inside `root`, retaining previews owned by other windows.
    public static func write(_ data: Data, name: String, mimeType: String?, in root: URL = Self.root) throws -> URL {
        let manager = FileManager.default
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(self.fileName(name, mimeType: mimeType), isDirectory: false)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            return url
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    /// Removes only the unique directory owned by this preview, after actual disk cleanup finishes.
    #if DEBUG
    package static func dismiss(_ url: URL, in root: URL = Self.root, probe: QuickLookCleanupProbe? = nil) async {
        await Task.detached { probe?.record(); Self.removeOwnedDirectory(url, root: root) }.value
    }
    #else
    package static func dismiss(_ url: URL, in root: URL = Self.root) async {
        await Task.detached { Self.removeOwnedDirectory(url, root: root) }.value
    }
    #endif

    private static func removeOwnedDirectory(_ url: URL, root: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
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
            // Reserve at least one visible stem character and the extension separator.
            // A suffix alone can exceed the entire filename budget.
            let boundedExtension = String(ext.prefix(118))
            let suffix = boundedExtension.isEmpty ? "" : "." + boundedExtension
            base = String(base.prefix(120 - suffix.count)) + suffix
        }
        return base
    }
}

#if DEBUG
/// Per-call scalar diagnostics only; no URLs or file contents retained.
package final class QuickLookCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0, worker = 0
    package init() {}
    fileprivate func record() {
        lock.lock(); defer { lock.unlock() }
        guard main + worker < 16 else { return }
        if Thread.isMainThread { main += 1 } else { worker += 1 }
    }
    package var counts: (main: Int, worker: Int) {
        lock.lock(); defer { lock.unlock() }; return (main, worker)
    }
}
#endif
