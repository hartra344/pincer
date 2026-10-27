import Foundation

/// The `health.summary` node command, matching upstream OpenClaw's `OpenClawHealthCommand`,
/// `OpenClawHealthSummaryParams` and `OpenClawHealthSummaryPayload` (apps/shared/OpenClawKit,
/// HealthCommands.swift) and the aggregation rules of apps/ios HealthSummaryService.swift.
/// PincerUI reads HealthKit; everything here is pure so tests and checks can cover it on any platform.
public enum HealthSummary {
    public static let command = "health.summary"

    /// Upstream supports only `today`.
    public enum Period: String, Codable, Sendable, CaseIterable {
        case today
    }

    public struct Params: Codable, Sendable, Equatable {
        public var period: Period

        public init(period: Period) {
            self.period = period
        }
    }

    /// Metric fields are omitted (not `null`) when HealthKit returns nothing.
    public struct Payload: Codable, Sendable, Equatable {
        public var period: Period
        public var startISO: String
        public var endISO: String
        public var timeZoneIdentifier: String
        public var stepCount: Int?
        public var sleepDurationMinutes: Int?
        public var restingHeartRateBpm: Double?
        public var workoutCount: Int?
        public var workoutDurationMinutes: Int?

        public init(
            period: Period, startISO: String, endISO: String, timeZoneIdentifier: String,
            stepCount: Int? = nil, sleepDurationMinutes: Int? = nil, restingHeartRateBpm: Double? = nil,
            workoutCount: Int? = nil, workoutDurationMinutes: Int? = nil)
        {
            self.period = period
            self.startISO = startISO
            self.endISO = endISO
            self.timeZoneIdentifier = timeZoneIdentifier
            self.stepCount = stepCount
            self.sleepDurationMinutes = sleepDurationMinutes
            self.restingHeartRateBpm = restingHeartRateBpm
            self.workoutCount = workoutCount
            self.workoutDurationMinutes = workoutDurationMinutes
        }
    }

    /// What HealthKit returned for the range, before rounding.
    public struct Raw: Sendable, Equatable {
        public var steps: Double?
        public var asleep: [DateInterval]
        public var restingHeartRate: Double?
        /// Durations (seconds) of workouts that started in the range; `nil` when there were none.
        public var workoutDurations: [TimeInterval]?

        public init(steps: Double? = nil, asleep: [DateInterval] = [], restingHeartRate: Double? = nil,
                    workoutDurations: [TimeInterval]? = nil)
        {
            self.steps = steps
            self.asleep = asleep
            self.restingHeartRate = restingHeartRate
            self.workoutDurations = workoutDurations
        }
    }

    /// `paramsJSON` is required and must be `{"period":"today"}`; upstream answers anything else with
    /// `INVALID_REQUEST: period must be today`.
    public static func params(_ paramsJSON: String?) -> Result<Params, DeviceNodeFailure> {
        guard let paramsJSON, let params = try? JSONDecoder().decode(Params.self, from: Data(paramsJSON.utf8)) else {
            return .failure(DeviceNodeFailure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: period must be today"))
        }
        return .success(params)
    }

    /// Local midnight through `now`, in `calendar`'s time zone.
    public static func range(now: Date, calendar: Calendar) -> DateInterval {
        DateInterval(start: calendar.startOfDay(for: now), end: now)
    }

    /// Total time covered by `intervals` inside `range`, counting overlaps (sleep stages, several
    /// sources) once. `nil` when nothing falls inside the range.
    public static func mergedDuration(_ intervals: [DateInterval], clippedTo range: DateInterval) -> TimeInterval? {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, range.start)
            let end = min(interval.end, range.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        guard var current = clipped.first else { return nil }
        var total: TimeInterval = 0
        for interval in clipped.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    public static func roundedMinutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

    public static func payload(_ raw: Raw, period: Period, range: DateInterval, timeZone: TimeZone) -> Payload {
        let formatter = ISO8601DateFormatter()
        let workouts = raw.workoutDurations.flatMap { $0.isEmpty ? nil : $0 }
        return Payload(
            period: period,
            startISO: formatter.string(from: range.start),
            endISO: formatter.string(from: range.end),
            timeZoneIdentifier: timeZone.identifier,
            stepCount: raw.steps.map { Int($0.rounded()) },
            sleepDurationMinutes: self.mergedDuration(raw.asleep, clippedTo: range).map(self.roundedMinutes),
            restingHeartRateBpm: raw.restingHeartRate.map { ($0 * 10).rounded() / 10 },
            workoutCount: workouts?.count,
            workoutDurationMinutes: workouts.map { self.roundedMinutes($0.reduce(0, +)) })
    }

    /// The `node.invoke.result` reply for a payload.
    public static func result(_ payload: Payload) -> DeviceNodeResult {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: could not encode the result")
        }
        return .ok(payloadJSON: json)
    }
}

public struct DeviceNodeFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var result: DeviceNodeResult { .failure(code: self.code, message: self.message) }
}
