#if DEBUG
import Foundation

/// Test diagnostics only: one fixed phase and scalar snapshot, never view or model payloads.
public final class AvatarPhaseDiagnostics: @unchecked Sendable {
    public enum Phase: String, Sendable {
        case setup, connection, history, picker, defaultGeometry, largeFirst, small, largeAgain
        case accessibilityGeometry, send, approval, overlays, reopened, complete
    }
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var phase = Phase.setup
    private var ready = false
    private var width = 0.0
    private var height = 0.0

    public init() {}
    public func enter(_ phase: Phase, ready: Bool = false, width: Double = 0, height: Double = 0) {
        lock.lock()
        self.phase = phase; self.ready = ready
        self.width = Self.bounded(width); self.height = Self.bounded(height)
        lock.unlock()
    }
    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? min(10000, max(0, value)) : 0
    }
    public func report() -> String {
        lock.lock()
        let phase = self.phase, ready = self.ready, width = self.width, height = self.height
        lock.unlock()
        let elapsed = start.duration(to: ContinuousClock.now).components
        return "Avatar phase=\(phase.rawValue) elapsedSeconds=\(elapsed.seconds) ready=\(ready) width=\(width) height=\(height)"
    }
}
#endif
