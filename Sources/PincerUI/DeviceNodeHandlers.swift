import Contacts
import CoreLocation
import EventKit
import Foundation
import Network
import PincerKit
import Synchronization
#if os(iOS)
import CoreMotion
import UIKit
#else
import IOKit.ps
#endif

/// The real device APIs behind opt-in device mode. Only the commands in `DeviceModePolicy` ever reach
/// `handle`; every call here is a one-shot read of data the user enabled, run off the main actor
/// (Core Location setup and UIKit state reads hop to main for a few lines and nothing more).
struct PlatformDeviceNodeHandler: DeviceNodeHandler {
    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for cap in caps { result[cap.rawValue] = await self.isAuthorized(cap) }
        return result
    }

    func requestAccess(for cap: DeviceCapability) async -> Bool {
        switch cap {
        case .location: await LocationOneShot.requestWhenInUse()
        case .device: true
        case .calendar: (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .reminders: (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        case .contacts: (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .motion: await MotionAccess.request()
        case .health: await HealthAccess.request()
        case .healthData: await HealthQueryAccess.request()
        }
    }

    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        switch invoke.command {
        case "location.get": await self.locationGet(invoke)
        case "device.info": await self.encode(DeviceInfoReader.info())
        case "device.status": await self.encode(DeviceInfoReader.status())
        case "calendar.events": await self.calendarEvents(invoke)
        case "reminders.list": await self.remindersList(invoke)
        case "contacts.search": await self.contactsSearch(invoke)
        case "motion.activity": await self.motionActivity(invoke)
        case "motion.pedometer": await self.motionPedometer(invoke)
        case HealthSummary.command: await HealthAccess.summary(invoke)
        case HealthQuery.command: await HealthQueryAccess.query(invoke)
        default: .failure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: unknown command")
        }
    }

    private func isAuthorized(_ cap: DeviceCapability) async -> Bool {
        switch cap {
        case .location: await LocationOneShot.isAuthorized()
        case .device: true
        case .calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contacts: Self.contactsGranted
        case .motion: MotionAccess.isAuthorized()
        // Never reported (`reportsPermission`): HealthKit hides read denial.
        case .health: HealthAccess.isAvailable
        case .healthData: HealthQueryAccess.isAvailable
        }
    }

    // MARK: Helpers

    func encode(_ value: some Encodable) -> DeviceNodeResult {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: could not encode the result")
        }
        return .ok(payloadJSON: json)
    }

    static func params<T: Decodable>(_ type: T.Type, _ invoke: DeviceNodeInvoke) -> T? {
        guard let json = invoke.paramsJSON, let data = json.data(using: .utf8), !data.isEmpty else {
            return try? JSONDecoder().decode(T.self, from: Data("{}".utf8))
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func invalid(_ message: String) -> DeviceNodeResult {
        .failure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: \(message)")
    }

    static var contactsGranted: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        return status == .authorized || status == .limited
        #else
        return status == .authorized
        #endif
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func date(_ iso: String?) -> Date?? {
        guard let iso, !iso.isEmpty else { return .some(nil) }
        guard let date = GatewayDates.iso(iso) else { return nil }
        return .some(date)
    }

    static func clamp(_ value: Int?, default fallback: Int, max cap: Int) -> Int {
        min(max(value ?? fallback, 1), cap)
    }
}

// MARK: Location

private struct LocationParams: Decodable {
    var timeoutMs: Int?
    var maxAgeMs: Int?
    var desiredAccuracy: String?
}

private struct LocationPayload: Encodable {
    var lat: Double
    var lon: Double
    var accuracyMeters: Double
    var altitudeMeters: Double?
    var speedMps: Double?
    var headingDeg: Double?
    var timestamp: String
    var isPrecise: Bool
}

extension PlatformDeviceNodeHandler {
    fileprivate func locationGet(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(LocationParams.self, invoke) else { return Self.invalid("invalid params") }
        #if os(iOS)
        if await MainActor.run(body: { UIApplication.shared.applicationState == .background }) {
            return .failure(code: "NODE_BACKGROUND_UNAVAILABLE",
                            message: "LOCATION_BACKGROUND_UNAVAILABLE: Pincer must be in the foreground to read the location")
        }
        #endif
        guard await LocationOneShot.isAuthorized() else {
            return .failure(code: "UNAVAILABLE", message: "LOCATION_PERMISSION_REQUIRED: grant Location permission")
        }
        let timeout = Double(Self.clamp(params.timeoutMs ?? invoke.timeoutMs, default: 10000, max: 60000)) / 1000
        let maxAge = Double(max(params.maxAgeMs ?? 0, 0)) / 1000
        let accuracy: CLLocationAccuracy
        switch params.desiredAccuracy {
        case "coarse": accuracy = kCLLocationAccuracyKilometer
        case "balanced": accuracy = kCLLocationAccuracyHundredMeters
        default: accuracy = kCLLocationAccuracyBest
        }
        guard !Task.isCancelled else { return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: request cancelled") }
        guard let location = await LocationOneShot.fetch(accuracy: accuracy, maxAge: maxAge, timeout: timeout) else {
            return .failure(code: "UNAVAILABLE", message: "LOCATION_UNAVAILABLE: no location fix")
        }
        let precise = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 100
        return self.encode(LocationPayload(
            lat: location.coordinate.latitude, lon: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speedMps: location.speed >= 0 ? location.speed : nil,
            headingDeg: location.course >= 0 ? location.course : nil,
            timestamp: Self.iso(location.timestamp), isPrecise: precise))
    }
}

/// A fresh `CLLocationManager` per request, created on the main actor (its delegate callbacks need a
/// run loop) and torn down as soon as one answer arrives.
@MainActor
private final class LocationOneShot: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationWaiter: CheckedContinuation<CLLocation?, Never>?
    private var authorizationWaiter: CheckedContinuation<Bool, Never>?

    static func isAuthorized() async -> Bool {
        await MainActor.run { Self.authorized(CLLocationManager().authorizationStatus) }
    }

    static func requestWhenInUse() async -> Bool {
        let request = await MainActor.run { LocationOneShot() }
        return await request.requestAuthorization()
    }

    static func fetch(accuracy: CLLocationAccuracy, maxAge: TimeInterval, timeout: TimeInterval) async -> CLLocation? {
        let request = await MainActor.run { LocationOneShot() }
        return await withTaskCancellationHandler {
            await request.fetch(accuracy: accuracy, maxAge: maxAge, timeout: timeout)
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    private var cancelled = false

    private func cancel() {
        self.cancelled = true
        self.manager.stopUpdatingLocation()
        self.finish(nil)
    }

    nonisolated static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(iOS)
        status == .authorizedWhenInUse || status == .authorizedAlways
        #else
        status == .authorizedAlways
        #endif
    }

    override init() {
        super.init()
        self.manager.delegate = self
    }

    private func requestAuthorization() async -> Bool {
        let status = self.manager.authorizationStatus
        guard status == .notDetermined else { return Self.authorized(status) }
        return await withCheckedContinuation { continuation in
            self.authorizationWaiter = continuation
            self.manager.requestWhenInUseAuthorization()
        }
    }

    private func fetch(accuracy: CLLocationAccuracy, maxAge: TimeInterval, timeout: TimeInterval) async -> CLLocation? {
        if maxAge > 0, let cached = self.manager.location, abs(cached.timestamp.timeIntervalSinceNow) <= maxAge,
           cached.horizontalAccuracy >= 0 {
            return cached
        }
        guard !self.cancelled else { return nil }
        self.manager.desiredAccuracy = accuracy
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(nil)
        }
        let location = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.locationWaiter = continuation
            self.manager.requestLocation()
        }
        timer.cancel()
        return location
    }

    private func finish(_ location: CLLocation?) {
        self.locationWaiter?.resume(returning: location)
        self.locationWaiter = nil
        self.manager.delegate = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let waiter = self.authorizationWaiter else { return }
        self.authorizationWaiter = nil
        waiter.resume(returning: Self.authorized(manager.authorizationStatus))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        self.finish(locations.filter { $0.horizontalAccuracy >= 0 }.max { $0.timestamp < $1.timestamp })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        self.finish(nil)
    }
}

// MARK: Device info and status

private struct DeviceInfoPayload: Encodable {
    var deviceName: String
    var modelIdentifier: String
    var systemName: String
    var systemVersion: String
    var appVersion: String
    var appBuild: String
    var locale: String
}

private struct DeviceStatusPayload: Encodable {
    struct Battery: Encodable {
        var level: Double?
        var levelPercent: Int?
        var state: String
        var lowPowerModeEnabled: Bool
    }

    struct Thermal: Encodable { var state: String }

    struct Network: Encodable {
        var status: String
        var isExpensive: Bool
        var isConstrained: Bool
        var interfaces: [String]
    }

    var battery: Battery
    var thermal: Thermal
    var network: Network
}

private enum DeviceInfoReader {
    static func info() async -> DeviceInfoPayload {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let bundle = Bundle.main
        #if os(iOS)
        let name = await MainActor.run { UIDevice.current.name }
        let system = "iOS"
        #else
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let system = "macOS"
        #endif
        return DeviceInfoPayload(
            deviceName: name, modelIdentifier: self.modelIdentifier(), systemName: system,
            systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            locale: Locale.current.identifier)
    }

    static func modelIdentifier() -> String {
        #if os(iOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #endif
    }

    static func status() async -> DeviceStatusPayload {
        let battery = await self.battery()
        let network = await self.network()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "nominal"
        }
        return DeviceStatusPayload(battery: battery, thermal: .init(state: thermal), network: network)
    }

    static func battery() async -> DeviceStatusPayload.Battery {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if os(iOS)
        let (level, state) = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            return (device.batteryLevel, device.batteryState)
        }
        let stateName: String
        switch state {
        case .unplugged: stateName = "unplugged"
        case .charging: stateName = "charging"
        case .full: stateName = "full"
        default: stateName = "unknown"
        }
        let value: Double? = level >= 0 ? Double(level) : nil
        return .init(level: value, levelPercent: value.map { Int(($0 * 100).rounded()) }, state: stateName,
                     lowPowerModeEnabled: lowPower)
        #else
        var level: Double?
        var stateName = "unknown"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
           let source = sources.first,
           let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] {
            if let current = description[kIOPSCurrentCapacityKey] as? Double,
               let full = description[kIOPSMaxCapacityKey] as? Double, full > 0 {
                level = min(max(current / full, 0), 1)
            }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let charged = description[kIOPSIsChargedKey] as? Bool ?? false
            let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            stateName = charged ? "full" : charging ? "charging" : onBattery ? "unplugged" : "unknown"
        }
        return .init(level: level, levelPercent: level.map { Int(($0 * 100).rounded()) }, state: stateName,
                     lowPowerModeEnabled: lowPower)
        #endif
    }

    static func network() async -> DeviceStatusPayload.Network {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let resumed = Mutex(false)
            monitor.pathUpdateHandler = { path in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                let status: String
                switch path.status {
                case .satisfied: status = "satisfied"
                case .requiresConnection: status = "requiresConnection"
                default: status = "unsatisfied"
                }
                var interfaces: [String] = []
                for (type, name) in [(NWInterface.InterfaceType.wifi, "wifi"), (.cellular, "cellular"),
                                     (.wiredEthernet, "wired"), (.other, "other")]
                    where path.usesInterfaceType(type) {
                    interfaces.append(name)
                }
                continuation.resume(returning: .init(status: status, isExpensive: path.isExpensive,
                                                     isConstrained: path.isConstrained, interfaces: interfaces))
            }
            monitor.start(queue: DispatchQueue(label: "chat.pincer.device-mode.network"))
        }
    }
}

