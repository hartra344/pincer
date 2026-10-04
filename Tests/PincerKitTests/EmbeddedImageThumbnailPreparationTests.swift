#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct EmbeddedImageThumbnailPreparationTests {
    @Test func actualInlineThumbnailFetchCompletesWithoutMainBase64Decode() async throws {
        // Reuse the valid 1x1 PNG fixture from QueuedImagePreviewTests, prepared off Main.
        let fixture = await Task.detached {
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!
            return ImageRef(artifactId: nil, base64: data.base64EncodedString(), url: nil, mimeType: "image/png", alt: nil, width: 1, height: 1)
        }.value
        let loader = ArtifactImageLoader(), probe = EmbeddedImageBase64Probe()
        loader.base64Probe = probe
        loader.load(fixture, sessionKey: "fixture")
        let deadline = ContinuousClock.now + .seconds(15)
        while loader.activeImageFetchCount != 0 && ContinuousClock.now < deadline && !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(loader.activeImageFetchCount == 0, "actual fetch task must finish before pixel/cache/thread assertions")
        let image = try #require(loader.cached(fixture))
        #expect(image.width == 1 && image.height == 1)
        #expect(loader.imageCount == 1 && loader.decodedBytes == image.bytesPerRow * image.height && loader.failures.isEmpty)
        let counts = probe.snapshot()
        #expect(counts.main == 0)
        #expect(counts.main + counts.worker == 1)
        loader.load(fixture, sessionKey: "fixture")
        #expect(loader.activeImageFetchCount == 0 && probe.snapshot().main + probe.snapshot().worker == 1,
                "warm actual thumbnail lookup must not start another decoder")
    }
}
#endif
