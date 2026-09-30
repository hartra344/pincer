import Foundation
import Network
import Observation

/// Whether the current network is expensive (cellular, personal hotspot) or constrained (Low
/// Data Mode). Large queued uploads wait while either is true. Shared by every Gateway store.
@MainActor @Observable
public final class NetworkConditions {
    public static let shared = NetworkConditions()

    public private(set) var isExpensive = false
    public private(set) var isConstrained = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var overridden = false

    public init() {}

    /// Starts watching the network; later calls do nothing.
    public func start() {
        guard self.monitor == nil, !self.overridden else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive, constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self, !self.overridden else { return }
                self.apply(expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "pincer.network-conditions", qos: .utility))
        self.monitor = monitor
    }

    /// Sets the state by hand and stops watching the real network (tests and checks).
    public func override(expensive: Bool, constrained: Bool) {
        self.overridden = true
        self.monitor?.cancel()
        self.monitor = nil
        self.apply(expensive: expensive, constrained: constrained)
    }

    private func apply(expensive: Bool, constrained: Bool) {
        if self.isExpensive != expensive { self.isExpensive = expensive }
        if self.isConstrained != constrained { self.isConstrained = constrained }
    }
}
