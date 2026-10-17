import Foundation
import Observation

// MARK: Snapshot

/// One `system.info` result: the Gateway host's identity and resource readings (`operator.read`).
/// Fields follow upstream `SystemInfoResultSchema` (packages/gateway-protocol/src/schema/system-info.ts);
/// everything but the identity strings is optional so older Gateways still parse.
public struct GatewayHostVitals: Sendable, Equatable {
    public struct Disk: Sendable, Equatable, Hashable {
        public let path: String
        public let totalBytes: Int64
        public let availableBytes: Int64

        public init(path: String, totalBytes: Int64, availableBytes: Int64) {
            self.path = path
            self.totalBytes = totalBytes
            self.availableBytes = min(max(0, availableBytes), totalBytes)
        }

        public var usedBytes: Int64 { self.totalBytes - self.availableBytes }
        public var usedFraction: Double { Double(self.usedBytes) / Double(self.totalBytes) }
    }

    public var machineName = ""
    public var hostname = ""
    public var platform = ""
    public var release = ""
    public var arch = ""
    public var osLabel = ""
    public var nodeVersion: String?
    public var pid: Int?
    /// Changes when the Gateway process restarts.
    public var processInstanceId: String?
    public var uptimeMs: Int?
    public var cpuCount: Int?
    public var cpuModel: String?
    /// 1, 5 and 15 minute load averages; nil unless exactly three finite, non-negative numbers.
    public var loadAverage: [Double]?
    public var memoryTotalBytes: Int64?
    public var memoryFreeBytes: Int64?
    /// `eventLoop.cpuBreakdown.hostUtilization`: the whole host's CPU use, 0...1.
    public var hostCpuUtilization: Double?
    /// `eventLoop.cpuCoreRatio`: the Gateway process's CPU, in cores.
    public var processCpuCores: Double?
    /// `processMemory.rssBytes`: the Gateway process's resident memory.
    public var processRssBytes: Int64?
    /// `disks` (or, from Gateways without it, the legacy `diskPath`/`diskTotalBytes`/`diskAvailableBytes`),
    /// with the volume holding the state directory (`diskPath`) first.
    public var disks: [Disk] = []

    public init() {}

    public init?(_ json: JSONValue) {
        guard let object = json.object else { return nil }
        func string(_ key: String) -> String { object[key]?.string ?? "" }
        func bytes(_ value: JSONValue?) -> Int64? { value?.int64.flatMap { $0 >= 0 ? $0 : nil } }
        func finite(_ value: JSONValue?) -> Double? {
            guard case let .number(number)? = value, number.isFinite, number >= 0 else { return nil }
            return number
        }
        self.machineName = string("machineName")
        self.hostname = string("hostname")
        self.platform = string("platform")
        self.release = string("release")
        self.arch = string("arch")
        self.osLabel = string("osLabel")
        self.nodeVersion = object["nodeVersion"]?.text
        self.pid = object["pid"]?.int
        self.processInstanceId = object["processInstanceId"]?.text
        self.uptimeMs = object["uptimeMs"]?.int.flatMap { $0 >= 0 ? $0 : nil }
        self.cpuCount = object["cpuCount"]?.int.flatMap { $0 > 0 ? $0 : nil }
        self.cpuModel = object["cpuModel"]?.text
        if let loads = object["loadAverage"]?.array, loads.count == 3 {
            let values = loads.compactMap(finite)
            self.loadAverage = values.count == 3 ? values : nil
        }
        self.memoryTotalBytes = bytes(object["memoryTotalBytes"]).flatMap { $0 > 0 ? $0 : nil }
        self.memoryFreeBytes = bytes(object["memoryFreeBytes"])
        let eventLoop = object["eventLoop"]
        self.processCpuCores = finite(eventLoop?["cpuCoreRatio"])
        self.hostCpuUtilization = finite(eventLoop?["cpuBreakdown"]?["hostUtilization"]).map { min($0, 1) }
        self.processRssBytes = bytes(object["processMemory"]?["rssBytes"])
        var disks: [Disk] = []
        for entry in object["disks"]?.array ?? [] {
            guard let path = entry["path"]?.text, let total = bytes(entry["totalBytes"]), total > 0,
                  let available = bytes(entry["availableBytes"]),
                  !disks.contains(where: { $0.path == path }) else { continue }
            disks.append(Disk(path: path, totalBytes: total, availableBytes: available))
        }
        let statePath = object["diskPath"]?.text
        if object["disks"]?.array == nil, let total = bytes(object["diskTotalBytes"]), total > 0,
           let available = bytes(object["diskAvailableBytes"]) {
            disks.append(Disk(path: statePath ?? "", totalBytes: total, availableBytes: available))
        } else if let statePath, let index = Self.volumeIndex(containing: statePath, in: disks), index > 0 {
            disks.insert(disks.remove(at: index), at: 0)
        }
        self.disks = disks
    }

