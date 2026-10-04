#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct EmbeddedImageDecodeLeaseTests {
    actor Gate {
        var entered = 0, open = false
        var held: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            entered += 1
            if !open { await withCheckedContinuation { held.append($0) } }
        }
        func release() { open = true; let values = held; held = []; for value in values { value.resume() } }
    }
    @Test func activeBuffersAreBoundedAndCancellationKeepsActualLease() async throws {
        let fixture = await Task.detached {
            let data = Data(repeating: 42, count: 1024 * 1024)
            return (data, ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil))
        }.value
        let loader = ArtifactImageLoader(), probe = EmbeddedImageBase64Probe(), gate = Gate()
        loader.base64Probe = probe; loader.didDecodeInline = { await gate.hold() }
        let tasks = (0..<8).map { _ in Task { await loader.data(for: fixture.1, sessionKey: "fixture") } }
        defer { for task in tasks { task.cancel() }; Task { await gate.release() } }
        try await withTaskCancellationHandler {
            let deadline = ContinuousClock.now + .seconds(15)
            while (await gate.entered != 4 || loader.pendingInlineDecodeCount != 4) && ContinuousClock.now < deadline && !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(await gate.entered == 4 && loader.activeInlineDecodeCount == 4 && loader.pendingInlineDecodeCount == 4)
            tasks[0].cancel()
            tasks[7].cancel()
            #expect(await tasks[7].value == nil)
            #expect(loader.activeInlineDecodeCount == 4, "canceled active decoder retains its lease while the real worker is held")
            await gate.release()
            var outputs: [Data?] = []
            for task in tasks { outputs.append(await task.value) }
            #expect(outputs[0] == nil && outputs[7] == nil)
            #expect(outputs[1...6].allSatisfy { $0 == fixture.0 })
            #expect(loader.activeInlineDecodeCount == 0 && loader.pendingInlineDecodeCount == 0 && loader.peakInlineDecodeCount == 4)
            #expect(probe.snapshot().main == 0 && probe.snapshot().worker == 7)
        } onCancel: { for task in tasks { task.cancel() }; Task { await gate.release() } }
    }
}
#endif
