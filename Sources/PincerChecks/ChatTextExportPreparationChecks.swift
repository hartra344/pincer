#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private func checkChatTextExportPreparation(_ items: [ChatItem]) async {
    let header = TranscriptExport.Header(title: "Export fixture", agentName: "Scout", exportedAt: Date(timeIntervalSince1970: 0))
    let options = TranscriptExport.Options(includeThinking: true, includeToolCalls: true)
    for format in [TranscriptExport.Format.markdown, .plainText] {
        let expected = await Task.detached {
            Data((format == .markdown ? TranscriptExport.markdown(items, header: header, options: options)
                  : TranscriptExport.plainText(items, header: header, options: options)).utf8)
        }.value
        let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
        preparation.probe = probe
        guard let file = await preparation.prepare(items, format: format, options: options, header: header) else {
            check(false, "actual text export prepares a nonempty file"); return
        }
        check(file.data == expected && !file.data.isEmpty, "actual text export preserves full format/options/header/UTF8 bytes")
        check(file.name == "Export fixture.\(format.fileExtension)", "actual text export prepares the current filename")
        let counts = probe.snapshot()
        check(counts.mainFormats == 0 && counts.mainEncodes == 0, "actual chat Export formatting and UTF8 encoding stay off Main")
        check(counts.workerFormats == 1 && counts.workerEncodes == 1, "invocation probe observes both real preparation boundaries")
    }
}
@MainActor func runChatTextExportPreparationChecks() async {
    let items = await Task.detached {
        [ChatItem(id: "user", role: .user, blocks: [.text("Hello\nworld")]),
         ChatItem(id: "assistant", role: .assistant, blocks: [.thinking("Consider it"), .text("Reply é")])]
    }.value
    await checkChatTextExportPreparation(items)
}
@MainActor func runDemoChatTextExportPreparationChecks() async {
    let (defaults, suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    guard await waitFor("actual chat Export Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "actual Demo connects for Export history"); return
    }
    guard let items = await gateway.chat(for: "agent:main:dashboard:tool-cards").exportItems(), !items.isEmpty else {
        check(false, "actual Demo exportItems supplies full nonempty committed history"); return
    }
    check(items.allSatisfy { !$0.isPending }, "actual Demo Export history excludes pending drafts")
    await checkChatTextExportPreparation(items)
}
#endif
