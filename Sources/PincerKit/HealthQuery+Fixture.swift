import Foundation

extension HealthQuery {
    /// A week of realistic Health data relative to `now`, shared by the demo showcase, PincerChecks'
    /// fake node handler and the unit tests. "Today" is the morning the fixture's last night ended.
    public enum Fixture {
        public static let source = "Apple Watch"
        /// HRV SDNN daily averages, oldest first; the dip is the day after a late night.
        public static let hrvAverages = [42.3, 45.1, 39.8, 51.2, 48.6, 35.9, 44.1]
        static let hrvMins = [28.1, 30.4, 26.2, 34.8, 33.0, 24.7, 29.6]
        static let hrvMaxes = [61.0, 63.2, 57.5, 70.1, 66.4, 52.3, 62.8]
        public static let restingHeartRates = [58.0, 57.0, 60.0, 56.0, 57.0, 59.0, 58.0]
        public static let steps = [8421.0, 11900.0, 6800.0, 9310.0, 10422.0, 7215.0, 9876.0]
        /// Last night, 22:48–06:31.
        public static let sleepMinutes = ["asleepCore": 231.0, "asleepDeep": 62.0, "asleepREM": 98.0, "awake": 14.0]
        /// Stage segments from 23:46 (minutes, sleepAnalysis raw value).
        static let sleepSegments: [(Double, Int)] = [
            (45, 3), (35, 4), (50, 3), (25, 5), (27, 4), (48, 3), (8, 2), (33, 5), (40, 3), (40, 5), (6, 2), (48, 3),
        ]

        /// Local midnight of the fixture's "today": today once it's past 06:45, otherwise yesterday.
        public static func today(now: Date, calendar: Calendar) -> Date {
            let midnight = calendar.startOfDay(for: now)
            let cutoff = calendar.date(bySettingHour: 6, minute: 45, second: 0, of: midnight) ?? midnight
            return now >= cutoff ? midnight : calendar.date(byAdding: .day, value: -1, to: midnight) ?? midnight
        }

        /// The 7 fixture days, oldest first.
        public static func days(now: Date, calendar: Calendar) -> [Date] {
            let today = self.today(now: now, calendar: calendar)
            return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        }

        private static func at(_ day: Date, _ hour: Int, _ minute: Int, _ calendar: Calendar, dayOffset: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }

        struct Point {
            var start: Date
            var end: Date
            var value: Double
        }

        /// Two HRV readings a day: overnight (~23:00 the evening before) and morning (~06:41).
        static func hrv(now: Date, calendar: Calendar) -> [Point] {
            zip(self.days(now: now, calendar: calendar), self.hrvAverages).flatMap { day, average -> [Point] in
                let night = self.at(day, 23, 2, calendar, dayOffset: -1)
                let morning = self.at(day, 6, 41, calendar)
                return [
                    Point(start: night, end: night.addingTimeInterval(61), value: average - 2.2),
                    Point(start: morning, end: morning, value: average + 2.2),
                ]
            }
        }

        /// Last night's sleepAnalysis samples: the inBed span plus contiguous stage segments.
        public static func sleep(now: Date, calendar: Calendar) -> [CategorySample] {
            let today = self.today(now: now, calendar: calendar)
            let bed = self.at(today, 22, 48, calendar, dayOffset: -1)
            let wake = self.at(today, 6, 31, calendar)
            var samples = [CategorySample(start: bed, end: wake, value: 0)]
            var cursor = self.at(today, 23, 46, calendar, dayOffset: -1)
            for (minutes, value) in self.sleepSegments {
                let end = cursor.addingTimeInterval(minutes * 60)
                samples.append(CategorySample(start: cursor, end: end, value: value))
                cursor = end
            }
            return samples
        }

        static func workouts(now: Date, calendar: Calendar, stamp: Stamp) -> [(Date, WorkoutRow)] {
            let today = self.today(now: now, calendar: calendar)
            let run = self.at(today, 7, 5, calendar, dayOffset: -2)
            let lift = self.at(today, 18, 10, calendar, dayOffset: -4)
            let runEnd = run.addingTimeInterval(34.6 * 60)
            let liftEnd = lift.addingTimeInterval(48 * 60)
            return [
                (run, WorkoutRow(
                    start: stamp.string(run), end: stamp.string(runEnd), activityType: "running", durationMinutes: 34.6,
                    activeEnergyKcal: 412, distanceMeters: 5210, averageHeartRateBpm: 152, maxHeartRateBpm: 171,
                    source: self.source)),
                (lift, WorkoutRow(
                    start: stamp.string(lift), end: stamp.string(liftEnd), activityType: "traditionalStrengthTraining",
                    durationMinutes: 48, activeEnergyKcal: 286, source: self.source)),
            ]
        }

