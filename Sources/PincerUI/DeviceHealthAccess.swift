import Foundation
import PincerKit
import Synchronization
#if os(iOS) && canImport(HealthKit)
import HealthKit

/// Device mode's `health.summary`: one read-only HealthKit pass over today, aggregated on the device
/// like upstream OpenClaw's HealthSummaryService. Runs only when the Gateway invokes it, off the main
/// actor; nothing is read in the background and nothing is written.
enum HealthAccess {
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var readTypes: Set<HKObjectType> {
        [HKWorkoutType.workoutType(), HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis),
         HKQuantityType(.restingHeartRate)]
    }

    /// Shows Apple's Health sheet. HealthKit never reveals read denial, so `true` only means the
    /// request completed; the checkbox records the user's choice to share, not what Apple granted.
    static func request() async -> Bool {
        guard self.isAvailable else { return false }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [], read: self.readTypes)
            return true
        } catch {
            return false
        }
    }

    static func summary(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        let params: HealthSummary.Params
        switch HealthSummary.params(invoke.paramsJSON) {
        case let .success(value): params = value
        case let .failure(failure): return failure.result
        }
        guard self.isAvailable else {
            return .failure(code: "UNAVAILABLE", message: "HEALTH_UNAVAILABLE: Health data isn't available on this device")
        }
        let range = HealthSummary.range(now: Date(), calendar: .current)
        let store = HKHealthStore()
        do {
            var raw = HealthSummary.Raw()
            raw.steps = try await self.statistic(.stepCount, .cumulativeSum, range, store)?
                .sumQuantity()?.doubleValue(for: .count())
            try Task.checkCancellation()
            raw.asleep = try await self.asleep(range, store)
            try Task.checkCancellation()
            raw.restingHeartRate = try await self.statistic(.restingHeartRate, .discreteAverage, range, store)?
                .averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
            try Task.checkCancellation()
            raw.workoutDurations = try await self.workoutDurations(range, store)
            return HealthSummary.result(HealthSummary.payload(raw, period: params.period, range: range, timeZone: .current))
        } catch is CancellationError {
            return .failure(code: "UNAVAILABLE", message: "UNAVAILABLE: request cancelled")
        } catch {
            return .failure(code: "UNAVAILABLE", message: "HEALTH_UNAVAILABLE: could not read Health data")
        }
    }

    private static func samples(in range: DateInterval, strictStart: Bool = false) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: range.start, end: range.end, options: strictStart ? .strictStartDate : [])
    }

    private static func statistic(
        _ type: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions, _ range: DateInterval, _ store: HKHealthStore
    ) async throws -> HKStatistics? {
        try await HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(type), predicate: self.samples(in: range)),
            options: options).result(for: store)
    }

    private static func asleep(_ range: DateInterval, _ store: HKHealthStore) async throws -> [DateInterval] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: self.samples(in: range))],
            sortDescriptors: [], limit: nil)
        return try await descriptor.result(for: store).compactMap { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(value) else { return nil }
            return DateInterval(start: sample.startDate, end: sample.endDate)
        }
    }

    private static func workoutDurations(_ range: DateInterval, _ store: HKHealthStore) async throws -> [TimeInterval]? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(self.samples(in: range, strictStart: true))], sortDescriptors: [], limit: nil)
        let workouts = try await descriptor.result(for: store)
        return workouts.isEmpty ? nil : workouts.map(\.duration)
    }
}
/// Device mode's `pincer.health.query` (#1084): read-only HealthKit queries for the one type an agent
/// asks for. Runs only when the Gateway invokes it, off the main actor, and never writes. Clinical
/// records, documents, medications, prescriptions, routes and heartbeat series are never requested.
enum HealthQueryAccess {
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Catalog entries resolved on this OS, by friendly name. Types newer than this OS resolve to nil.
    static let resolved: [String: HKObjectType] = {
        var map: [String: HKObjectType] = [:]
        for entry in HealthQuery.catalog {
            if let type = HealthQueryAccess.objectType(entry) { map[entry.name] = type }
        }
        return map
    }()

