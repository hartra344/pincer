import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit

@MainActor
@Suite("Share upload policy")
struct ShareUploadPolicyTests {
    let scratch = ScratchDefaults()
    let tight = GatewayProfile(name: "Tight", url: "ws://127.0.0.1:9", authMode: .none)
    let roomy = GatewayProfile(name: "Roomy", url: "ws://127.0.0.1:10", authMode: .none)

    var content: SharedContent {
        SharedContent(files: [SharedFile(name: "report.pdf", typeIdentifier: UTType.pdf.identifier, data: Data(count: 1_000))])
    }

    func saveTightPolicy() throws {
        let policy = UploadPolicy(maxPayload: nil, maxImageBytes: nil, maxAttachmentBytes: 100)
        scratch.defaults.set(try JSONEncoder().encode(policy), forKey: GatewayStore.uploadPolicyKey(tight.id))
    }

    @Test func savedPolicySizesContentBeforeConnecting() throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let model = ShareModel(profiles: [tight], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        #expect(model.attachments.isEmpty, "the selected Gateway's saved limit rejects the oversized file")
        #expect(model.attachmentProblems.count == 1)
        #expect(model.attachmentProblems.first?.contains("last known limit") == true)
    }

    @Test func changingGatewayRecomputesPreviouslyPreparedContent() throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let model = ShareModel(profiles: [roomy, tight], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        #expect(model.attachments.count == 1)
        model.profileId = tight.id
        #expect(model.attachments.isEmpty, "prepared attachments must not carry over from another Gateway")
        #expect(model.attachmentProblems.first?.contains("last known limit") == true)
    }
}
