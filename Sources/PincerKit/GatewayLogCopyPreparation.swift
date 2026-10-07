import Foundation

#if DEBUG
package final class GatewayLogCopyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0, worker = 0
    package init() {}
    func record() { lock.withLock {
        guard main + worker < 32 else { return }
        if Thread.isMainThread { main += 1 } else { worker += 1 }
    } }
    package func snapshot() -> (main: Int, worker: Int) { lock.withLock { (main, worker) } }
}
#endif

/// Preparation used only by explicit log Copy buttons; it does not write a clipboard.
@MainActor public final class GatewayLogCopyPreparation {
    public enum Style: Sendable { case formatted, raw }
    #if DEBUG
    package var probe: GatewayLogCopyProbe?
    package var workerTask: Task<Void, Never>? { preparer.workerTask }
    package private(set) var requestID = UUID()
    package var didPrepare: (@Sendable () async -> Void)?
    #endif
    private let preparer = LatestWinsPreparer<String>()
    public init() {}

    public func prepare(_ entries: [GatewayLogEntry], style: Style) async -> String {
        await withCheckedContinuation { continuation in
            enqueue(entries, style: style) { continuation.resume(returning: $0 ?? "") }
        }
    }

    /// Captures intent synchronously; stale jobs never call the clipboard publisher.
    public func request(_ entries: [GatewayLogEntry], style: Style,
                        publish: @escaping @MainActor (String) -> Void) {
        enqueue(entries, style: style) { if let text = $0 { publish(text) } }
    }

    public func invalidate() {
        #if DEBUG
        requestID = UUID()
        #endif
        preparer.invalidate()
    }

    private func enqueue(_ entries: [GatewayLogEntry], style: Style,
                         completion: @escaping @MainActor (String?) -> Void) {
        #if DEBUG
        requestID = UUID()
        #endif
        preparer.submit(start: {
            #if DEBUG
            let probe = self.probe, didPrepare = self.didPrepare
            #endif
            return {
                #if DEBUG
                probe?.record()
                #endif
                let text = switch style {
                case .formatted: GatewayLogs.copyText(entries)
                case .raw: GatewayLogs.rawText(entries)
                }
                #if DEBUG
                await didPrepare?()
                #endif
                return text
            }
        }, completion: completion)
    }
}