    private static func objectType(_ entry: HealthQuery.Entry) -> HKObjectType? {
        switch entry.kind {
        case .quantity: HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: entry.identifier))
        case .category: HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: entry.identifier))
        case .correlation:
            HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(rawValue: entry.identifier))
        case .workout: HKObjectType.workoutType()
        case .electrocardiogram: HKObjectType.electrocardiogramType()
        case .audiogram: HKObjectType.audiogramSampleType()
        case .stateOfMind: HKObjectType.stateOfMindType()
        case .scoredAssessment:
            // Swift's `HKScoredAssessmentType(_:)` is non-optional, so only known identifiers are built.
            switch HKScoredAssessmentTypeIdentifier(rawValue: entry.identifier) {
            case .GAD7: HKScoredAssessmentType(.GAD7)
            case .PHQ9: HKScoredAssessmentType(.PHQ9)
            default: nil
            }
        case .activitySummary: HKObjectType.activitySummaryType()
        }
    }

    /// Everything shareable, minus correlations (HealthKit only authorizes their component quantities,
    /// which are in the catalog).
    static var readTypes: Set<HKObjectType> {
        Set(HealthQuery.catalog.filter { $0.kind != .correlation }.compactMap { self.resolved[$0.name] })
    }

    /// One Apple Health sheet for every included type ("Turn On All" or pick). Read-only: `toShare: []`.
    static func request() async -> Bool {
        guard self.isAvailable else { return false }
        do {
            try await HKHealthStore().requestAuthorization(toShare: [], read: self.readTypes)
            return true
        } catch {
            return false
        }
    }

    static func query(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        let calendar = Calendar.current
        let request: HealthQuery.Request
        switch HealthQuery.request(invoke.paramsJSON, now: Date(), calendar: calendar) {
        case let .success(value): request = value
        case let .failure(failure): return failure.result
        }
        guard self.isAvailable else { return HealthQuery.healthUnavailable.result }
        guard request.mode != .types else {
            return HealthQuery.result(HealthQuery.typesPayload { self.resolved[$0.name] != nil })
        }
        guard let entry = request.entry else { return HealthQuery.readFailed.result }
        guard self.resolved[entry.name] != nil else { return HealthQuery.needsNewerOS(entry).result }
        return await Deadline.run(seconds: HealthQuery.deadline(timeoutMs: invoke.timeoutMs)) {
            do {
                return try await Runner(request: request, entry: entry, calendar: calendar).run()
            } catch is CancellationError {
                return HealthQuery.cancelled.result
            } catch let failure as DeviceNodeFailure {
                return failure.result
            } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
                return HealthQuery.notDetermined(entry).result
            } catch {
                return HealthQuery.readFailed.result
            }
        }
    }

    /// Races `work` against the deadline. The first answer wins; a late HealthKit reply is dropped.
    private enum Deadline {
        static func run(
            seconds: TimeInterval, _ work: @escaping @Sendable () async -> DeviceNodeResult) async -> DeviceNodeResult
        {
            let gate = Gate()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    gate.attach(continuation)
                    let worker = Task { gate.finish(await work()) }
                    let timer = Task {
                        try await Task.sleep(for: .seconds(seconds))
                        gate.finish(HealthQuery.timedOut.result)
                    }
                    gate.onFinish {
                        worker.cancel()
                        timer.cancel()
                    }
                }
            } onCancel: {
                gate.finish(HealthQuery.cancelled.result)
            }
        }
    }

    private final class Gate: Sendable {
        private struct State {
            var continuation: CheckedContinuation<DeviceNodeResult, Never>?
            var result: DeviceNodeResult?
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func attach(_ continuation: CheckedContinuation<DeviceNodeResult, Never>) {
            let early = self.state.withLock { state -> DeviceNodeResult? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        /// Cancels the worker once an answer has been sent (immediately if it already was).
        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let done = self.state.withLock { state -> Bool in
                if state.result != nil { return true }
                state.cleanup = cleanup
                return false
            }
            if done { cleanup() }
        }

        /// `true` if this call delivered the answer.
        @discardableResult
        func finish(_ result: DeviceNodeResult) -> Bool {
            let (continuation, cleanup, won) = self.state.withLock {
                state -> (CheckedContinuation<DeviceNodeResult, Never>?, (@Sendable () -> Void)?, Bool) in
                guard state.result == nil else { return (nil, nil, false) }
                state.result = result
                defer {
                    state.continuation = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cleanup, true)
            }
            continuation?.resume(returning: result)
            cleanup?()
            return won
        }
    }

    private struct TooManySamples: Error {}

    private struct Runner {
        let request: HealthQuery.Request
        let entry: HealthQuery.Entry
        let calendar: Calendar
        let store = HKHealthStore()
        var stamp: HealthQuery.Stamp { HealthQuery.Stamp(timeZone: self.calendar.timeZone) }

        func run() async throws -> DeviceNodeResult {
            let stamp = self.stamp
            if self.request.mode == .statistics {
                let buckets = try await self.entry.kind == .category
                    ? self.categoryStatistics(stamp) : self.quantityStatistics(stamp)
                return HealthQuery.result(HealthQuery.statisticsPayload(self.request, buckets: buckets, stamp: stamp))
            }
            switch self.entry.kind {
            case .quantity: return try await self.samples(self.quantityRows(stamp), stamp)
            case .category: return try await self.samples(self.categoryRows(stamp), stamp)
            case .correlation:
                return self.entry.name == "food"
                    ? try await self.samples(self.foodRows(stamp), stamp)
                    : try await self.samples(self.bloodPressureRows(stamp), stamp)
            case .workout: return try await self.samples(self.workoutRows(stamp), stamp)
            case .electrocardiogram: return try await self.samples(self.electrocardiogramRows(stamp), stamp)
            case .audiogram: return try await self.samples(self.audiogramRows(stamp), stamp)
            case .stateOfMind: return try await self.samples(self.stateOfMindRows(stamp), stamp)
            case .scoredAssessment: return try await self.samples(self.assessmentRows(stamp), stamp)
            case .activitySummary: return try await self.samples(self.activitySummaryRows(stamp), stamp)
            }
        }

        private func samples<Row: Codable & Sendable & Equatable>(_ rows: [Row], _ stamp: HealthQuery.Stamp) -> DeviceNodeResult {
            HealthQuery.result(HealthQuery.samplesPayload(self.request, rows: rows, stamp: stamp))
        }

        // MARK: Fetching

        private var strictStart: NSPredicate {
            HKQuery.predicateForSamples(
                withStart: self.request.range.start, end: self.request.range.end, options: .strictStartDate)
        }

        private var overlapping: NSPredicate {
            HKQuery.predicateForSamples(withStart: self.request.range.start, end: self.request.range.end, options: [])
        }

        private func fetch<Sample: HKSample>(_ predicate: HKSamplePredicate<Sample>) async throws -> [Sample] {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [predicate],
                sortDescriptors: [SortDescriptor(\.startDate, order: self.request.sort == .asc ? .forward : .reverse)],
                limit: self.request.limit + 1)
            let samples = try await descriptor.result(for: self.store)
            try Task.checkCancellation()
            return samples
        }

        private var quantityType: HKQuantityType? { HealthQueryAccess.resolved[self.entry.name] as? HKQuantityType }

        private static func source(_ sample: HKSample) -> String { sample.sourceRevision.source.name }

        private static func userEntered(_ sample: HKSample) -> Bool? {
            (sample.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue == true ? true : nil
        }

        private static func value(_ quantity: HKQuantity, _ entry: HealthQuery.Entry) throws -> Double {
            guard let unit = HealthQueryAccess.unit(entry.unit) else { throw HealthQuery.readFailed }
            let value = quantity.doubleValue(for: unit)
            return HealthQuery.round(entry.isPercent ? value * 100 : value)
        }

        private func end(_ sample: HKSample, _ stamp: HealthQuery.Stamp) -> String? {
            sample.endDate == sample.startDate ? nil : stamp.string(sample.endDate)
        }

        // MARK: Samples

        private func quantityRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.QuantityRow] {
            guard let type = self.quantityType else { throw HealthQuery.readFailed }
            return try await self.fetch(.quantitySample(type: type, predicate: self.strictStart)).map { sample in
                try HealthQuery.QuantityRow(
                    start: stamp.string(sample.startDate), end: self.end(sample, stamp),
                    value: Self.value(sample.quantity, self.entry), source: Self.source(sample),
                    userEntered: Self.userEntered(sample))
            }
        }

        private func categoryRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.CategoryRow] {
            guard let type = HealthQueryAccess.resolved[self.entry.name] as? HKCategoryType else {
                throw HealthQuery.readFailed
            }
            let hasValues = self.entry.values != nil
            return try await self.fetch(.categorySample(type: type, predicate: self.strictStart)).map { sample in
                HealthQuery.CategoryRow(
                    start: stamp.string(sample.startDate), end: stamp.string(sample.endDate),
                    durationMinutes: HealthQuery.minutes(sample.endDate.timeIntervalSince(sample.startDate)),
                    value: hasValues ? sample.value : nil, valueName: hasValues ? self.entry.valueName(sample.value) : nil,
                    source: Self.source(sample), userEntered: Self.userEntered(sample))
            }
        }

        private func correlations() async throws -> [HKCorrelation] {
            guard let type = HealthQueryAccess.resolved[self.entry.name] as? HKCorrelationType else {
                throw HealthQuery.readFailed
            }
            return try await self.fetch(.correlation(type: type, predicate: self.strictStart))
        }

        private func bloodPressureRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.BloodPressureRow] {
            let mmHg = HKUnit.millimeterOfMercury()
            func reading(_ correlation: HKCorrelation, _ id: HKQuantityTypeIdentifier) -> Double? {
                (correlation.objects(for: HKQuantityType(id)).first as? HKQuantitySample)
                    .map { HealthQuery.round($0.quantity.doubleValue(for: mmHg)) }
            }
            return try await self.correlations().map { correlation in
                HealthQuery.BloodPressureRow(
                    start: stamp.string(correlation.startDate), end: self.end(correlation, stamp),
                    systolic: reading(correlation, .bloodPressureSystolic),
                    diastolic: reading(correlation, .bloodPressureDiastolic), source: Self.source(correlation))
            }
        }

        private func foodRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.FoodRow] {
            try await self.correlations().map { correlation in
                let nutrients = correlation.objects.compactMap { object -> HealthQuery.Nutrient? in
                    guard let sample = object as? HKQuantitySample,
                          let entry = HealthQuery.entry(identifier: sample.quantityType.identifier),
                          let unit = entry.unit, let value = try? Self.value(sample.quantity, entry)
                    else { return nil }
                    return HealthQuery.Nutrient(type: entry.name, value: value, unit: unit)
                }.sorted { $0.type < $1.type }
                return HealthQuery.FoodRow(
                    start: stamp.string(correlation.startDate), end: self.end(correlation, stamp),
                    foodName: correlation.metadata?[HKMetadataKeyFoodType] as? String, nutrients: nutrients,
                    source: Self.source(correlation))
            }
        }

        private func workoutRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.WorkoutRow] {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let distances: [HKQuantityTypeIdentifier] = [
                .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair,
                .distanceDownhillSnowSports, .distanceCrossCountrySkiing, .distancePaddleSports, .distanceRowing,
                .distanceSkatingSports,
            ]
            return try await self.fetch(.workout(self.strictStart)).map { workout in
                let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
                let distance = distances.lazy.compactMap {
                    workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter())
                }.first
                return HealthQuery.WorkoutRow(
                    start: stamp.string(workout.startDate), end: stamp.string(workout.endDate),
                    activityType: HealthQuery.workoutActivityName(workout.workoutActivityType.rawValue),
                    durationMinutes: HealthQuery.minutes(workout.duration),
                    activeEnergyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
                        .map { HealthQuery.round($0.doubleValue(for: .kilocalorie())) },
                    distanceMeters: distance.map(HealthQuery.round),
                    averageHeartRateBpm: heartRate?.averageQuantity().map { HealthQuery.round($0.doubleValue(for: bpm)) },
                    maxHeartRateBpm: heartRate?.maximumQuantity().map { HealthQuery.round($0.doubleValue(for: bpm)) },
                    source: Self.source(workout))
            }
        }

        private func electrocardiogramRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.ElectrocardiogramRow] {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            return try await self.fetch(.electrocardiogram(self.strictStart)).map { ecg in
                HealthQuery.ElectrocardiogramRow(
                    start: stamp.string(ecg.startDate), end: stamp.string(ecg.endDate),
                    classification: HealthQuery.electrocardiogramClassification(ecg.classification.rawValue),
                    averageHeartRateBpm: ecg.averageHeartRate.map { HealthQuery.round($0.doubleValue(for: bpm)) },
                    symptomsStatus: HealthQuery.electrocardiogramSymptoms(ecg.symptomsStatus.rawValue),
                    samplingFrequencyHz: ecg.samplingFrequency.map { HealthQuery.round($0.doubleValue(for: .hertz())) },
                    voltageMeasurementCount: ecg.numberOfVoltageMeasurements, source: Self.source(ecg))
            }
        }

        private func audiogramRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.AudiogramRow] {
            try await self.fetch(.audiogram(self.strictStart)).map { audiogram in
                HealthQuery.AudiogramRow(
                    start: stamp.string(audiogram.startDate),
                    points: audiogram.sensitivityPoints.map(Self.point), source: Self.source(audiogram))
            }
        }

        private static func point(_ point: HKAudiogramSensitivityPoint) -> HealthQuery.AudiogramPoint {
            let dBHL = HKUnit.decibelHearingLevel()
            var result = HealthQuery.AudiogramPoint(frequencyHz: HealthQuery.round(point.frequency.doubleValue(for: .hertz())))
            if #available(iOS 18.1, *) {
                for test in point.tests where test.type == .air && !test.masked {
                    let value = HealthQuery.round(test.sensitivity.doubleValue(for: dBHL))
                    switch test.side {
                    case .left: result.leftEarDBHL = value
                    case .right: result.rightEarDBHL = value
                    @unknown default: break
                    }
                }
            } else {
                result.leftEarDBHL = point.leftEarSensitivity.map { HealthQuery.round($0.doubleValue(for: dBHL)) }
                result.rightEarDBHL = point.rightEarSensitivity.map { HealthQuery.round($0.doubleValue(for: dBHL)) }
            }
            return result
        }

        private func stateOfMindRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.StateOfMindRow] {
            try await self.fetch(.stateOfMind(self.strictStart)).map { mind in
                HealthQuery.StateOfMindRow(
                    start: stamp.string(mind.startDate), kind: HealthQuery.stateOfMindKind(mind.kind.rawValue),
                    valence: HealthQuery.round(mind.valence),
                    valenceClassification: HealthQuery.valenceClassification(mind.valenceClassification.rawValue),
                    labels: mind.labels.map { HealthQuery.stateOfMindLabel($0.rawValue) },
                    associations: mind.associations.map { HealthQuery.stateOfMindAssociation($0.rawValue) },
                    source: Self.source(mind))
            }
        }

        private func assessmentRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.AssessmentRow] {
            if self.entry.name == "gad7" {
                return try await self.fetch(.gad7Assessment(self.strictStart)).map {
                    HealthQuery.AssessmentRow(
                        start: stamp.string($0.startDate), score: $0.score, risk: HealthQuery.gad7Risk($0.risk.rawValue),
                        source: Self.source($0))
                }
            }
            return try await self.fetch(.phq9Assessment(self.strictStart)).map {
                HealthQuery.AssessmentRow(
                    start: stamp.string($0.startDate), score: $0.score, risk: HealthQuery.phq9Risk($0.risk.rawValue),
                    source: Self.source($0))
            }
        }

        private func activitySummaryRows(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.ActivitySummaryRow] {
            var calendar = self.calendar
            calendar.timeZone = self.request.timeZone
            func components(_ date: Date) -> DateComponents {
                var components = calendar.dateComponents([.era, .year, .month, .day], from: date)
                components.calendar = calendar
                return components
            }
            let lastDay = self.request.range.end.addingTimeInterval(-1)
            let predicate = HKQuery.predicate(
                forActivitySummariesBetweenStart: components(self.request.range.start), end: components(lastDay))
            let summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: self.store)
            try Task.checkCancellation()
            let dated = summaries.compactMap { summary -> (Date, HKActivitySummary)? in
                calendar.date(from: summary.dateComponents(for: calendar)).map { ($0, summary) }
            }.sorted { self.request.sort == .asc ? $0.0 < $1.0 : $0.0 > $1.0 }
            let kcal = HKUnit.kilocalorie()
            return dated.prefix(self.request.limit + 1).map { day, summary in
                HealthQuery.ActivitySummaryRow(
                    date: stamp.date(day),
                    activeEnergyKcal: HealthQuery.round(summary.activeEnergyBurned.doubleValue(for: kcal)),
                    activeEnergyGoalKcal: HealthQuery.round(summary.activeEnergyBurnedGoal.doubleValue(for: kcal)),
                    exerciseMinutes: HealthQuery.round(summary.appleExerciseTime.doubleValue(for: .minute())),
                    exerciseGoalMinutes: summary.exerciseTimeGoal.map { HealthQuery.round($0.doubleValue(for: .minute())) },
                    standHours: HealthQuery.round(summary.appleStandHours.doubleValue(for: .count())),
                    standGoalHours: summary.standHoursGoal.map { HealthQuery.round($0.doubleValue(for: .count())) })
            }
        }

        // MARK: Statistics

        private func quantityStatistics(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.Bucket] {
            guard let type = self.quantityType else { throw HealthQuery.readFailed }
            let cumulative = self.entry.aggregation == .cumulative
            let options: HKStatisticsOptions = cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
            let predicate = HKSamplePredicate.quantitySample(type: type, predicate: self.overlapping)
            func bucket(_ statistics: HKStatistics?, _ interval: DateInterval) throws -> HealthQuery.Bucket {
                var row = HealthQuery.Bucket(start: stamp.string(interval.start), end: stamp.string(interval.end))
                guard let statistics else { return row }
                if cumulative {
                    row.sum = try statistics.sumQuantity().map { try Self.value($0, self.entry) }
                } else {
                    row.average = try statistics.averageQuantity().map { try Self.value($0, self.entry) }
                    row.min = try statistics.minimumQuantity().map { try Self.value($0, self.entry) }
                    row.max = try statistics.maximumQuantity().map { try Self.value($0, self.entry) }
                }
                return row
            }
            if self.request.interval == .total {
                let statistics = try await HKStatisticsQueryDescriptor(predicate: predicate, options: options)
                    .result(for: self.store)
                return try [bucket(statistics, self.request.range)]
            }
            guard let anchor = self.request.buckets.first?.start else { return [] }
            let collection = try await HKStatisticsCollectionQueryDescriptor(
                predicate: predicate, options: options, anchorDate: anchor,
                intervalComponents: HealthQuery.intervalComponents(self.request.interval)).result(for: self.store)
            try Task.checkCancellation()
            return try self.request.buckets.map { try bucket(collection.statistics(for: $0.start), $0) }
        }

        private func categoryStatistics(_ stamp: HealthQuery.Stamp) async throws -> [HealthQuery.Bucket] {
            guard let type = HealthQueryAccess.resolved[self.entry.name] as? HKCategoryType else {
                throw HealthQuery.readFailed
            }
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: type, predicate: self.overlapping)],
                sortDescriptors: [SortDescriptor(\.endDate)], limit: HealthQuery.maxCategorySamples + 1)
            let samples = try await descriptor.result(for: self.store)
            try Task.checkCancellation()
            guard samples.count <= HealthQuery.maxCategorySamples else { throw HealthQuery.tooManyCategorySamples }
            return HealthQuery.categoryBuckets(
                samples.map { HealthQuery.CategorySample(start: $0.startDate, end: $0.endDate, value: $0.value) },
                entry: self.entry, buckets: self.request.buckets, stamp: stamp)
        }
    }

    /// The catalog's fixed units. Never `HKUnit(from:)`, which raises on a string it can't parse.
    static func unit(_ string: String?) -> HKUnit? {
        let kg = HKUnit.gramUnit(with: .kilo)
        return switch string {
        case "%": .percent()
        case "count": .count()
        case "count/min": .count().unitDivided(by: .minute())
        case "degC": .degreeCelsius()
        case "kg": kg
        case "g": .gram()
        case "S": .siemen()
        case "m": .meter()
        case "cm": .meterUnit(with: .centi)
        case "m/s": .meter().unitDivided(by: .second())
        case "kcal": .kilocalorie()
        case "kcal/(kg*hr)": .kilocalorie().unitDivided(by: kg.unitMultiplied(by: .hour()))
        case "min": .minute()
        case "ms": .secondUnit(with: .milli)
        case "W": .watt()
        case "appleEffortScore": .appleEffortScore()
        case "dBASPL": .decibelAWeightedSoundPressureLevel()
        case "ml/(kg*min)": .literUnit(with: .milli).unitDivided(by: kg.unitMultiplied(by: .minute()))
        case "mL": .literUnit(with: .milli)
        case "L": .liter()
        case "L/min": .liter().unitDivided(by: .minute())
        case "mmHg": .millimeterOfMercury()
        case "IU": .internationalUnit()
        case "mg/dL": .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        default: nil
        }
    }
}
#else
enum HealthAccess {
    static var isAvailable: Bool { false }
    static func request() async -> Bool { false }

    static func summary(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        .failure(code: "UNAVAILABLE", message: "HEALTH_UNAVAILABLE: Health data isn't available on this device")
    }
}
enum HealthQueryAccess {
    static var isAvailable: Bool { false }
    static func request() async -> Bool { false }

    /// Validation still runs first, so a Mac answers bad params like an iPhone would.
    static func query(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        switch HealthQuery.request(invoke.paramsJSON, now: Date(), calendar: .current) {
        case .success: HealthQuery.healthUnavailable.result
        case let .failure(failure): failure.result
        }
    }
}
#endif
