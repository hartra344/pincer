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
    public init() {}
    public func prepare(_ entries: [GatewayLogEntry], style: Style) async -> String {
        #if DEBUG
        probe?.record()
        #endif
        return switch style {
        case .formatted: GatewayLogs.copyText(entries)
        case .raw: GatewayLogs.rawText(entries)
        }
    }
}
