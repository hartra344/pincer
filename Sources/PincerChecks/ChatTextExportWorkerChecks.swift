#if DEBUG
import Foundation
import PincerKit

@MainActor func runChatTextExportWorkerChecks() async {
    let items = await Task.detached {
        [ChatItem(id: "assistant", role: .assistant, blocks: [.thinking("PRIVATE THOUGHT"),
            .toolCall(id: "tool", name: "exec", arguments: "{}"), .text("Visible reply")])]
    }.value
    let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
    preparation.probe = probe
    for format in [TranscriptExport.Format.markdown, .plainText] {
        guard let output = await preparation.prepare(items, format: format, options: .init(), header: .init(title: "Options")),
              let text = String(data: output.data, encoding: .utf8) else {
            check(false, "actual text Export produces UTF8 output"); return
        }
        check(text.contains("Visible reply") && !text.contains("PRIVATE THOUGHT") && !text.contains("exec"),
              "actual text Export honors thinking/tool exclusions")
    }
    let before = probe.snapshot()
    let unsupported = await preparation.prepare(items, format: .pdf, options: .init(), header: .init(title: "PDF"))
    let after = probe.snapshot()
    check(unsupported == nil && before.workerFormats == 2 && before.workerEncodes == 2
          && after.workerFormats == before.workerFormats && after.workerEncodes == before.workerEncodes,
          "PDF remains outside the actual text Export worker")
    check(after.mainFormats == 0 && after.mainEncodes == 0, "text Export option preparation adds no Main format/encoding work")
}
#endif
