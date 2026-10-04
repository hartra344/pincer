import Foundation
@testable import PincerKit
@testable import PincerUI
import Testing

@MainActor @Suite("Premeasure source admission", .serialized)
struct PremeasureAdmissionTests {
    @Test(arguments: ["large", "foreign", "grapheme"])
    func actualDriverDoesNotPrepareFullSourcesOnMain(kind: String) async throws {
        let pieces = await Task.detached { () -> [String] in
            switch kind {
            case "foreign": return [NSString(string: String(repeating: "\u{2003}", count: 20_000) + "Visible") as String, "Second"]
            case "grapheme": return ["a" + String(repeating: "\u{301}", count: 100_000), "Second"]
            default: return [String(repeating: "A", count: 1_048_576), String(repeating: "B", count: 1_048_576)]
            }
        }.value
        if kind == "foreign" { try #require(!pieces[0].isContiguousUTF8) }
        let item = ChatItem(id: "admission-\(kind)", role: .user, blocks: pieces.map { .text($0) })
        let row = TranscriptRow.entry(.user(item))
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let driver = TranscriptPremeasureDriver()
        driver.currentRow = { id in id == row.id ? row : nil }
        PremeasureAdmissionProbe.register(row.id)
        defer { PremeasureAdmissionProbe.remove(row.id) }
        let split = driver.split([0], all: [row], width: 360, renderer: renderer)
        #expect(!split.offload.isEmpty || !split.measureNow.isEmpty, "real driver handles the actual row")
        let cost = PremeasureAdmissionProbe.snapshot(row.id)
        #expect(cost.mainJoins == 0)
        #expect(cost.mainSizes == 0)
        #expect(cost.mainWarmLookups == 0)
    }

    @Test func realWorkerMeasurementAndAdoptionRemainReachable() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let driver = TranscriptPremeasureDriver()
        let row = TranscriptRow.entry(.user(ChatItem(id: "admission-control", role: .user,
            blocks: [.text("First actual paragraph"), .text("Second actual paragraph")])) )
        driver.currentRow = { id in id == row.id ? row : nil }
        PremeasureAdmissionProbe.register(row.id)
        defer { PremeasureAdmissionProbe.remove(row.id) }
        let job = try #require(driver.split([0], all: [row], width: 360, renderer: renderer).offload.first)
        #expect(job.bodies.isEmpty && job.sourceRow == nil, "admission retains no prepared source")
        let result = TranscriptPremeasurer.shared.measureWithin(5, jobs: [job], env: renderer.textEnvironment, epoch: driver.epoch)
        #expect(result.count == 1)
        #expect(result.first?.bodies.first?.key.source == "First actual paragraph\n\nSecond actual paragraph")
        #expect(!driver.adopt(result, width: 360, epoch: driver.epoch.current).isEmpty)
        #expect(PremeasureAdmissionProbe.snapshot(row.id).offMainMeasurements > 0)
        driver.cancelAll()
        #expect(driver.adopt(result, width: 360, epoch: driver.epoch.current).isEmpty, "stale real result remains rejected")
    }
}

#if DEBUG
import Synchronization

private final class PremeasureHeldSource: Sendable {
    let entered = Mutex(false)
    private let released = DispatchSemaphore(value: 0)
    func hold() {
        self.entered.withLock { $0 = true }
        _ = self.released.wait(timeout: .now() + 15)
    }
    func release() { self.released.signal() }
}

