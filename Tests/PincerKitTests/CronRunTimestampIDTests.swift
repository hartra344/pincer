import Foundation
import Testing
@testable import PincerKit

struct CronRunTimestampIDTests {
    @Test func ordinaryFallbackAndExplicitRunIDsKeepTheirIdentity() throws {
        let ordinary = try #require(CronRun(Fixtures.json(#"{"jobId":"job-fixture","action":"finished","ts":1700000000123,"status":"ok"}"#)))
        #expect(ordinary.id == "job-fixture@1700000000123")
        #expect(ordinary.jobId == "job-fixture" && ordinary.status == .ok)
        let explicit = try #require(CronRun(Fixtures.json(#"{"jobId":"job-fixture","action":"finished","ts":1e30,"runAtMs":1700000000123,"runId":"explicit-run"}"#)))
        #expect(explicit.id == "explicit-run")
        #expect(explicit.startedAt == Date(timeIntervalSince1970: 1700000000.123))
        #expect(CronRun(Fixtures.json(#"{"ts":1700000000123}"#)) == nil)
    }

    @Test func oversizedTimestampWithoutOptionalRunIDCannotTrap() throws {
        // Upstream CronRunLogEntrySchema: ts is an integer >= 0 with no maximum; runId optional.
        // Ordinary runAtMs isolates the fallback identity conversion from date formatting.
        let source = Fixtures.json(#"{"jobId":"job-fixture","action":"finished","ts":1e30,"runAtMs":1700000000123,"status":"ok"}"#)
        let first = try #require(CronRun(source))
        let second = try #require(CronRun(source))
        #expect(!first.id.isEmpty && first.id == second.id)
        #expect(first.jobId == "job-fixture" && first.status == .ok)
        #expect(first.startedAt == Date(timeIntervalSince1970: 1700000000.123))
    }
}
