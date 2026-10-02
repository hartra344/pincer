import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PincerKit

private final class SharePreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0
    private var wasMain = false

    var ranOnMain: Bool { lock.withLock { wasMain } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func open() { release.signal() }
    func probe() {
        let first = lock.withLock {
            calls += 1
            wasMain = wasMain || Thread.isMainThread
            return calls == 1
        }
        if first {
            entered.signal()
            if !Thread.isMainThread { release.wait() }
        }
    }
}

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

    @Test func savedPolicySizesContentBeforeConnecting() async throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let model = ShareModel(profiles: [tight], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.isEmpty, "the selected Gateway's saved limit rejects the oversized file")
        #expect(model.attachmentProblems.count == 1)
        #expect(model.attachmentProblems.first?.contains("last known limit") == true)
    }

    @Test func changingGatewayRecomputesPreviouslyPreparedContent() async throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let model = ShareModel(profiles: [roomy, tight], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.count == 1)
        model.profileId = tight.id
        #expect(model.attachments.isEmpty, "old Gateway attachments disappear as soon as selection changes")
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.isEmpty, "prepared attachments must not carry over from another Gateway")
        #expect(model.attachmentProblems.first?.contains("last known limit") == true)
    }

    @Test func changingFromTightToRoomyUsesThatGatewayPolicy() async throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let larger = UploadPolicy(maxPayload: nil, maxImageBytes: nil, maxAttachmentBytes: 2_000)
        scratch.defaults.set(try JSONEncoder().encode(larger), forKey: GatewayStore.uploadPolicyKey(roomy.id))
        let model = ShareModel(profiles: [tight, roomy], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.isEmpty)
        model.profileId = roomy.id
        #expect(model.attachmentProblems.isEmpty, "the previous Gateway's rejection disappears immediately")
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.map(\.fileName) == ["report.pdf"])
        #expect(model.attachmentProblems.isEmpty)
    }

    @Test func malformedSavedPolicyUsesDefaultLimits() async {
        defer { scratch.remove() }
        scratch.defaults.set(Data("not JSON".utf8), forKey: GatewayStore.uploadPolicyKey(tight.id))
        let model = ShareModel(profiles: [tight], identity: nil, defaults: scratch.defaults)
        model.setContent(content)
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.map(\.fileName) == ["report.pdf"])
        #expect(model.attachmentProblems.isEmpty)
    }

    @Test func switchingGatewayWhileWorkerIsHeldKeepsUIResponsiveAndDiscardsStaleResult() async throws {
        defer { scratch.remove() }
        try saveTightPolicy()
        let gate = SharePreparationGate()
        defer { gate.open() }
        let model = ShareModel(profiles: [roomy, tight], identity: nil, defaults: scratch.defaults)
        model.attachmentPreparationProbe = gate.probe
        model.setContent(content)
        let entered = await Task.detached { gate.waitForEntry() }.value
        #expect(entered)
        #expect(!gate.ranOnMain, "local decoding and preparation cannot block the share-sheet actor")
        let start = ContinuousClock.now
        model.profileId = tight.id
        #expect(ContinuousClock.now - start < PerfBudget.limit(.milliseconds(100)))
        #expect(model.isPreparingAttachments)
        #expect(model.attachments.isEmpty && model.attachmentProblems.isEmpty)
        gate.open()
        await model.waitForAttachmentPreparation()
        #expect(model.attachments.isEmpty, "the cancelled roomy result never overwrites the tight Gateway's result")
        #expect(model.attachmentProblems.first?.contains("last known limit") == true)
    }
}
