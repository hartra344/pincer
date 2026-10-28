#if os(iOS) && canImport(HealthKit)
import Foundation
import HealthKit
import Testing
@testable import PincerKit
@testable import PincerUI

/// The `pincer.health.query` catalog against the simulator's real HealthKit (#1084).
@Suite("Health query catalog (HealthKit)")
struct HealthQueryCatalogTests {
    /// Catalog types newer than the deployment target, with the iOS version that adds them.
    static let newer: [String: OperatingSystemVersion] = [
        "heartRateVariabilityRMSSD": .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
        "menopausalState": .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
        "bleedingAfterMenopause": .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
        "hypertensionEvent": .init(majorVersion: 26, minorVersion: 2, patchVersion: 0),
    ]

    @Test func everyIdentifierResolvesOrIsNewerThanThisOS() {
        for entry in HealthQuery.catalog {
            if let type = HealthQueryAccess.resolved[entry.name] {
                if entry.kind == .quantity || entry.kind == .category || entry.kind == .correlation {
                    #expect(type.identifier == entry.identifier, "\(entry.name)")
                }
                continue
            }
            let version = Self.newer[entry.name]
            #expect(version != nil, "\(entry.name) doesn't resolve and isn't a known newer-OS type")
            if let version {
                #expect(!ProcessInfo.processInfo.isOperatingSystemAtLeast(version), "\(entry.name) should resolve here")
            }
        }
        #expect(!HealthQueryAccess.readTypes.isEmpty)
        #expect(!HealthQueryAccess.readTypes.contains { $0 is HKCorrelationType }, "correlations aren't authorized directly")
    }

    @Test func everyQuantityUnitParsesAndMatchesItsAggregation() {
        for entry in HealthQuery.catalog where entry.kind == .quantity {
            guard let type = HealthQueryAccess.resolved[entry.name] as? HKQuantityType else { continue }
            guard let string = entry.unit else { Issue.record("\(entry.name) has no unit"); continue }
            // Catalog strings are fixed, so parsing them here is safe; the runner never parses at all.
            let unit = HKUnit(from: string)
            #expect(HealthQueryAccess.unit(string) == unit, "\(entry.name): \(string)")
            #expect(type.is(compatibleWith: unit), "\(entry.name) is not compatible with \(string)")
            let cumulative = type.aggregationStyle == .cumulative
            #expect((entry.aggregation == .cumulative) == cumulative, "\(entry.name) aggregation")
        }
        for entry in HealthQuery.catalog where entry.kind == .correlation {
            if let unit = entry.unit { #expect(HealthQueryAccess.unit(unit) == HKUnit(from: unit), "\(entry.name)") }
        }
    }
}
#endif
