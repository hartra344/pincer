#if DEBUG
import Foundation
import PincerKit

@MainActor private final class ExportFileCompletedCheckGate {
    var entered = false, finished = false, open = false
    var url: URL?
    private var held: CheckedContinuation<Void, Never>?
    func hold(_ url: URL?) async {
        self.url = url; entered = true
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { held = continuation }
        }
        finished = true
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor func runExportFileStagingOwnershipChecks() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-owned-check-\(UUID())", isDirectory: true)
    let gate = ExportFileCompletedCheckGate(), staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
    staging.probe = probe; staging.afterWrite = { await gate.hold($0) }
    let task = Task { await staging.prepare(name: "Canceled.txt", data: Data([1, 2, 3])) }
    guard await waitFor("actual completed Export write", timeout: 15, { gate.entered }), let written = gate.url else {
        check(false, "actual Export write completes before cancellation")
        task.cancel(); gate.release(); _ = await task.value
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value; return
    }
    let exact = await Task.detached { try? Data(contentsOf: written) }.value
    check(exact == Data([1, 2, 3]), "held actual Export worker has written exact bytes")
    task.cancel(); gate.release()
    let result = await task.value
    let removed = await Task.detached { !FileManager.default.fileExists(atPath: written.deletingLastPathComponent().path) }.value
    check(result == nil && gate.finished && removed, "canceled consumer awaits actual worker and removes its unused directory")
    let counts = probe.snapshot()
    check(counts.mainDirectories == 0 && counts.mainWrites == 0 && counts.workerDirectories == 1 && counts.workerWrites == 1,
          "canceled real Export performs one worker write and no Main I/O")
    staging.afterWrite = nil
    let before = probe.snapshot()
    let refused = Task { await staging.prepare(name: "Not-admitted.txt", data: Data([4])) }; refused.cancel()
    let refusedResult = await refused.value, after = probe.snapshot()
    check(refusedResult == nil && before.workerDirectories == after.workerDirectories && before.workerWrites == after.workerWrites,
          "pre-canceled Export admits no extra worker or file")
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
#endif
