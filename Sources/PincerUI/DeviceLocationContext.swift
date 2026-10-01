import CoreLocation
import PincerKit
import Synchronization

struct LocationRequestToken: Sendable {
    let manager: ObjectIdentifier
    let generation: Int

    func generation(for callbackManager: ObjectIdentifier) -> Int? {
        self.manager == callbackManager ? self.generation : nil
    }
}

/// Foreground, one-shot location requests only. No continuous or background tracking.
@MainActor
final class DeviceLocationContext: NSObject, LocationContextDriver, CLLocationManagerDelegate {
    private weak var model: LocationContextModel?
    private var permissionManager: CLLocationManager?
    private var requestManager: CLLocationManager?
    private nonisolated let request = Mutex<LocationRequestToken?>(nil)

    init(model: LocationContextModel) {
        self.model = model
        super.init()
    }

    private func locationManager() -> CLLocationManager {
        if let manager = self.permissionManager { return manager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.permissionManager = manager
        return manager
    }

    var authorization: LocationAuthorization {
        switch self.locationManager().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestAuthorization() { self.locationManager().requestWhenInUseAuthorization() }

    func requestLocation(generation: Int) {
        self.stop()
        // Core Location callbacks carry a manager, not a request ID. A distinct manager per
        // one-shot request prevents a late callback from an old request borrowing a new generation.
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.requestManager = manager
        self.request.withLock { $0 = LocationRequestToken(manager: ObjectIdentifier(manager), generation: generation) }
        manager.requestLocation()
    }

    func stop() {
        self.request.withLock { $0 = nil }
        self.requestManager?.stopUpdatingLocation()
        self.requestManager?.delegate = nil
        self.requestManager = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.model?.authorizationDidChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let identity = ObjectIdentifier(manager)
        guard let generation = self.request.withLock({ $0?.generation(for: identity) }),
              let location = locations.filter({ $0.horizontalAccuracy >= 0 }).max(by: { $0.timestamp < $1.timestamp })
        else { return }
        let fix = LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                              accuracyMeters: location.horizontalAccuracy, timestamp: location.timestamp)
        Task { @MainActor [weak self] in
            await self?.model?.receiveFix(fix, generation: generation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let identity = ObjectIdentifier(manager)
        guard let generation = self.request.withLock({ $0?.generation(for: identity) }) else { return }
        Task { @MainActor [weak self] in self?.model?.receiveFailure(generation: generation) }
    }
}
