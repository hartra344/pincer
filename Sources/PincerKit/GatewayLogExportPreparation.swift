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
    private struct Request {
        let id: UUID
        let entries: [GatewayLogEntry]
        let name: String
        let publish: @MainActor (GatewayLogExport) -> Void
    }
    private var current: UUID?
    private var active: Task<Void, Never>?
    private var pending: Request?
    #if DEBUG
    package var probe: GatewayLogExportProbe?
    /// Holds actual completed preparation, without substituting a prepared result.
    package var afterPreparation: (@Sendable () async -> Void)?
    package var pendingCount: Int { self.pending == nil ? 0 : 1 }
    package var activeCount: Int { self.active == nil ? 0 : 1 }
    #endif
    public init() {}

    /// UI admission retains one active source and at most one replaceable latest source.
    public func request(_ entries: [GatewayLogEntry], gatewayName: String,
                        publish: @escaping @MainActor (GatewayLogExport) -> Void) {
        let request = Request(id: UUID(), entries: entries, name: gatewayName, publish: publish)
        self.current = request.id
        if self.active != nil { self.pending = request }
        else { self.start(request) }
    }

    /// Disappearance invalidates publication. The active lease stays owned until its worker exits.
    public func cancel() {
        self.current = nil
        self.pending = nil
    }

    private func start(_ request: Request) {
        self.active = Task {
            let output = await self.prepare(request.entries, gatewayName: request.name)
            if self.current == request.id { request.publish(output) }
            self.active = nil
            if let pending = self.pending {
                self.pending = nil
                self.start(pending)
            }
        }
    }

    package func waitForIdle() async {
        while let active = self.active { await active.value }
    }

    /// The exact worker used by admitted Gateway Logs Export requests.
    public func prepare(_ entries: [GatewayLogEntry], gatewayName: String,
                        date: Date = Date(), timeZone: TimeZone = .current) async -> GatewayLogExport {
        #if DEBUG
        let probe = self.probe
        let afterPreparation = self.afterPreparation
        #endif
        return await Task.detached(priority: .userInitiated) {
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
