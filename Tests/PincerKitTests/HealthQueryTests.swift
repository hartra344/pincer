import Foundation
import Testing
@testable import PincerKit

/// Answers `pincer.health.query` from `HealthQuery.Fixture`, like the iOS HealthKit runner would.
private final class FakeHealthQueryHandler: DeviceNodeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _invokes: [DeviceNodeInvoke] = []
    private var _permissionCaps: [Set<DeviceCapability>] = []
    var invokes: [DeviceNodeInvoke] { self.lock.withLock { self._invokes } }
    var permissionCaps: [Set<DeviceCapability>] { self.lock.withLock { self._permissionCaps } }

    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool] {
        self.lock.withLock { self._permissionCaps.append(caps) }
        return Dictionary(uniqueKeysWithValues: caps.map { ($0.rawValue, true) })
    }

    func requestAccess(for cap: DeviceCapability) async -> Bool { true }

    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        self.lock.withLock { self._invokes.append(invoke) }
        switch HealthQuery.request(invoke.paramsJSON, now: Date(), calendar: .current) {
        case let .failure(failure): return failure.result
        case let .success(request): return HealthQuery.Fixture.result(request, now: Date(), calendar: .current)
        }
    }
}

@Suite("Health query")
struct HealthQueryTests {
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// 2026-10-28T12:00:00-04:00.
    static let now = Date(timeIntervalSince1970: 1_793_203_200)

    private func request(_ json: String?) -> Result<HealthQuery.Request, DeviceNodeFailure> {
        HealthQuery.request(json, now: Self.now, calendar: Self.newYork)
    }

    private func error(_ json: String?) -> String? {
        if case let .failure(failure) = self.request(json) { return failure.message }
        return nil
    }

    private func ok(_ json: String?) throws -> HealthQuery.Request {
        try self.request(json).get()
    }

