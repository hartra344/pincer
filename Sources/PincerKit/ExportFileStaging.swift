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

/// Actual temporary-file staging used by iOS Export. Neutral extraction retains synchronous Main I/O.
@MainActor package final class ExportFileStaging {
    private let root: URL?
    #if DEBUG
    package var probe: ExportFileStagingProbe?
    #endif
    package init(root: URL? = nil) { self.root = root }
    /// Async preparation entry point preserves the same actual synchronous implementation before the worker fix.
    package func prepare(name: String, data: Data) async -> URL? { self.write(name: name, data: data) }
    package func write(name: String, data: Data) -> URL? {
        let folder = (root ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            #if DEBUG
            probe?.record(writing: false)
            #endif
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #if DEBUG
            probe?.record(writing: true)
            #endif
            try data.write(to: url, options: .atomic)
        } catch { return nil }
        return url
    }
}