    /// The mount whose path is the longest prefix of `path` (the state directory's volume).
    static func volumeIndex(containing path: String, in disks: [Disk]) -> Int? {
        func contains(_ mount: String) -> Bool {
            if mount == path || mount == "/" { return true }
            let prefix = mount.hasSuffix("/") || mount.hasSuffix("\\") ? mount : mount + "/"
            return path.hasPrefix(prefix)
        }
        return disks.indices.filter { contains(disks[$0].path) }.max { disks[$0].path.count < disks[$1].path.count }
    }

    /// The name to show for the host.
    public var displayName: String {
        if !self.machineName.isEmpty { return self.machineName }
        if !self.hostname.isEmpty { return self.hostname }
        return L("Gateway host")
    }

    public var memoryUsedBytes: Int64? {
        guard let total = self.memoryTotalBytes, let free = self.memoryFreeBytes else { return nil }
        return max(0, total - min(free, total))
    }

    public var memoryUsedFraction: Double? {
        guard let used = self.memoryUsedBytes, let total = self.memoryTotalBytes else { return nil }
        return Double(used) / Double(total)
    }

    public var primaryDisk: Disk? { self.disks.first }

    /// The 1 minute load per core: above 1 means work is queuing for CPU.
    public var loadPerCore: Double? {
        guard let load = self.loadAverage?.first, let cores = self.cpuCount else { return nil }
        return load / Double(cores)
    }
}

public struct GatewayHostVitalsSample: Sendable, Equatable {
    public let at: Date
    /// The `system.info` round trip, in milliseconds.
    public let pingMs: Double
    public let vitals: GatewayHostVitals

    public init(at: Date, pingMs: Double, vitals: GatewayHostVitals) {
        self.at = at
        self.pingMs = pingMs
        self.vitals = vitals
    }
}

public enum GatewayHostVitalsMetric: String, CaseIterable, Hashable, Sendable {
    case cpu, memory, disk, load, ping

    /// The reading for one sample: CPU, memory and disk as 0...1 fractions, load the 1 minute average, ping in ms.
    public func value(_ sample: GatewayHostVitalsSample) -> Double? {
        switch self {
        case .cpu: sample.vitals.hostCpuUtilization
        case .memory: sample.vitals.memoryUsedFraction
        case .disk: sample.vitals.primaryDisk?.usedFraction
        case .load: sample.vitals.loadAverage?.first
        case .ping: sample.pingMs
        }
    }

    /// Orange in Gateway Health. Ping follows the Control UI (over 250 ms); the rest flag a host near its limits.
    public func isWarning(_ sample: GatewayHostVitalsSample) -> Bool {
        switch self {
        case .cpu: (sample.vitals.hostCpuUtilization ?? 0) >= 0.9
        case .memory: (sample.vitals.memoryUsedFraction ?? 0) >= 0.9
        case .disk: (sample.vitals.primaryDisk?.usedFraction ?? 0) >= 0.9
        case .load: (sample.vitals.loadPerCore ?? 0) >= 1
        case .ping: sample.pingMs > 250
        }
    }
}

// MARK: Model