// MARK: Calendar and reminders

private struct EventsParams: Decodable {
    var startISO: String?
    var endISO: String?
    var limit: Int?
}

private struct EventsPayload: Encodable {
    struct Event: Encodable {
        var identifier: String
        var title: String
        var startISO: String
        var endISO: String
        var isAllDay: Bool
        var location: String?
        var calendarTitle: String?
    }

    var events: [Event]
}

private struct RemindersParams: Decodable {
    var status: String?
    var limit: Int?
}

private struct RemindersPayload: Encodable {
    struct Reminder: Encodable {
        var identifier: String
        var title: String
        var dueISO: String?
        var completed: Bool
        var listName: String?
    }

    var reminders: [Reminder]
}

extension PlatformDeviceNodeHandler {
    fileprivate func calendarEvents(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(EventsParams.self, invoke),
              let start = Self.date(params.startISO), let end = Self.date(params.endISO)
        else { return Self.invalid("invalid params") }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .failure(code: "UNAVAILABLE", message: "CALENDAR_PERMISSION_REQUIRED: grant Calendar permission")
        }
        let from = start ?? Date()
        let to = end ?? from.addingTimeInterval(7 * 86400)
        guard to > from else { return Self.invalid("endISO must be after startISO") }
        let limit = Self.clamp(params.limit, default: 50, max: 500)
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                EventsPayload.Event(
                    identifier: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "",
                    startISO: Self.iso(event.startDate), endISO: Self.iso(event.endDate), isAllDay: event.isAllDay,
                    location: event.location?.isEmpty == false ? event.location : nil,
                    calendarTitle: event.calendar?.title)
            }
        return self.encode(EventsPayload(events: Array(events)))
    }

    fileprivate func remindersList(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(RemindersParams.self, invoke) else { return Self.invalid("invalid params") }
        let status = params.status ?? "incomplete"
        guard ["incomplete", "completed", "all"].contains(status) else { return Self.invalid("invalid status") }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return .failure(code: "UNAVAILABLE", message: "REMINDERS_PERMISSION_REQUIRED: grant Reminders permission")
        }
        let limit = Self.clamp(params.limit, default: 50, max: 500)
        let store = EKEventStore()
        let predicate = switch status {
        case "completed": store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
        case "all": store.predicateForReminders(in: nil)
        default: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        }
        let items: [RemindersPayload.Reminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).prefix(limit).map { reminder in
                    RemindersPayload.Reminder(
                        identifier: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                        dueISO: reminder.dueDateComponents?.date.map(Self.iso), completed: reminder.isCompleted,
                        listName: reminder.calendar?.title)
                }
                continuation.resume(returning: Array(mapped))
            }
        }
        // The store must outlive its callback, or the callback never fires.
        withExtendedLifetime(store) {}
        return self.encode(RemindersPayload(reminders: items))
    }
}

