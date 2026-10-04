import Foundation

#if DEBUG
/// Invocation-owned scalar observations at the actual directory and atomic-write boundaries.
package final class ExportFileStagingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var mainDirectories = 0, workerDirectories = 0, mainWrites = 0, workerWrites = 0
    package init() {}
    func record(writing: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard events < 16 else { return }; events += 1
        if writing {
            if Thread.isMainThread { mainWrites += 1 } else { workerWrites += 1 }
        } else {
            if Thread.isMainThread { mainDirectories += 1 } else { workerDirectories += 1 }
        }
    }
    package func snapshot() -> (mainDirectories: Int, workerDirectories: Int, mainWrites: Int, workerWrites: Int) {
        lock.lock(); defer { lock.unlock() }
        return (mainDirectories, workerDirectories, mainWrites, workerWrites)
    }
}
#endif

/// Actual temporary-file staging used by iOS Export. Each invocation awaits its real worker.
@MainActor package final class ExportFileStaging {
    private struct Input: Sendable {
        let root: URL?
        let name: String
        let data: Data
        #if DEBUG
        let probe: ExportFileStagingProbe?
        let afterWrite: (@Sendable (URL?) async -> Void)?
        #endif
    }
    private let root: URL?
    #if DEBUG
    package var probe: ExportFileStagingProbe?
    package var afterWrite: (@Sendable (URL?) async -> Void)?
    #endif
    package init(root: URL? = nil) { self.root = root }
    package func prepare(name: String, data: Data) async -> URL? {
        guard !Task.isCancelled else { return nil }
        #if DEBUG
        let input = Input(root: root, name: name, data: data, probe: probe, afterWrite: afterWrite)
        #else
        let input = Input(root: root, name: name, data: data)
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            let result = Self.write(input)
            #if DEBUG
            await input.afterWrite?(result)
            #endif
            return result
        }
        let result = await worker.value
        guard !Task.isCancelled else {
            if let result { await Self.discard(result) }
            return nil
        }
        return result
    }
    /// Removes only the unique directory belonging to this unused result, never older exports.
    package nonisolated static func discard(_ url: URL) async {
        await Task.detached { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }.value
    }
    private nonisolated static func write(_ input: Input) -> URL? {
        let folder = (input.root ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(input.name)
        do {
            #if DEBUG
            input.probe?.record(writing: false)
            #endif
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #if DEBUG
            input.probe?.record(writing: true)
            #endif
            try input.data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return url
    }
}