    private func local(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    private func object(_ result: DeviceNodeResult) throws -> [String: Any] {
        guard case let .ok(json) = result else { Issue.record("not ok: \(result)"); return [:] }
        #expect(!json.contains("null"), "optional fields are omitted, never null")
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Params

    @Test func defaults() throws {
        let request = try self.ok(#"{"type":"heartRateVariabilitySDNN"}"#)
        #expect(request.mode == .samples && request.limit == 100 && request.sort == .desc && request.interval == .day)
        #expect(request.range.end == Self.now)
        #expect(request.range.start == Self.newYork.date(byAdding: .day, value: -7, to: Self.now))
        #expect(request.buckets.isEmpty)
        #expect(try self.ok(#"{"mode":"types"}"#).entry == nil)
        #expect(self.error(nil) == self.error("  ") && self.error(nil) == self.error("{}"), "missing params is {}")
        let statistics = try self.ok(#"{"mode":"statistics","type":"stepCount"}"#)
        #expect(statistics.interval == .day && !statistics.buckets.isEmpty)
    }

    @Test func everyErrorString() {
        let allowed = "allowed: mode, type, startISO, endISO, interval, limit, sort"
        let typeless = #"call with {"mode":"types"} to list types"#
        let never = "is never shared (clinical records, documents, medications, vision prescriptions, characteristics, workout routes and heartbeat series are excluded)"
        let cases: [(String?, String)] = [
            ("[1,2]", "params must be a JSON object"),
            ("nope", "params must be a JSON object"),
            (#"{"type":"stepCount","from":"2026-10-01"}"#, #"unknown parameter "from"; \#(allowed)"#),
            (#"{"mode":"raw"}"#, "mode must be types, samples or statistics"),
            (#"{"mode":7}"#, "mode must be types, samples or statistics"),
            (nil, "type is required; \(typeless)"),
            (#"{"mode":"statistics"}"#, "type is required; \(typeless)"),
            (#"{"type":"heartRateVariabilityRMSSDX"}"#, #"unknown type "heartRateVariabilityRMSSDX"; \#(typeless)"#),
            (#"{"type":"workoutRoute"}"#, "workoutRoute \(never)"),
            (#"{"type":"HKClinicalTypeIdentifierLabResultRecord"}"#, "HKClinicalTypeIdentifierLabResultRecord \(never)"),
            (#"{"type":"dateOfBirth"}"#, "dateOfBirth \(never)"),
            (#"{"type":"heartbeatSeries"}"#, "heartbeatSeries \(never)"),
            (#"{"type":"audioExposureEvent"}"#, "audioExposureEvent \(never)"),
            (#"{"type":"stepCount","startISO":"last week"}"#, "startISO must be an ISO 8601 date or date-time"),
            (#"{"type":"stepCount","endISO":"2026-02-30"}"#, "endISO must be an ISO 8601 date or date-time"),
            (#"{"type":"stepCount","startISO":3}"#, "startISO must be an ISO 8601 date or date-time"),
            (#"{"type":"stepCount","startISO":"2026-10-28","endISO":"2026-10-27"}"#, "startISO must be before endISO"),
            (#"{"type":"stepCount","startISO":"2020-01-01"}"#, "the range can be at most 1827 days"),
            (#"{"mode":"statistics","type":"stepCount","interval":"year"}"#, "interval must be hour, day, week, month or total"),
            (#"{"type":"stepCount","limit":0}"#, "limit must be an integer from 1 to 1000"),
            (#"{"type":"stepCount","limit":1001}"#, "limit must be an integer from 1 to 1000"),
            (#"{"type":"stepCount","limit":2.5}"#, "limit must be an integer from 1 to 1000"),
            (#"{"type":"stepCount","limit":true}"#, "limit must be an integer from 1 to 1000"),
            (#"{"type":"stepCount","limit":"10"}"#, "limit must be an integer from 1 to 1000"),
            (#"{"type":"stepCount","sort":"newest"}"#, "sort must be desc or asc"),
            (#"{"type":"stepCount","interval":"day"}"#, "interval only applies to statistics"),
            (#"{"mode":"statistics","type":"stepCount","limit":5}"#, "limit only applies to samples"),
            (#"{"mode":"types","sort":"asc"}"#, "sort only applies to samples"),
            (#"{"mode":"statistics","type":"workout"}"#, "statistics supports quantity and category types; use samples for workout"),
            (#"{"mode":"statistics","type":"bloodPressure"}"#, "statistics supports quantity and category types; use samples for bloodPressure"),
            (#"{"mode":"statistics","type":"heartRate","interval":"hour","startISO":"2026-09-28T12:00:00-04:00"}"#,
             "720 buckets is more than 500; use a larger interval or a shorter range"),
        ]
        for (json, message) in cases {
            #expect(self.error(json) == "INVALID_REQUEST: \(message)", "\(json ?? "nil")")
        }
        if case let .failure(failure) = self.request("[]") { #expect(failure.code == "INVALID_REQUEST") }
    }

    @Test func failureStringsMatchTheSpec() throws {
        let hrv = try #require(HealthQuery.entry(identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"))
        #expect(HealthQuery.healthUnavailable.message == "HEALTH_UNAVAILABLE: Health data isn't available on this device")
        #expect(HealthQuery.needsNewerOS(hrv).message == "HEALTH_UNAVAILABLE: heartRateVariabilitySDNN needs a newer iOS version")
        #expect(HealthQuery.notDetermined(hrv).message == "HEALTH_UNAVAILABLE: Pincer hasn't asked for access to heartRateVariabilitySDNN yet; on the device, turn All Apple Health data off and on in Gateway Settings › This Device")
        #expect(HealthQuery.tooManyCategorySamples.message == "HEALTH_UNAVAILABLE: too much data for category statistics; shorten the range")
        #expect(HealthQuery.timedOut.message == "HEALTH_TIMEOUT: the query took too long; shorten the range or use statistics")
        #expect(HealthQuery.cancelled.message == "UNAVAILABLE: request cancelled")
        #expect(HealthQuery.readFailed.message == "HEALTH_UNAVAILABLE: could not read Health data")
        for failure in [HealthQuery.healthUnavailable, HealthQuery.timedOut, HealthQuery.cancelled, HealthQuery.readFailed,
                        HealthQuery.tooManyCategorySamples] {
            #expect(failure.code == "UNAVAILABLE")
        }
    }

    @Test func nullParamsAreIgnoredButUnknownKeysAreNot() throws {
        #expect(try self.ok(#"{"type":"stepCount","limit":null}"#).limit == 100)
        #expect(self.error(#"{"type":"stepCount","unit":"count"}"#)?.hasPrefix(#"INVALID_REQUEST: unknown parameter "unit""#) == true)
    }

    @Test func dateOnlyStartAndEndCoverWholeLocalDays() throws {
        let request = try self.ok(#"{"type":"stepCount","startISO":"2026-10-20","endISO":"2026-10-27"}"#)
        #expect(request.range.start == self.local("2026-10-20T00:00:00-04:00"))
        #expect(request.range.end == self.local("2026-10-28T00:00:00-04:00"), "a date-only end covers that day")
        let precise = try self.ok(#"{"type":"stepCount","startISO":"2026-10-27T23:14:00.250Z","endISO":"2026-10-28T01:00:00Z"}"#)
        #expect(abs(precise.range.start.timeIntervalSince1970 - 1_793_142_840.25) < 0.001)
        let onlyEnd = try self.ok(#"{"type":"stepCount","endISO":"2026-10-21"}"#)
        #expect(onlyEnd.range.start == self.local("2026-10-15T00:00:00-04:00"), "start defaults to end − 7 days")
    }

    @Test func spanAndBucketCaps() throws {
        // Exactly 1827 days is fine; one more is not.
        _ = try self.ok(#"{"type":"stepCount","startISO":"2021-10-27T12:00:00-04:00","endISO":"2026-10-28T12:00:00-04:00"}"#)
        #expect(self.error(#"{"type":"stepCount","startISO":"2021-10-26T12:00:00-04:00","endISO":"2026-10-28T12:00:00-04:00"}"#)
            == "INVALID_REQUEST: the range can be at most 1827 days")
        let month = try self.ok(#"{"mode":"statistics","type":"stepCount","interval":"month","startISO":"2021-10-28"}"#)
        #expect(month.buckets.count == 61 && month.buckets.count <= HealthQuery.maxBuckets)
        let total = try self.ok(#"{"mode":"statistics","type":"stepCount","interval":"total","startISO":"2021-10-28"}"#)
        #expect(total.buckets == [total.range])
    }

    @Test func bucketsAreAnchoredInTheLocalCalendar() throws {
        let days = try self.ok(#"{"mode":"statistics","type":"stepCount"}"#)
        #expect(days.buckets.count == 8, "a partial first day plus seven more")
        #expect(days.buckets.first?.start == self.local("2026-10-21T00:00:00-04:00"))
        #expect(days.buckets.last?.end == self.local("2026-10-29T00:00:00-04:00"))
        // Daylight saving ends 2026-11-01 in New York: that local day is 25 hours long.
        let dst = HealthQuery.buckets(
            DateInterval(start: self.local("2026-11-01T00:00:00-04:00"), end: self.local("2026-11-01T12:00:00-05:00")),
            .day, calendar: Self.newYork)
        #expect(dst.count == 1 && dst[0].duration == 25 * 3600)
        let hours = try self.ok(#"{"mode":"statistics","type":"heartRate","interval":"hour","startISO":"2026-10-28T09:30:00-04:00"}"#)
        #expect(hours.buckets.first?.start == self.local("2026-10-28T09:00:00-04:00") && hours.buckets.count == 3)
    }

    // MARK: Names

    @Test func nameResolution() throws {
        guard case let .entry(hrv) = HealthQuery.resolve("heartRateVariabilitySDNN") else { Issue.record("hrv"); return }
        #expect(hrv.kind == .quantity && hrv.unit == "ms" && hrv.aggregation == .discrete)
        #expect(HealthQuery.resolve(" HEARTRATEVARIABILITYSDNN ") == .entry(hrv), "case-insensitive")
        #expect(HealthQuery.resolve("HKQuantityTypeIdentifierHeartRateVariabilitySDNN") == .entry(hrv), "full identifier")
        let identifiers = [
            "HKCategoryTypeIdentifierSleepAnalysis": "sleepAnalysis", "HKCorrelationTypeIdentifierBloodPressure": "bloodPressure",
            "HKWorkoutTypeIdentifier": "workout", "HKDataTypeIdentifierStateOfMind": "stateOfMind",
            "HKScoredAssessmentTypeIdentifierPHQ9": "phq9", "HKQuantityTypeIdentifierForcedExpiratoryVolume1": "forcedExpiratoryVolume1",
        ]
        for (identifier, name) in identifiers {
            guard case let .entry(entry) = HealthQuery.resolve(identifier) else { Issue.record("\(identifier)"); continue }
            #expect(entry.name == name, "\(identifier)")
        }
        for name in ["heartRate", "restingHeartRate", "vo2Max", "stepCount", "sleepAnalysis", "mindfulSession", "menstrualFlow",
                     "bloodPressure", "food", "uvExposure", "dietaryVitaminB12", "forcedExpiratoryVolume1", "electrocardiogram",
                     "audiogram", "gad7", "activitySummary", "heartRateVariabilityRMSSD"] {
            guard case let .entry(entry) = HealthQuery.resolve(name) else { Issue.record("\(name)"); continue }
            #expect(entry.name == name)
        }
        for name in ["workoutRoute", "HKWorkoutRouteTypeIdentifier", "HKDataTypeIdentifierHeartbeatSeries", "bloodType",
                     "HKCharacteristicTypeIdentifierDateOfBirth", "HKDocumentTypeIdentifierCDA", "medications",
                     "HKClinicalTypeIdentifierAllergyRecord", "HKVisionPrescriptionTypeIdentifier"] {
            #expect(HealthQuery.resolve(name) == .neverShared, "\(name)")
        }
        #expect(HealthQuery.resolve("heartbeats") == .unknown)
    }

    @Test func catalogUnitsAndAggregation() throws {
        func entry(_ name: String) -> HealthQuery.Entry? {
            if case let .entry(entry) = HealthQuery.resolve(name) { return entry }
            return nil
        }
        #expect(entry("heartRate")?.unit == "count/min" && entry("respiratoryRate")?.unit == "count/min")
        #expect(entry("stepCount")?.aggregation == .cumulative && entry("restingHeartRate")?.aggregation == .discrete)
        for name in ["bodyFatPercentage", "oxygenSaturation", "walkingAsymmetryPercentage", "walkingDoubleSupportPercentage",
                     "appleWalkingSteadiness", "atrialFibrillationBurden", "peripheralPerfusionIndex", "bloodAlcoholContent"] {
            #expect(entry(name)?.isPercent == true, "\(name)")
        }
        #expect(entry("uvExposure")?.unit == "count" && entry("bodyMassIndex")?.unit == "count")
        #expect(entry("mindfulSession")?.values == nil)
        #expect(entry("sleepAnalysis")?.values?.map(\.name)
            == ["inBed", "asleepUnspecified", "awake", "asleepCore", "asleepDeep", "asleepREM"])
        #expect(entry("sleepAnalysis")?.valueName(9) == "unknown(9)")
        for item in HealthQuery.catalog {
            #expect((item.kind == .quantity) == (item.aggregation != nil), "\(item.name)")
            if item.kind == .quantity { #expect(item.unit != nil, "\(item.name)") }
        }
        #expect(Set(HealthQuery.catalog.map(\.name)).count == HealthQuery.catalog.count, "friendly names are unique")
        #expect(!HealthQuery.catalog.contains { $0.name.lowercased().contains("audioexposureevent") && !$0.name.hasPrefix("environmental") && !$0.name.hasPrefix("headphone") })
    }

    /// HealthKit's runtime string for `.environmentalAudioExposureEvent` is the old
    /// "HKCategoryTypeIdentifierAudioExposureEvent"; the constant's name alone resolves to nothing.
    @Test func environmentalAudioExposureEventUsesTheRuntimeIdentifier() {
        let event = HealthQuery.catalog.first { $0.name == "environmentalAudioExposureEvent" }
        #expect(event?.identifier == "HKCategoryTypeIdentifierAudioExposureEvent")
        for name in ["environmentalAudioExposureEvent", "HKCategoryTypeIdentifierAudioExposureEvent",
                     "HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent"] {
            #expect(HealthQuery.resolve(name) == event.map { .entry($0) }, "\(name)")
        }
        #expect(HealthQuery.resolve("audioExposureEvent") == .neverShared)
    }

    @Test func typesPayloadIsOrderStable() throws {
        let payload = HealthQuery.typesPayload()
        #expect(payload.excluded == ["clinicalRecords", "documents", "medications", "visionPrescriptions", "characteristics",
                                     "workoutRoutes", "heartbeatSeries"])
        let kinds = payload.types.map(\.kind)
        let order = ["quantity", "category", "correlation"]
        let ranks = kinds.map { order.firstIndex(of: $0) ?? 3 }
        #expect(ranks == ranks.sorted())
        for kind in order {
            let names = payload.types.filter { $0.kind == kind }.map(\.name)
            #expect(names == names.sorted { $0.lowercased() < $1.lowercased() } || names == names.sorted(), "\(kind)")
        }
        let filtered = HealthQuery.typesPayload { $0.name != "heartRateVariabilityRMSSD" }
        #expect(filtered.types.count == payload.types.count - 1)
        let json = try self.object(HealthQuery.result(payload))
        #expect(Set(json.keys) == ["mode", "usage", "types", "excluded"])
        let workout = try #require((json["types"] as? [[String: Any]])?.first { $0["name"] as? String == "workout" })
        #expect(Set(workout.keys) == ["name", "kind"], "no null unit, aggregation or values")
    }

    // MARK: Numbers and category buckets

    @Test func rounding() {
        #expect(HealthQuery.round(44.123_456) == 44.12)
        #expect(HealthQuery.round(-2.345_6) == -2.35)
        #expect(HealthQuery.round(0.000_123_456) == 0.000_123_5)
        #expect(HealthQuery.round(0.987_65) == 0.987_7)
        #expect(HealthQuery.round(0) == 0 && HealthQuery.round(.nan) == 0)
        #expect(HealthQuery.minutes(90) == 1.5 && HealthQuery.minutes(100) == 1.7)
    }

    @Test func categoryBucketsByEndDateWithMerge() throws {
        guard case let .entry(sleep) = HealthQuery.resolve("sleepAnalysis") else { Issue.record("sleep"); return }
        let stamp = HealthQuery.Stamp(timeZone: Self.newYork.timeZone)
        let day1 = DateInterval(start: self.local("2026-10-27T00:00:00-04:00"), end: self.local("2026-10-28T00:00:00-04:00"))
        let day2 = DateInterval(start: day1.end, end: self.local("2026-10-29T00:00:00-04:00"))
        let samples = [
            // A night that starts on the 27th belongs to the 28th, the morning you wake.
            HealthQuery.CategorySample(start: self.local("2026-10-27T23:00:00-04:00"), end: self.local("2026-10-28T01:00:00-04:00"), value: 3),
            // Overlapping core from a second source merges: 00:30–02:00 adds 60 minutes, not 90.
            HealthQuery.CategorySample(start: self.local("2026-10-28T00:30:00-04:00"), end: self.local("2026-10-28T02:00:00-04:00"), value: 3),
            HealthQuery.CategorySample(start: self.local("2026-10-28T02:00:00-04:00"), end: self.local("2026-10-28T02:45:00-04:00"), value: 4),
            HealthQuery.CategorySample(start: self.local("2026-10-28T02:45:00-04:00"), end: self.local("2026-10-28T02:50:00-04:00"), value: 42),
        ]
        let buckets = HealthQuery.categoryBuckets(samples, entry: sleep, buckets: [day1, day2], stamp: stamp)
        #expect(buckets.count == 1, "the empty 27th is omitted")
        #expect(buckets.first?.start == "2026-10-28T00:00:00-04:00" && buckets.first?.count == 4)
        #expect(buckets.first?.minutesByValue == ["asleepCore": 180, "asleepDeep": 45, "unknown(42)": 5])
        #expect(buckets.first?.minutes == nil)

        guard case let .entry(mindful) = HealthQuery.resolve("mindfulSession") else { Issue.record("mindful"); return }
        let sessions = [
            HealthQuery.CategorySample(start: self.local("2026-10-28T07:00:00-04:00"), end: self.local("2026-10-28T07:10:00-04:00"), value: 0),
            HealthQuery.CategorySample(start: self.local("2026-10-28T07:05:00-04:00"), end: self.local("2026-10-28T07:15:00-04:00"), value: 0),
        ]
        let plain = HealthQuery.categoryBuckets(sessions, entry: mindful, buckets: [day1, day2], stamp: stamp)
        #expect(plain.first?.minutes == 15 && plain.first?.count == 2 && plain.first?.minutesByValue == nil)
    }

    @Test func enumNamesFallBackForUnknownRawValues() {
        #expect(HealthQuery.workoutActivityName(37) == "running")
        #expect(HealthQuery.workoutActivityName(50) == "traditionalStrengthTraining")
        #expect(HealthQuery.workoutActivityName(63) == "highIntensityIntervalTraining")
        #expect(HealthQuery.workoutActivityName(9999) == "other(9999)")
        #expect(HealthQuery.electrocardiogramClassification(1) == "sinusRhythm")
        #expect(HealthQuery.electrocardiogramSymptoms(2) == "present")
    }

    // MARK: Payloads

    @Test func samplesPayloadKeysAndPaging() throws {
        let request = try self.ok(#"{"type":"heartRateVariabilitySDNN","limit":2}"#)
        let stamp = HealthQuery.Stamp(timeZone: Self.newYork.timeZone)
        let rows = [
            HealthQuery.QuantityRow(start: "2026-10-28T06:41:12-04:00", value: 44.12, source: "Apple Watch"),
            HealthQuery.QuantityRow(start: "2026-10-27T23:02:40-04:00", end: "2026-10-27T23:03:41-04:00", value: 38.9,
                                    source: "Apple Watch", userEntered: true),
            HealthQuery.QuantityRow(start: "2026-10-27T06:41:00-04:00", value: 40, source: "Oura"),
        ]
        let json = try self.object(HealthQuery.result(HealthQuery.samplesPayload(request, rows: rows, stamp: stamp)))
        #expect(Set(json.keys) == ["mode", "type", "kind", "unit", "startISO", "endISO", "timeZoneIdentifier", "sort",
                                   "limit", "count", "hasMore", "samples"])
        #expect(json["mode"] as? String == "samples" && json["unit"] as? String == "ms")
        #expect(json["count"] as? Int == 2 && json["hasMore"] as? Bool == true)
        #expect(json["endISO"] as? String == "2026-10-28T12:00:00-04:00")
        #expect(json["timeZoneIdentifier"] as? String == "America/New_York")
        let samples = try #require(json["samples"] as? [[String: Any]])
        #expect(Set(samples[0].keys) == ["start", "value", "source"])
        #expect(Set(samples[1].keys) == ["start", "end", "value", "source", "userEntered"])
    }

    @Test func statisticsPayloadDropsEmptyBuckets() throws {
        let request = try self.ok(#"{"mode":"statistics","type":"stepCount","interval":"total"}"#)
        let stamp = HealthQuery.Stamp(timeZone: Self.newYork.timeZone)
        let payload = HealthQuery.statisticsPayload(request, buckets: [
            HealthQuery.Bucket(start: "a", end: "b"),
            HealthQuery.Bucket(start: "b", end: "c", sum: 9310),
        ], stamp: stamp)
        #expect(payload.buckets.map(\.start) == ["b"])
        let json = try self.object(HealthQuery.result(payload))
        #expect(Set(json.keys) == ["mode", "type", "kind", "unit", "aggregation", "interval", "startISO", "endISO",
                                   "timeZoneIdentifier", "buckets"])
        #expect(json["aggregation"] as? String == "cumulative" && json["interval"] as? String == "total")
        #expect(Set(try #require((json["buckets"] as? [[String: Any]])?.first).keys) == ["start", "end", "sum"])
    }

    // MARK: Fixture

    @Test func fixtureHRVStatisticsRoundTrip() throws {
        let request = try self.ok(#"{"mode":"statistics","type":"heartRateVariabilitySDNN","interval":"day"}"#)
        let json = try self.object(HealthQuery.Fixture.result(request, now: Self.now, calendar: Self.newYork))
        let buckets = try #require(json["buckets"] as? [[String: Any]])
        #expect(buckets.compactMap { $0["average"] as? Double } == HealthQuery.Fixture.hrvAverages)
        #expect(buckets.allSatisfy { ($0["min"] as? Double ?? 99) < ($0["average"] as? Double ?? 0) })
        #expect(buckets.first?["start"] as? String == "2026-10-22T00:00:00-04:00")
        let average = HealthQuery.Fixture.hrvAverages.reduce(0, +) / 7
        #expect(abs(average - 44) < 0.5, "the demo says HRV averaged about 44 ms")
        #expect(HealthQuery.Fixture.hrvAverages.min() == 35.9)
    }

    @Test func fixtureSamplesSleepAndWorkouts() throws {
        let hrv = try self.ok(#"{"type":"heartRateVariabilitySDNN","limit":3}"#)
        let hrvJSON = try self.object(HealthQuery.Fixture.result(hrv, now: Self.now, calendar: Self.newYork))
        #expect(hrvJSON["count"] as? Int == 3 && hrvJSON["hasMore"] as? Bool == true)
        let all = try self.ok(#"{"type":"heartRateVariabilitySDNN","limit":100,"sort":"asc"}"#)
        let allJSON = try self.object(HealthQuery.Fixture.result(all, now: Self.now, calendar: Self.newYork))
        #expect(allJSON["count"] as? Int == 14 && allJSON["hasMore"] as? Bool == false)
        #expect((allJSON["samples"] as? [[String: Any]])?.allSatisfy { $0["source"] as? String == "Apple Watch" } == true)

        let sleep = try self.ok(#"{"type":"sleepAnalysis","startISO":"2026-10-27T18:00:00-04:00","endISO":"2026-10-28T12:00:00-04:00","sort":"asc","limit":200}"#)
        let sleepJSON = try self.object(HealthQuery.Fixture.result(sleep, now: Self.now, calendar: Self.newYork))
        let rows = try #require(sleepJSON["samples"] as? [[String: Any]])
        #expect(rows.first?["valueName"] as? String == "inBed")
        #expect(rows.first?["start"] as? String == "2026-10-27T22:48:00-04:00" && rows.first?["end"] as? String == "2026-10-28T06:31:00-04:00")
        var minutes: [String: Double] = [:]
        for row in rows.dropFirst() { minutes[row["valueName"] as? String ?? "", default: 0] += row["durationMinutes"] as? Double ?? 0 }
        #expect(minutes == HealthQuery.Fixture.sleepMinutes)

        let nights = try self.ok(#"{"mode":"statistics","type":"sleepAnalysis","interval":"day"}"#)
        let nightsJSON = try self.object(HealthQuery.Fixture.result(nights, now: Self.now, calendar: Self.newYork))
        let night = try #require((nightsJSON["buckets"] as? [[String: Any]])?.last)
        #expect(night["start"] as? String == "2026-10-28T00:00:00-04:00")
        #expect((night["minutesByValue"] as? [String: Double])?["asleepDeep"] == 62)

        let workouts = try self.ok(#"{"type":"workout"}"#)
        let workoutJSON = try self.object(HealthQuery.Fixture.result(workouts, now: Self.now, calendar: Self.newYork))
        let sessions = try #require(workoutJSON["samples"] as? [[String: Any]])
        #expect(sessions.map { $0["activityType"] as? String } == ["running", "traditionalStrengthTraining"])
        #expect(sessions.first?["distanceMeters"] as? Double == 5210 && sessions.first?["averageHeartRateBpm"] as? Double == 152)

        let types = try self.object(HealthQuery.Fixture.result(try self.ok(#"{"mode":"types"}"#), now: Self.now, calendar: Self.newYork))
        #expect((types["types"] as? [Any])?.count == HealthQuery.catalog.count)
    }

    @Test func enumNamesMatchHealthKitRawValues() {
        #expect(HealthQuery.stateOfMindKind(1) == "momentaryEmotion" && HealthQuery.stateOfMindKind(2) == "dailyMood")
        #expect(HealthQuery.valenceClassification(1) == "veryUnpleasant" && HealthQuery.valenceClassification(7) == "veryPleasant")
        #expect(HealthQuery.stateOfMindLabel(1) == "amazed" && HealthQuery.stateOfMindLabel(38) == "satisfied")
        #expect(HealthQuery.stateOfMindAssociation(1) == "community" && HealthQuery.stateOfMindAssociation(18) == "weather")
        #expect(HealthQuery.gad7Risk(1) == "noneToMinimal" && HealthQuery.gad7Risk(4) == "severe")
        #expect(HealthQuery.phq9Risk(4) == "moderatelySevere" && HealthQuery.phq9Risk(5) == "severe")
        #expect(HealthQuery.phq9Risk(0) == "unknown(0)" && HealthQuery.stateOfMindKind(9) == "unknown(9)")
    }

    @Test func deadlineLeavesHeadroomUnderTheInvokeTimeout() {
        #expect(HealthQuery.deadline(timeoutMs: nil) == 14.5)
        #expect(HealthQuery.deadline(timeoutMs: 30000) == 29.5)
        #expect(HealthQuery.deadline(timeoutMs: 100) == 0.5)
    }

    @Test func statisticsIntervalsStepByOneUnit() {
        #expect(HealthQuery.intervalComponents(.hour) == DateComponents(hour: 1))
        #expect(HealthQuery.intervalComponents(.day) == DateComponents(day: 1))
        #expect(HealthQuery.intervalComponents(.total) == DateComponents(day: 1))
        #expect(HealthQuery.intervalComponents(.week) == DateComponents(weekOfYear: 1))
        #expect(HealthQuery.intervalComponents(.month) == DateComponents(month: 1))
    }
}

@MainActor
@Suite("Health query device node (demo)")
struct HealthQueryDemoTests {
    @Test func demoRoundTripDeclaresHealthDataAndValidatesParams() async throws {
        let scratch = ScratchDefaults()
        let store = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        store.cacheRoot = nil
        let handler = FakeHealthQueryHandler()
        store.deviceNode.handler = handler
        store.deviceNode.supports = { _ in true }
        defer { store.stop(); scratch.remove() }
        store.start()
        #expect(await eventually(timeout: .seconds(10)) { store.state.isConnected })
        await store.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .health, .healthData]))
        #expect(await eventually(timeout: .seconds(10)) { store.deviceNode.status == .active })
        let demo = try #require(store.connection.demo)
        let node = await demo.demoNodes.first { $0["nodeId"]?.text == DemoGateway.deviceId }
        #expect(DeviceRecords.strings(node?["commands"]) == ["health.summary", "location.get", "pincer.health.query"])
        #expect(Set(DeviceRecords.strings(node?["caps"])) == ["location", "health", "healthData"])
        #expect(handler.permissionCaps.last == [.location], "no Health permission is reported")

        let params = #"{"mode":"statistics","type":"heartRateVariabilitySDNN","interval":"day"}"#
        let ok = await store.demoInvokeNode(command: "pincer.health.query", paramsJSON: params)
        #expect(ok?["ok"]?.bool == true)
        #expect(ok?["payload"]?["type"]?.string == "heartRateVariabilitySDNN")
        #expect(ok?["payload"]?["buckets"]?.array?.compactMap { $0["average"]?.double } == HealthQuery.Fixture.hrvAverages)
        #expect(handler.invokes.last?.paramsJSON == params)

        let bad = await store.demoInvokeNode(command: "pincer.health.query", paramsJSON: #"{"type":"stepCount","from":"x"}"#)
        #expect(bad?["ok"]?.bool == false)
        #expect(bad?["error"]?["message"]?.string?.hasPrefix(#"INVALID_REQUEST: unknown parameter "from""#) == true)
    }

    @Test func showcaseSeedsTheRecoveryChat() throws {
        let seeded = DemoGateway.seed()
        let row = try #require(seeded.sessions[DemoGateway.recoveryKey])
        #expect(row["derivedTitle"]?.string == "Recovery check-in")
        let messages = try #require(seeded.transcripts[DemoGateway.recoveryKey])
        let calls = messages.flatMap { $0["content"]?.array ?? [] }.filter { $0["type"]?.string == "toolCall" }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0["name"]?.string == "nodes" && $0["arguments"]?["invokeCommand"]?.string == "pincer.health.query" })
        let results = messages.filter { $0["role"]?.string == "toolResult" }
        #expect(results.count == 2 && results.allSatisfy { $0["isError"]?.bool == false })
        let hrvText = results.first?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(hrvText.contains(#""type":"heartRateVariabilitySDNN""#) && hrvText.contains("35.9"))
        let reply = messages.last?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(reply.contains("44 ms") && reply.contains("35.9") && reply.contains("6 h 31 min") && reply.contains("not medical advice"))
    }
}