// MARK: Contacts

private struct ContactsParams: Decodable {
    var query: String?
    var limit: Int?
}

private struct ContactsPayload: Encodable {
    struct Contact: Encodable {
        var identifier: String
        var displayName: String
        var givenName: String
        var familyName: String
        var organizationName: String
        var phoneNumbers: [String]
        var emails: [String]
    }

    var contacts: [Contact]
}

extension PlatformDeviceNodeHandler {
    fileprivate func contactsSearch(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(ContactsParams.self, invoke) else { return Self.invalid("invalid params") }
        guard Self.contactsGranted else {
            return .failure(code: "UNAVAILABLE", message: "CONTACTS_PERMISSION_REQUIRED: grant Contacts permission")
        }
        let limit = Self.clamp(params.limit, default: 25, max: 200)
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var found: [CNContact] = []
        let query = params.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if query.isEmpty {
                let request = CNContactFetchRequest(keysToFetch: keys)
                request.unifyResults = true
                try store.enumerateContacts(with: request) { contact, stop in
                    found.append(contact)
                    if found.count >= limit { stop.pointee = true }
                }
            } else {
                found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            }
        } catch {
            return .failure(code: "UNAVAILABLE", message: "CONTACTS_UNAVAILABLE: could not read contacts")
        }
        let contacts = found.prefix(limit).map { contact in
            ContactsPayload.Contact(
                identifier: contact.identifier,
                displayName: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
                givenName: contact.givenName, familyName: contact.familyName,
                organizationName: contact.organizationName,
                phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String })
        }
        return self.encode(ContactsPayload(contacts: Array(contacts)))
    }
}

