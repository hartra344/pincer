import Foundation
import Testing
@testable import PincerKit

/// #481: the Gateway's last-known upload limits are remembered per Gateway and used while offline.
@MainActor
@Suite("Upload policy")
struct UploadPolicyTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)

    func store(_ profile: GatewayProfile? = nil) -> GatewayStore {
        GatewayStore(profile: profile ?? self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
    }

    func save(_ policy: UploadPolicy, for profile: GatewayProfile) throws {
        self.scratch.defaults.set(try JSONEncoder().encode(policy), forKey: "pincer.uploadPolicy.\(profile.id)")
    }

    @Test func unknownPolicyFallsBackToDefaults() {
        defer { self.scratch.remove() }
        let store = self.store()
        #expect(store.lastUploadPolicy == nil)
        #expect(store.uploadLimits == UploadLimits(policy: nil))
        #expect(store.uploadLimits == UploadLimits(hello: nil), "same as today's defaults")
        #expect(!store.uploadLimitsKnown)
    }

    @Test func savedPolicyIsLoadedAtInit() throws {
        defer { self.scratch.remove() }
        let policy = UploadPolicy(maxPayload: 4_000_000, maxImageBytes: 1_000_000, maxAttachmentBytes: 2_000_000)
        try self.save(policy, for: self.profile)
        let store = self.store()
        #expect(store.lastUploadPolicy == policy)
        #expect(store.uploadLimitsKnown)
        #expect(store.uploadLimits == UploadLimits(policy: policy), "offline uses the last-known limits")
        #expect(store.uploadLimits.imageBytes == 1_000_000)
    }

    @Test func policiesAreKeyedPerGateway() throws {
        defer { self.scratch.remove() }
        let other = GatewayProfile(name: "Work", url: "ws://127.0.0.1:10", authMode: .none)
        try self.save(UploadPolicy(maxPayload: 1_000_000, maxImageBytes: 100_000, maxAttachmentBytes: 200_000), for: self.profile)
        #expect(self.store(other).lastUploadPolicy == nil, "another Gateway doesn't inherit it")
        #expect(self.store(other).uploadLimits == UploadLimits(policy: nil))
        #expect(self.store().lastUploadPolicy?.maxImageBytes == 100_000)
    }

    @Test func policyInitWithNilFieldsMatchesDefaults() {
        let partial = UploadPolicy(maxPayload: nil, maxImageBytes: nil, maxAttachmentBytes: nil)
        #expect(UploadLimits(policy: partial) == UploadLimits(policy: nil))
        let capped = UploadPolicy(maxPayload: 1_000_000, maxImageBytes: 5_000_000, maxAttachmentBytes: nil)
        #expect(UploadLimits(policy: capped).imageBytes <= 700_000, "still under 70% of the payload")
    }

    @Test func policyRoundTripsThroughCodable() throws {
        let policy = UploadPolicy(maxPayload: 26_214_400, maxImageBytes: 5_000_000, maxAttachmentBytes: 20_000_000)
        #expect(try JSONDecoder().decode(UploadPolicy.self, from: JSONEncoder().encode(policy)) == policy)
    }
}
