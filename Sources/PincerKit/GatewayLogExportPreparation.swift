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
    #if DEBUG
    package var probe: GatewayLogExportProbe?
    #endif
    public init() {}

    /// The same preparation used by Gateway Logs' confirmed Export action.
    public func prepare(_ entries: [GatewayLogEntry], gatewayName: String,
                        date: Date = Date(), timeZone: TimeZone = .current) async -> GatewayLogExport {
        #if DEBUG
        self.probe?.record(encoding: false)
        #endif
        let raw = GatewayLogs.rawText(entries)
        #if DEBUG
        self.probe?.record(encoding: true)
        #endif
        let data = Data(raw.utf8)
        return GatewayLogExport(name: GatewayLogs.exportFilename(gatewayName: gatewayName, date: date, timeZone: timeZone), data: data)
    }
}