extension PremeasureAdmissionTests {
    @Test(.timeLimit(.minutes(2))) func globalStyleAdmissionKeepsOnlyOneActiveSourceAnd64WaitingDescriptors() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let service = TranscriptPremeasureAdmission()
        let gate = PremeasureHeldSource()
        defer { gate.release(); service.beforeSourcePreparation = nil }
        let rows = (0..<80).map { index in
            TranscriptRow.entry(.user(ChatItem(id: "lease-\(index)", role: .user, blocks: [.text("Exact body \(index)")])) )
        }
        let heldRowID = rows[0].id
        service.beforeSourcePreparation = { id in if id == heldRowID { gate.hold() } }
        let first = TranscriptPremeasureDriver(admission: service)
        let second = TranscriptPremeasureDriver(admission: service)
        first.currentRow = { id in rows.first { $0.id == id } }
        second.currentRow = first.currentRow
        let firstJobs = first.split(Array(0..<40), all: rows, width: 360, renderer: renderer).offload
        let secondJobs = second.split(Array(40..<80), all: rows, width: 360, renderer: renderer).offload
        #expect((firstJobs + secondJobs).allSatisfy { $0.bodies.isEmpty && $0.sourceRow == nil })
        first.submit(firstJobs, width: 360, env: renderer.textEnvironment) {}
        second.submit(secondJobs, width: 360, env: renderer.textEnvironment) {}
        #expect(await eventually { gate.entered.withLock { $0 } })
        #expect(service.active && service.pendingCount == 64)
        // Busy synchronous width warmup must return immediately without needing Main on the worker.
        #expect(first.prewarm([79], all: rows, width: 360, renderer: renderer, budget: 0.01) == 0)
        second.cancelAll()
        #expect(service.pendingCount < 64, "owner cancellation releases waiting descriptors")
        gate.release()
        #expect(await eventually(timeout: .seconds(15)) { !service.active && service.pendingCount == 0 })
        #expect(first.stats.adopted == 40)
        #expect(second.stats.adopted == 0, "cancelled source owner never adopts old results")
    }

    @Test(.timeLimit(.minutes(2))) func connectedDemoControllerPublishesExactWorkerSources() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        gateway.start()
        gateway.reconnectIfNeeded()
        #expect(await eventually(timeout: .seconds(15)) { gateway.state.isConnected })
        let chat = gateway.chat(for: "agent:main:dashboard:garden")
        await chat.load()
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: gateway.agent("main"), sessionKey: chat.sessionKey,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let controller = TranscriptListController(context: context, prefetchBudget: 0.004)
        let rows = TranscriptRow.rows(for: chat)
        _ = controller.accept(rows, contextChanged: false)
        let jobs = controller.premeasure.split(Array(rows.indices), all: controller.rows, width: 360, renderer: controller.renderer).offload
        #expect(!jobs.isEmpty)
        var ready = false
        controller.premeasure.submit(jobs, width: 360, env: controller.renderer.textEnvironment) { ready = true }
        #expect(await eventually(timeout: .seconds(15)) { ready && controller.premeasure.inFlightCount == 0 })
        #expect(controller.premeasureStats.adopted > 0)
        let user = try #require(rows.first { if case .entry(.user) = $0 { true } else { false } })
        let layout = controller.renderer.layout(for: user, width: 360)
        #expect(layout.height.isFinite && layout.height > 0)
    }
}
#endif

#if DEBUG
@MainActor
private final class WaitingPremeasureOwner {
    let row: TranscriptRow
    let driver: TranscriptPremeasureDriver
    let renderer: TranscriptRenderer
    init(id: String, renderer: TranscriptRenderer, service: TranscriptPremeasureAdmission) {
        self.row = .entry(.user(ChatItem(id: id, role: .user, blocks: [.text("Exact \(id)")])) )
        self.renderer = renderer
        self.driver = TranscriptPremeasureDriver(admission: service)
        self.driver.currentRow = { [weak self] id in self?.row.id == id ? self?.row : nil }
    }
    func enqueue() {
        let jobs = self.driver.split([0], all: [self.row], width: 360, renderer: self.renderer).offload
        self.driver.submit(jobs, width: 360, env: self.renderer.textEnvironment) { [weak self] in
            guard let self, self.driver.stats.adopted == 0 else { return }
            self.enqueue()
        }
    }
}

extension PremeasureAdmissionTests {
    @Test(.timeLimit(.minutes(2))) func sixtyFiveDeniedOwnersRetryAutomaticallyAndDeadOwnersReleaseObservation() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let service = TranscriptPremeasureAdmission()
        let gate = PremeasureHeldSource()
        defer { gate.release(); service.beforeSourcePreparation = nil }
        let rows = (0..<64).map { index in
            TranscriptRow.entry(.user(ChatItem(id: "capacity-blocked-\(index)", role: .user, blocks: [.text("Body \(index)")])) )
        }
        let heldRowID = rows[0].id
        service.beforeSourcePreparation = { id in if id == heldRowID { gate.hold() } }
        let blocker = TranscriptPremeasureDriver(admission: service)
        blocker.currentRow = { id in rows.first { $0.id == id } }
        blocker.submit(blocker.split(Array(rows.indices), all: rows, width: 360, renderer: renderer).offload,
                       width: 360, env: renderer.textEnvironment) {}
        let filler = WaitingPremeasureOwner(id: "capacity-filler", renderer: renderer, service: service)
        filler.enqueue()
        #expect(await eventually { gate.entered.withLock { $0 } })
        #expect(service.pendingCount == 64)
        var owners: [WaitingPremeasureOwner?] = (0..<65).map {
            WaitingPremeasureOwner(id: "denied-owner-\($0)", renderer: renderer, service: service)
        }
        for owner in owners { owner?.enqueue() }
        #expect(service.observationCount == 65, "the 65th entirely denied owner also gets a capacity wakeup")
        weak var removed = owners[0]?.driver
        owners[0] = nil
        #expect(removed == nil && service.observationCount == 64,
                "deallocation removes the real observation without retaining the source owner")
        gate.release()
        #expect(await eventually(timeout: .seconds(15)) {
            owners.dropFirst().allSatisfy { $0?.driver.stats.adopted == 1 }
                && !service.active && service.pendingCount == 0
        }, "every remaining denied owner automatically replans and adopts after capacity releases")
        #expect(service.observationCount == 0)
    }
}
#endif
