import Foundation

/// Exact raw log bytes and filename handed to the platform document exporter.
public struct GatewayLogExport: Sendable {
    public let name: String
    public let data: Data
}

#if DEBUG
/// Per-preparation, payload-free observation of actual join and encoding work.
package final class GatewayLogExportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0
    private var mainJoins = 0, workerJoins = 0, mainEncodes = 0, workerEncodes = 0
    package init() {}
    func record(encoding: Bool) {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.events < 32 else { return }
        self.events += 1
        if encoding {
            if Thread.isMainThread { self.mainEncodes += 1 } else { self.workerEncodes += 1 }
        } else {
            if Thread.isMainThread { self.mainJoins += 1 } else { self.workerJoins += 1 }
        }
    }
    package func snapshot() -> (mainJoins: Int, workerJoins: Int, mainEncodes: Int, workerEncodes: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        return (self.mainJoins, self.workerJoins, self.mainEncodes, self.workerEncodes)
    }
}
#endif

@MainActor
public final class GatewayLogExportPreparation {
    private let preparer = LatestWinsPreparer<GatewayLogExport>()
    #if DEBUG
    package var probe: GatewayLogExportProbe?
    /// Holds actual completed preparation, without substituting a prepared result.
    package var afterPreparation: (@Sendable () async -> Void)?
    package var pendingCount: Int { self.preparer.pendingCount }
    package var activeCount: Int { self.preparer.activeCount }
    #endif
    public init() {}

    /// UI admission retains one active source and at most one replaceable latest source.
    /// A displaced pending request is dropped silently.
    public func request(_ entries: [GatewayLogEntry], gatewayName: String,
                        publish: @escaping @MainActor (GatewayLogExport) -> Void) {
        self.preparer.submit(start: { self.worker(entries, gatewayName: gatewayName, date: Date(), timeZone: .current) },
                             completion: { if let output = $0 { publish(output) } })
    }

    /// Disappearance invalidates publication. The active lease stays owned until its worker exits.
    public func cancel() {
        self.preparer.invalidate()
    }

    package func waitForIdle() async {
        await self.preparer.waitForIdle()
    }

    /// The exact worker used by admitted Gateway Logs Export requests.
    public func prepare(_ entries: [GatewayLogEntry], gatewayName: String,
                        date: Date = Date(), timeZone: TimeZone = .current) async -> GatewayLogExport {
        await self.worker(entries, gatewayName: gatewayName, date: date, timeZone: timeZone)()
    }

    private func worker(_ entries: [GatewayLogEntry], gatewayName: String,
                        date: Date, timeZone: TimeZone) -> @Sendable () async -> GatewayLogExport {
        #if DEBUG
        let probe = self.probe
        let afterPreparation = self.afterPreparation
        #endif
        return {
            await Task.detached(priority: .userInitiated) {
                #if DEBUG
                probe?.record(encoding: false)
                #endif
                let raw = GatewayLogs.rawText(entries)
                #if DEBUG
                probe?.record(encoding: true)
                #endif
                let data = Data(raw.utf8)
                let output = GatewayLogExport(name: GatewayLogs.exportFilename(gatewayName: gatewayName, date: date, timeZone: timeZone), data: data)
                #if DEBUG
                await afterPreparation?()
                #endif
                return output
            }.value
        }
    }
}