// MARK: Motion (iOS only)

private struct MotionParams: Decodable {
    var startISO: String?
    var endISO: String?
    var limit: Int?
}

private struct ActivityPayload: Encodable {
    struct Activity: Encodable {
        var startISO: String
        var endISO: String
        var confidence: String
        var isWalking: Bool
        var isRunning: Bool
        var isCycling: Bool
        var isAutomotive: Bool
        var isStationary: Bool
        var isUnknown: Bool
    }

    var activities: [Activity]
}

private struct PedometerPayload: Encodable {
    var startISO: String
    var endISO: String
    var steps: Int?
    var distanceMeters: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?
}

#if os(iOS)
private enum MotionAccess {
    static func isAuthorized() -> Bool {
        CMMotionActivityManager.isActivityAvailable() && CMMotionActivityManager.authorizationStatus() == .authorized
    }

    static func request() async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        if CMMotionActivityManager.authorizationStatus() == .notDetermined {
            // A tiny query is what makes iOS show the Motion & Fitness prompt.
            let manager = CMMotionActivityManager()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: OperationQueue()) { _, _ in
                    continuation.resume()
                }
            }
            withExtendedLifetime(manager) {}
        }
        return CMMotionActivityManager.authorizationStatus() == .authorized
    }
}

private struct MotionSample: Sendable {
    let startDate: Date
    let confidence: String
    let walking, running, cycling, automotive, stationary, unknown: Bool

