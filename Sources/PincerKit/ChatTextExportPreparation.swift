import Foundation

package struct ChatTextExport: Sendable {
    package let name: String
    package let data: Data
}

#if DEBUG
/// Invocation-owned scalar observations; never retains transcript or output bytes.
package final class ChatTextExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var mainFormats = 0, workerFormats = 0, mainEncodes = 0, workerEncodes = 0
    package init() {}
    private func record(encoding: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard events < 16 else { return }; events += 1
        if encoding {
            if Thread.isMainThread { mainEncodes += 1 } else { workerEncodes += 1 }
        } else {
            if Thread.isMainThread { mainFormats += 1 } else { workerFormats += 1 }
        }
    }
    func formatting() { record(encoding: false) }
    func encoding() { record(encoding: true) }
    package func snapshot() -> (mainFormats: Int, workerFormats: Int, mainEncodes: Int, workerEncodes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (mainFormats, workerFormats, mainEncodes, workerEncodes)
    }
}
#endif

/// The actual Markdown/plain-text preparation used by Export Chat. Neutral extraction keeps Main execution.
@MainActor package final class ChatTextExportPreparation {
    #if DEBUG
    package var probe: ChatTextExportProbe?
    #endif
    package init() {}
    package func prepare(_ items: [ChatItem], format: TranscriptExport.Format,
                         options: TranscriptExport.Options, header: TranscriptExport.Header) async -> ChatTextExport? {
        guard format != .pdf else { return nil }
        #if DEBUG
        probe?.formatting()
        #endif
        let text: String
        switch format {
        case .markdown: text = TranscriptExport.markdown(items, header: header, options: options)
        case .plainText: text = TranscriptExport.plainText(items, header: header, options: options)
        case .pdf: return nil
        }
        #if DEBUG
        probe?.encoding()
        #endif
        let data = Data(text.utf8)
        guard !data.isEmpty else { return nil }
        return ChatTextExport(name: TranscriptExport.fileName(title: header.title, format: format), data: data)
    }
}
