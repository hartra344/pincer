#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkActualExportFileStaging(name: String, data: Data) async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-check-staging-\(UUID())", isDirectory: true)
    let staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
    staging.probe = probe
    guard let first = await staging.prepare(name: name, data: data), let second = await staging.prepare(name: name, data: data) else {
        check(false, "actual Export file staging returns both real files")
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value; return
    }
    let bytes = await Task.detached { (try? Data(contentsOf: first), try? Data(contentsOf: second)) }.value
    check(bytes.0 == data && bytes.1 == data && !data.isEmpty, "actual Export files preserve exact nonempty bytes")
    check(first.lastPathComponent == name && second.lastPathComponent == name
          && first.deletingLastPathComponent() != second.deletingLastPathComponent()
          && first.deletingLastPathComponent().deletingLastPathComponent() == root,
          "actual Export staging uses exact filenames and unique owned directories")
    let counts = probe.snapshot()
    check(counts.mainDirectories == 0 && counts.mainWrites == 0, "actual Export temporary directory and atomic write stay off Main")
    check(counts.workerDirectories == 2 && counts.workerWrites == 2, "invocation probe observes both real directory/write operations")
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
@MainActor func runExportFileStagingChecks() async {
    let bytes = await Task.detached { Data("Exact file\né\n".utf8) }.value
    await checkActualExportFileStaging(name: "Export.txt", data: bytes)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-check-failure-\(UUID())", isDirectory: true)
    let blocker = root.appendingPathComponent("file")
    let created = await Task.detached {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([1]).write(to: blocker)
            return true
        } catch { return false }
    }.value
    guard created else {
        check(false, "actual failure fixture creates a blocking file")
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value; return
    }
    let blocked = await ExportFileStaging(root: blocker).prepare(name: "Export.txt", data: bytes)
    let missingParent = await ExportFileStaging(root: root).prepare(name: "missing/Export.txt", data: bytes)
    check(blocked == nil && missingParent == nil, "actual directory and atomic-write failures return no shared file")
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
@MainActor func runDemoExportFileStagingChecks() async {
    let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    guard await waitFor("Export file Demo source", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "actual Demo connects for Export file source"); return
    }
    guard let items = await gateway.chat(for: "agent:main:dashboard:tool-cards").exportItems(), !items.isEmpty else {
        check(false, "actual Demo exportItems supplies nonempty committed history"); return
    }
    let header = TranscriptExport.Header(title: "MCP servers", agentName: "Claw", exportedAt: Date(timeIntervalSince1970: 0))
    let source = await Task.detached {
        (TranscriptExport.fileName(title: header.title, format: .plainText),
         Data(TranscriptExport.plainText(items, header: header, options: .init(includeToolCalls: true)).utf8))
    }.value
    check(items.allSatisfy { !$0.isPending } && !source.1.isEmpty, "genuine Demo committed history creates an actual text export")
    await checkActualExportFileStaging(name: source.0, data: source.1)
}
#endif