/// Host vitals for Gateway Health: `system.info` sampled while the page is on screen, with a bounded history.
@MainActor
@Observable
public final class GatewayHostVitalsModel {
    /// The Control UI's cadence.
    public nonisolated static let pollInterval: Duration = .seconds(10)
    /// 15 minutes at the poll interval, like the Control UI's 90 samples.
    public nonisolated static let historyCapacity = 90
    /// A read that takes longer is a gap, like the Control UI's.
    public nonisolated static let requestTimeout: TimeInterval = 10
    nonisolated static let method = "system.info"

    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// The Gateway doesn't offer `system.info`.
        case unavailable
        case failed(String)
    }

    public private(set) var state = State.idle
    /// Oldest first, at most `historyCapacity`.
    public private(set) var samples: [GatewayHostVitalsSample] = []
    /// The connection lacks `operator.read`: polling stops until a reconnect or an explicit Refresh.
    public private(set) var missingScope = false

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let clock: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var generation = 0
    /// The generation whose read is in flight.
    @ObservationIgnored private var inFlight: Int?

    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.clock = clock
    }

    public var latest: GatewayHostVitalsSample? { self.samples.last }

    /// The Gateway advertises `system.info` (or doesn't list methods) and hasn't refused it.
    public var isAvailable: Bool {
        if self.state == .unavailable { return false }
        if let methods = self.methods(), !methods.isEmpty, !methods.contains(Self.method) { return false }
        return true
    }

    /// One `system.info` read, appended to the history. Overlapping calls share the one in flight.
    public func sample() async {
        let generation = self.generation
        guard self.isAvailable, self.inFlight != generation, !Task.isCancelled else { return }
        self.inFlight = generation
        defer { if self.inFlight == generation { self.inFlight = nil } }
        if self.samples.isEmpty { self.state = .loading }
        let started = self.clock()
        do {
            let result = try await self.request(Self.method, [:])
            let elapsed = self.clock() - started
            guard generation == self.generation else { return }
            guard let vitals = GatewayHostVitals(result) else {
                self.state = .failed(L("The Gateway sent host information Pincer can't read."))
                return
            }
            let ping = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            self.append(GatewayHostVitalsSample(at: Date(), pingMs: max(0, ping), vitals: vitals))
            self.missingScope = false
            self.state = .loaded
        } catch {
            guard generation == self.generation, !(error is CancellationError) else {
                if generation == self.generation, self.state == .loading { self.state = .idle }
                return
            }
            if GatewayError.isMissingScope(error) {
                self.missingScope = true
                self.state = .failed(GatewayError.missingScopeMessage(for: error))
            } else if GatewayError.isUnavailable(error) {
                self.state = .unavailable
                self.samples = []
            } else if case GatewayError.rpc(_, let message, _) = error {
                self.state = .failed(message)
            } else {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Adds a reading, dropping the history when the Gateway process changed (it restarted) and the oldest past the cap.
    func append(_ sample: GatewayHostVitalsSample) {
        if let last = self.samples.last?.vitals, Self.processChanged(from: last, to: sample.vitals) {
            self.samples.removeAll(keepingCapacity: true)
        }
        self.samples.append(sample)
        if self.samples.count > Self.historyCapacity {
            self.samples.removeFirst(self.samples.count - Self.historyCapacity)
        }
    }

    nonisolated static func processChanged(from old: GatewayHostVitals, to new: GatewayHostVitals) -> Bool {
        if let a = old.processInstanceId, let b = new.processInstanceId { return a != b }
        if let a = old.pid, let b = new.pid { return a != b }
        return false
    }

    /// Forgets the history (disconnect, another Gateway); a read in flight is discarded.
    public func reset() {
        self.generation += 1
        self.samples = []
        self.state = .idle
        self.missingScope = false
        self.inFlight = nil
    }

    /// Each sample's reading, oldest first; nil where a sample lacks it.
    public func series(_ metric: GatewayHostVitalsMetric) -> [Double?] {
        self.samples.map(metric.value)
    }

    public func value(_ metric: GatewayHostVitalsMetric) -> Double? {
        self.latest.flatMap(metric.value)
    }

    public func isWarning(_ metric: GatewayHostVitalsMetric) -> Bool {
        self.latest.map(metric.isWarning) ?? false
    }
}
