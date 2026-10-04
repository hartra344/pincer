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

/// Exact text Export preparation. One worker per invocation; source/output storage is input-proportional.
@MainActor package final class ChatTextExportPreparation {
    private struct Input: Sendable {
        let items: [ChatItem]
        let format: TranscriptExport.Format
        let options: TranscriptExport.Options
        let header: TranscriptExport.Header
        #if DEBUG
        let probe: ChatTextExportProbe?
        let afterPreparation: (@Sendable () async -> Void)?
        #endif
    }
    #if DEBUG
    package var probe: ChatTextExportProbe?
    /// Holds the actual completed computation before its worker returns.
    package var afterPreparation: (@Sendable () async -> Void)?
    #endif
    package init() {}
    package func prepare(_ items: [ChatItem], format: TranscriptExport.Format,
                         options: TranscriptExport.Options, header: TranscriptExport.Header) async -> ChatTextExport? {
        guard format != .pdf, !Task.isCancelled else { return nil }
        #if DEBUG
        let input = Input(items: items, format: format, options: options, header: header,
                          probe: probe, afterPreparation: afterPreparation)
        #else
        let input = Input(items: items, format: format, options: options, header: header)
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            let output = Self.build(input)
            #if DEBUG
            await input.afterPreparation?()
            #endif
            return output
        }
        // A canceled consumer still awaits the actual worker; it cannot release work early.
        let output = await worker.value
        guard !Task.isCancelled else { return nil }
        return output
    }
    private nonisolated static func build(_ input: Input) -> ChatTextExport? {
        #if DEBUG
        input.probe?.formatting()
        #endif
        let text: String
        switch input.format {
        case .markdown: text = TranscriptExport.markdown(input.items, header: input.header, options: input.options)
        case .plainText: text = TranscriptExport.plainText(input.items, header: input.header, options: input.options)
        case .pdf: return nil
        }
        #if DEBUG
        input.probe?.encoding()
        #endif
        let data = Data(text.utf8)
        guard !data.isEmpty else { return nil }
        return ChatTextExport(name: TranscriptExport.fileName(title: input.header.title, format: input.format), data: data)
    }
}