        /// Daily statistics for the quantity types the fixture covers.
        static func daily(_ name: String) -> (average: [Double], min: [Double], max: [Double])? {
            switch name {
            case "heartRateVariabilitySDNN": (self.hrvAverages, self.hrvMins, self.hrvMaxes)
            case "restingHeartRate": (self.restingHeartRates, self.restingHeartRates.map { $0 - 2 },
                                      self.restingHeartRates.map { $0 + 3 })
            case "stepCount": (self.steps, [], [])
            default: nil
            }
        }

        /// What a device holding the fixture would answer for `request`.
        public static func result(_ request: Request, now: Date, calendar: Calendar) -> DeviceNodeResult {
            let stamp = Stamp(timeZone: calendar.timeZone)
            guard request.mode != .types else { return HealthQuery.result(HealthQuery.typesPayload()) }
            guard let entry = request.entry else { return HealthQuery.result(HealthQuery.typesPayload()) }
            if request.mode == .statistics {
                return HealthQuery.result(HealthQuery.statisticsPayload(
                    request, buckets: self.statistics(request, entry, now: now, calendar: calendar, stamp: stamp),
                    stamp: stamp))
            }
            func page<Row>(_ rows: [(Date, Row)]) -> [Row] {
                let inRange = rows.filter { $0.0 >= request.range.start && $0.0 < request.range.end }
                    .sorted { request.sort == .asc ? $0.0 < $1.0 : $0.0 > $1.0 }
                return inRange.prefix(request.limit + 1).map(\.1)
            }
            switch entry.name {
            case "heartRateVariabilitySDNN":
                let rows = self.hrv(now: now, calendar: calendar).map { point in
                    (point.start, QuantityRow(
                        start: stamp.string(point.start), end: point.end == point.start ? nil : stamp.string(point.end),
                        value: HealthQuery.round(point.value), source: self.source))
                }
                return HealthQuery.result(HealthQuery.samplesPayload(request, rows: page(rows), stamp: stamp))
            case "sleepAnalysis":
                let rows = self.sleep(now: now, calendar: calendar).map { sample in
                    (sample.start, CategoryRow(
                        start: stamp.string(sample.start), end: stamp.string(sample.end),
                        durationMinutes: HealthQuery.minutes(sample.end.timeIntervalSince(sample.start)),
                        value: sample.value, valueName: entry.valueName(sample.value), source: self.source))
                }
                return HealthQuery.result(HealthQuery.samplesPayload(request, rows: page(rows), stamp: stamp))
            case "workout":
                let rows = page(self.workouts(now: now, calendar: calendar, stamp: stamp))
                return HealthQuery.result(HealthQuery.samplesPayload(request, rows: rows, stamp: stamp))
            default:
                return HealthQuery.result(HealthQuery.samplesPayload(request, rows: [QuantityRow](), stamp: stamp))
            }
        }

        private static func statistics(
            _ request: Request, _ entry: Entry, now: Date, calendar: Calendar, stamp: Stamp) -> [Bucket]
        {
            if entry.name == "sleepAnalysis" {
                let samples = self.sleep(now: now, calendar: calendar)
                    .filter { $0.end > request.range.start && $0.start < request.range.end }
                return HealthQuery.categoryBuckets(samples, entry: entry, buckets: request.buckets, stamp: stamp)
            }
            guard let daily = self.daily(entry.name) else { return [] }
            let days = self.days(now: now, calendar: calendar)
            return request.buckets.compactMap { bucket -> Bucket? in
                let indices = days.indices.filter { index in
                    let day = days[index]
                    let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                    return day >= bucket.start && day < bucket.end && day < request.range.end
                        && dayEnd > request.range.start
                }
                guard !indices.isEmpty else { return nil }
                var row = Bucket(start: stamp.string(bucket.start), end: stamp.string(bucket.end))
                if entry.aggregation == .cumulative {
                    row.sum = HealthQuery.round(indices.map { daily.average[$0] }.reduce(0, +))
                } else {
                    row.average = HealthQuery.round(indices.map { daily.average[$0] }.reduce(0, +) / Double(indices.count))
                    row.min = indices.map { daily.min[$0] }.min()
                    row.max = indices.map { daily.max[$0] }.max()
                }
                return row
            }
        }
    }
}
