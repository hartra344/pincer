import Foundation
import Testing
@testable import PincerKit

@Suite("Demo long-chat usage and wording")
struct DemoLongChatUsageTests {
    @Test func longChatHasExplicitUsageMatchingItsSeededModel() throws {
        let seeded = DemoGateway.seed()
        let key = DemoGateway.longChatKey
        let session = try #require(seeded.sessions[key], "the showcased long chat exists")
        let replies = (seeded.transcripts[key] ?? []).filter { $0["role"]?.string == "assistant" }
        #expect(!replies.isEmpty, "the actual transcript contains replies to annotate")
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let params = UsageRequests.session(key: key, agentId: "main", range: .last(7, now: now), at: now)
        let payload = try DemoUsage.handle("sessions.usage", params,
                                           knownKeys: Set(seeded.sessions.keys), now: now)
        let result = try #require(SessionsUsageResult(payload))
        let usage = try #require(result.sessions.first { $0.key == key },
                                "the showcased long chat needs its own usage row")
        #expect((usage.usage?.totals.totalTokens ?? 0) > 0)
        #expect(usage.provider == session["modelProvider"]?.string && usage.model == session["model"]?.string)
        #expect(replies.allSatisfy { $0["provider"]?.string == usage.provider && $0["model"]?.string == usage.model },
                "transcript reply metadata and the usage drill-down agree")
    }

    @Test func longChatNamesTheBackupProductInSearchableProse() throws {
        let seeded = DemoGateway.seed()
        let messages = try #require(seeded.transcripts[DemoGateway.longChatKey])
        let prose = messages.flatMap { $0["content"]?.array ?? [] }.compactMap { $0["text"]?.string }
        #expect(prose.contains { $0.contains("Proxmox Backup Server") },
                "demo wording should name the product instead of working around a search fixture")
    }
}