    init(_ activity: CMMotionActivity) {
        self.startDate = activity.startDate
        switch activity.confidence {
        case .low: self.confidence = "low"
        case .medium: self.confidence = "medium"
        case .high: self.confidence = "high"
        @unknown default: self.confidence = "low"
        }
        self.walking = activity.walking
        self.running = activity.running
        self.cycling = activity.cycling
        self.automotive = activity.automotive
        self.stationary = activity.stationary
        self.unknown = activity.unknown
    }
}

private struct PedometerSample: Sendable {
    let steps: Int
    let distance: Double?
    let floorsAscended: Int?
    let floorsDescended: Int?

    init(_ data: CMPedometerData) {
        self.steps = data.numberOfSteps.intValue
        self.distance = data.distance?.doubleValue
        self.floorsAscended = data.floorsAscended?.intValue
        self.floorsDescended = data.floorsDescended?.intValue
    }
}

extension PlatformDeviceNodeHandler {
    fileprivate func motionActivity(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(MotionParams.self, invoke),
              let start = Self.date(params.startISO), let end = Self.date(params.endISO)
        else { return Self.invalid("invalid params") }
        guard CMMotionActivityManager.isActivityAvailable() else { return Self.motionUnavailable }
        guard MotionAccess.isAuthorized() else {
            return .failure(code: "UNAVAILABLE", message: "MOTION_PERMISSION_REQUIRED: grant Motion & Fitness permission")
        }
        let to = end ?? Date()
        let from = start ?? to.addingTimeInterval(-86400)
        let limit = Self.clamp(params.limit, default: 200, max: 1000)
        let manager = CMMotionActivityManager()
        // CoreMotion's objects aren't Sendable: copy what we need inside the callback.
        let samples: [MotionSample]? = await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: OperationQueue()) { activities, _ in
                continuation.resume(returning: activities?.map(MotionSample.init))
            }
        }
        withExtendedLifetime(manager) {}
        guard let samples else {
            return .failure(code: "UNAVAILABLE", message: "MOTION_UNAVAILABLE: could not read activity")
        }
        var mapped: [ActivityPayload.Activity] = []
        for (index, activity) in samples.enumerated().suffix(limit) {
            let next = index + 1 < samples.count ? samples[index + 1].startDate : to
            mapped.append(.init(
                startISO: Self.iso(activity.startDate), endISO: Self.iso(next), confidence: activity.confidence,
                isWalking: activity.walking, isRunning: activity.running, isCycling: activity.cycling,
                isAutomotive: activity.automotive, isStationary: activity.stationary, isUnknown: activity.unknown))
        }
        return self.encode(ActivityPayload(activities: mapped))
    }

    fileprivate func motionPedometer(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        guard let params = Self.params(MotionParams.self, invoke),
              let start = Self.date(params.startISO), let end = Self.date(params.endISO)
        else { return Self.invalid("invalid params") }
        guard CMPedometer.isStepCountingAvailable() else { return Self.motionUnavailable }
        guard MotionAccess.isAuthorized() else {
            return .failure(code: "UNAVAILABLE", message: "MOTION_PERMISSION_REQUIRED: grant Motion & Fitness permission")
        }
        let to = end ?? Date()
        let from = start ?? Calendar.current.startOfDay(for: to)
        let pedometer = CMPedometer()
        let data: PedometerSample? = await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { data, _ in
                continuation.resume(returning: data.map(PedometerSample.init))
            }
        }
        withExtendedLifetime(pedometer) {}
        guard let data else {
            return .failure(code: "UNAVAILABLE", message: "MOTION_UNAVAILABLE: could not read pedometer data")
        }
        return self.encode(PedometerPayload(
            startISO: Self.iso(from), endISO: Self.iso(to), steps: data.steps,
            distanceMeters: data.distance, floorsAscended: data.floorsAscended,
            floorsDescended: data.floorsDescended))
    }

    fileprivate static var motionUnavailable: DeviceNodeResult {
        .failure(code: "UNAVAILABLE", message: "MOTION_UNAVAILABLE: not supported on this device")
    }
}
#else
private enum MotionAccess {
    static func isAuthorized() -> Bool { false }
    static func request() async -> Bool { false }
}

extension PlatformDeviceNodeHandler {
    fileprivate func motionActivity(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult { Self.motionUnavailable }
    fileprivate func motionPedometer(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult { Self.motionUnavailable }

    fileprivate static var motionUnavailable: DeviceNodeResult {
        .failure(code: "UNAVAILABLE", message: "MOTION_UNAVAILABLE: not supported on this device")
    }
}
#endif
