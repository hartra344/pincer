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
    #endif
    #if DEBUG
    package private(set) var workerTask: Task<Void, Never>?
    package var requestID: UUID { current }
    package var didPrepare: (@Sendable () async -> Void)?
    #endif
    private struct Job {
        let id: UUID
        let entries: [GatewayLogEntry]
        let style: Style
        let completion: @MainActor (String?) -> Void
    }
    private var current = UUID()
    private var active: UUID?
    private var pending: Job?
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
        current = UUID()
        let displaced = pending; pending = nil
        displaced?.completion(nil)
    }

    private func enqueue(_ entries: [GatewayLogEntry], style: Style,
                         completion: @escaping @MainActor (String?) -> Void) {
        let id = UUID(); current = id
        let job = Job(id: id, entries: entries, style: style, completion: completion)
        if active != nil {
            let displaced = pending; pending = job
            displaced?.completion(nil)
        } else { start(job) }
    }

    private func start(_ job: Job) {
        active = job.id
        #if DEBUG
        let probe = self.probe, didPrepare = self.didPrepare
        #endif
        let entries = job.entries, style = job.style
        let running = Task {
            let text = await Task.detached(priority: .userInitiated) {
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
            }.value
            guard active == job.id else { return }
            let accepted = current == job.id
            active = nil
            #if DEBUG
            workerTask = nil
            #endif
            let next = pending; pending = nil
            if let next { start(next) }
            job.completion(accepted ? text : nil)
        }
        #if DEBUG
        workerTask = running
        #endif
    }
}
