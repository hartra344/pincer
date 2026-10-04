import Foundation
@testable import PincerKit

@MainActor func runFilePreviewLongExtensionChecks() async {
    let names = await Task.detached {
        [119, 120, 130].map { FilePreviewFiles.fileName("a." + String(repeating: "x", count: $0), mimeType: nil) }
    }.value
    check(names.allSatisfy { !$0.isEmpty && $0.count <= 120 && !$0.contains("/") && !$0.hasPrefix(".") && !($0 as NSString).deletingPathExtension.isEmpty }, "actual Quick Look extension boundaries stay within one bounded filename without trapping")
}

/// Actual Demo PDF download; only the filename input below is a LOCAL safety fixture.
@MainActor func runDemoFilePreviewLongExtensionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let key = "agent:main:dashboard:rate-limiter"
    let connected = await waitFor("Quick Look filename Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil }
    check(connected, "genuine Demo attachment session is ready")
    guard connected else { return }
    let chat = gateway.chat(for: key)
    await chat.load()
    let files = chat.entries.flatMap { entry -> [FileRef] in
        if case let .assistant(turn) = entry { return turn.files }
        return []
    }
    guard let pdf = files.first(where: { $0.mimeType == "application/pdf" }), FilePreviewFiles.isPreviewable(pdf) else {
        check(false, "actual Demo history contains downloadable PDF"); return
    }
    guard let data = await gateway.files.data(for: pdf, sessionKey: key) else {
        check(false, "actual Demo PDF download completes"); return
    }
    let result = await Task.detached { () -> Bool in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PincerQuickLookExtension-" + UUID().uuidString, isDirectory: true)
        defer { FilePreviewFiles.clear(in: root) }
        guard data.prefix(5) == Data("%PDF-".utf8),
              let ordinary = try? FilePreviewFiles.write(data, name: pdf.name, mimeType: pdf.mimeType, in: root),
              ordinary.lastPathComponent == "rate-limiter-design.pdf", (try? Data(contentsOf: ordinary)) == data,
              let local = try? FilePreviewFiles.write(data, name: "attachment." + String(repeating: "x", count: 130), mimeType: pdf.mimeType, in: root)
        else { return false }
        return local.lastPathComponent.count <= 120 && !local.lastPathComponent.hasPrefix(".")
            && !(local.lastPathComponent as NSString).deletingPathExtension.isEmpty && (try? Data(contentsOf: local)) == data
            && local.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }.value
    check(result, "real downloaded PDF retains exact bytes in task-owned Quick Look path with explicit LOCAL long-extension filename input")
}

@MainActor func runFilePreviewExtensionPolicyChecks() async {
    let value = await Task.detached {
        FilePreviewFiles.fileName("attachment." + String(repeating: "x", count: 130), mimeType: nil)
    }.value
    check(value == "a." + String(repeating: "x", count: 118), "oversized Quick Look extension retains one visible stem and bounded suffix")
}
