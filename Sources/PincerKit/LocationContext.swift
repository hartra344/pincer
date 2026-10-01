import Foundation
import Observation

public enum LocationAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

/// The platform owns permission prompts and one-shot acquisition. Tests supply a driver without hardware.
@MainActor
public protocol LocationContextDriver: AnyObject {
    var authorization: LocationAuthorization { get }
    func requestAuthorization()
    func requestLocation(generation: Int)
    func stop()
}

public struct LocationFix: Sendable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, accuracyMeters: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.timestamp = timestamp
    }
}

/// Contains only the coarse, disclosed context. Raw device coordinates are never persisted.
public struct LocationContextSnapshot: Sendable, Equatable {
    public static let maxAge: TimeInterval = 300
    public let timestamp: Date
    public let context: String

    /// Run on a worker: quantization, numeric formatting, and ISO date formatting happen once per fix.
    public nonisolated static func prepare(_ fix: LocationFix, now: Date = .now) -> Self? {
        guard fix.latitude.isFinite, fix.longitude.isFinite, fix.accuracyMeters.isFinite,
              (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude),
              (0...50_000).contains(fix.accuracyMeters),
              fix.timestamp <= now, now.timeIntervalSince(fix.timestamp) <= Self.maxAge else { return nil }
        // A 0.02-degree grid has cells at most ~2.2 km wide; a 2 km uncertainty covers rounding.
        let latitude = (fix.latitude / 0.02).rounded() * 0.02
        let longitude = (fix.longitude / 0.02).rounded() * 0.02
        let coordinates = String(format: "%.2f, %.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        let accuracy = Int(max(2_000, fix.accuracyMeters + 1_600).rounded(.up))
        let observed = fix.timestamp.formatted(.iso8601)
        let label = L("Location context (approximate, shared by Pincer)")
        let observedLabel = L("observed")
        return Self(timestamp: fix.timestamp,
                    context: "\(label): 📍 \(coordinates) ±\(accuracy)m; \(observedLabel) \(observed)")
    }

    public func isFresh(at now: Date) -> Bool {
        self.timestamp <= now && now.timeIntervalSince(self.timestamp) <= Self.maxAge
    }
}

/// Opt-in, foreground-only context. Sending reads the prepared snapshot without waiting for location.
@Observable
@MainActor
public final class LocationContextModel {
    public enum Status: Equatable, Sendable {
        case off, permissionRequired, denied, restricted, locating, ready, unavailable
    }

    public static let enabledKey = "pincer.locationContext.enabled"
    public private(set) var enabled: Bool
    public private(set) var status: Status = .off
    public private(set) var snapshot: LocationContextSnapshot?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var driver: (any LocationContextDriver)?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingGeneration: Int?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var wantsPermission: Bool

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.enabled = enabled
        self.wantsPermission = enabled
        if self.enabled { self.status = .permissionRequired }
    }

    public func configure(driver: any LocationContextDriver) {
        guard self.driver == nil else { return }
        self.driver = driver
        self.refresh()
    }

    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        self.wantsPermission = enabled
        self.defaults.set(enabled, forKey: Self.enabledKey)
        self.cancelRequest(clearSnapshot: true)
        guard enabled else { self.status = .off; return }
        self.refresh(requestPermission: true)
    }

    public func setActive(_ active: Bool) {
        self.active = active
        if active { self.refresh() }
        else {
            self.cancelRequest(clearSnapshot: true)
            if self.enabled { self.status = .unavailable }
        }
    }

    public func authorizationDidChange() {
        guard self.enabled else { return }
        self.refresh()
    }

    public func refresh() { self.refresh(requestPermission: false) }

    public func requestPermission() { self.refresh(requestPermission: true) }

    private func refresh(requestPermission: Bool) {
        guard self.enabled, self.active, let driver else { return }
        switch driver.authorization {
        case .notDetermined:
            self.cancelRequest(clearSnapshot: true)
            self.status = .permissionRequired
            if requestPermission || self.wantsPermission {
                self.wantsPermission = false
                driver.requestAuthorization()
            }
        case .denied, .restricted:
            self.cancelRequest(clearSnapshot: true)
            self.status = driver.authorization == .denied ? .denied : .restricted
        case .authorized:
            guard self.pendingGeneration == nil else { return }
            // Avoid repeated requests while typing or sending several messages from the same place.
            if let snapshot, snapshot.isFresh(at: .now), Date().timeIntervalSince(snapshot.timestamp) < 30 {
                self.status = .ready
                return
            }
            self.generation += 1
            let generation = self.generation
            self.pendingGeneration = generation
            self.status = .locating
            self.timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.receiveFailure(generation: generation)
            }
            driver.requestLocation(generation: generation)
        }
    }

    public func receiveFix(_ fix: LocationFix, generation: Int, now: Date = .now) async {
        let prepared = await Task.detached(priority: .utility) {
            LocationContextSnapshot.prepare(fix, now: now)
        }.value
        guard self.pendingGeneration == generation, self.enabled, self.active,
              self.driver?.authorization == .authorized else { return }
        self.cancelRequest(clearSnapshot: false)
        self.snapshot = prepared
        self.status = prepared == nil ? .unavailable : .ready
    }

    public func receiveFailure(generation: Int) {
        guard self.pendingGeneration == generation else { return }
        self.cancelRequest(clearSnapshot: false)
        self.status = .unavailable
    }

    /// Normal messages carry a visible, immutable snapshot into the outbox. Commands stay exact.
    public func message(_ text: String, now: Date = .now) -> String {
        guard self.enabled, self.active, self.driver?.authorization == .authorized else {
            if self.enabled { self.refresh() }
            return text
        }
        let snapshot = self.snapshot
        // Keep Core Location request setup outside this synchronous send path.
        Task { @MainActor [weak self] in self?.refresh() }
        guard !text.hasPrefix("/"), let snapshot, snapshot.isFresh(at: now) else { return text }
        return text + (text.isEmpty ? "" : "\n\n") + snapshot.context
    }

    private func cancelRequest(clearSnapshot: Bool) {
        self.generation += 1
        self.pendingGeneration = nil
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        self.driver?.stop()
        if clearSnapshot { self.snapshot = nil }
    }
}
