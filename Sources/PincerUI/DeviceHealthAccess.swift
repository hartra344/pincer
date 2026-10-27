import Foundation
import PincerKit
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
#else
enum HealthAccess {
    static var isAvailable: Bool { false }
    static func request() async -> Bool { false }

    static func summary(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        .failure(code: "UNAVAILABLE", message: "HEALTH_UNAVAILABLE: Health data isn't available on this device")
    }
}
#endif
