#if DEBUG
import Foundation

/// Actual fetch terminal ownership used by ImageRSSProbe, independent of bounded cache retention.
@MainActor package func imageRSSPreparationIsComplete(_ loader: ArtifactImageLoader, admittedCount: Int) -> Bool {
    loader.activeImageFetchCount == 0
}

package struct ImageLoaderTerminalEvidence: Sendable {
    package let admitted: Int
    package let activeAtAdmission: Int
    package let retained: Int
    package let failures: Int
    package let terminal: Bool
    package let exactPixels: Bool
    package let probeReportsComplete: Bool
}

/// Real inline image decoding and eviction; no synthetic image results or Gateway overlay.
@MainActor package func inspectImageLoaderTerminal() async throws -> ImageLoaderTerminalEvidence {
    let payload = await Task.detached {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!.base64EncodedString()
    }.value
    let refs = (0..<3).map { number in
        ImageRef(artifactId: nil, base64: "data:image/png;n=\(number);base64,\(payload)", url: nil,
                 mimeType: "image/png", alt: nil, width: 1, height: 1)
    }
    let loader = ArtifactImageLoader(byteBudget: 1)
    for ref in refs { loader.load(ref, sessionKey: "agent:probe:main") }
    let admitted = loader.activeImageFetchCount
    let deadline = ContinuousClock.now + .seconds(15)
    // inFlight is removed by the actual fetch Task defer, after decode/publication.
    // Cancellation does not abandon those owned requests; drain before reporting cancellation.
    while loader.activeImageFetchCount != 0 && ContinuousClock.now < deadline {
        await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
    }
    try Task.checkCancellation()
    return ImageLoaderTerminalEvidence(admitted: refs.count, activeAtAdmission: admitted,
        retained: loader.images.count, failures: loader.failures.count,
        terminal: loader.activeImageFetchCount == 0,
        exactPixels: !loader.images.isEmpty && loader.images.values.allSatisfy { $0.width == 1 && $0.height == 1 },
        probeReportsComplete: imageRSSPreparationIsComplete(loader, admittedCount: refs.count))
}
#endif
