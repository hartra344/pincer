import Foundation
@testable import PincerKit

@MainActor private func checkQuickLookOwnership(_ data: Data) async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickLookCheck-" + UUID().uuidString, isDirectory: true)
    do {
        let a = try await Task.detached { try FilePreviewFiles.write(data, name: "A.pdf", mimeType: "application/pdf", in: root) }.value
        let initial = await Task.detached { try? Data(contentsOf: a) }.value
        check(initial == data && !data.isEmpty, "ordinary actual preview retains exact nonempty bytes")
        let b = try await Task.detached { try FilePreviewFiles.write(data, name: "B.pdf", mimeType: "application/pdf", in: root) }.value
        let opened = await Task.detached { (try? Data(contentsOf: a), try? Data(contentsOf: b)) }.value
        check(opened.0 == data, "opening another preview retains first presented file")
        check(opened.1 == data && a != b, "second preview has exact bytes and distinct URL")
        #if DEBUG
        let probe = QuickLookCleanupProbe()
        await FilePreviewFiles.dismiss(a, in: root, probe: probe)
        check(probe.counts.main == 0 && probe.counts.worker == 1, "actual dismissal cleanup runs off Main")
        #else
        await FilePreviewFiles.dismiss(a, in: root)
        #endif
        let remaining = await Task.detached { try? Data(contentsOf: b) }.value
        check(remaining == data, "dismissing first preview retains second presented file")
        await FilePreviewFiles.dismiss(b, in: root)
        let closed = await Task.detached { !FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path) }.value
        check(closed, "current owner close awaits actual owned-directory cleanup")
    } catch { check(false, "actual owned Quick Look writes completed") }
    await Task.detached { FilePreviewFiles.clear(in: root) }.value
}

@MainActor func runQuickLookFileOwnershipChecks() async {
    let data = await Task.detached { DemoGateway.richRenderingPDF() }.value
    await checkQuickLookOwnership(data)
}

@MainActor func runDemoQuickLookFileOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    gateway.start(); gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:rate-limiter"
    let ready = await waitFor("Quick Look ownership Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil }
    check(ready, "genuine Demo attachment session ready"); guard ready else { return }
    let chat = gateway.chat(for: key); await chat.load()
    let files = chat.entries.flatMap { entry -> [FileRef] in
        if case let .assistant(turn) = entry { return turn.files }; return []
    }
    guard let pdf = files.first(where: { $0.mimeType == "application/pdf" && FilePreviewFiles.isPreviewable($0) }),
          let data = await gateway.files.data(for: pdf, sessionKey: key), data.prefix(5) == Data("%PDF-".utf8)
    else { check(false, "actual Demo PDF download has nonempty PDF bytes"); return }
    check(true, "actual artifacts.download supplies existing Demo PDF")
    await checkQuickLookOwnership(data)
}
