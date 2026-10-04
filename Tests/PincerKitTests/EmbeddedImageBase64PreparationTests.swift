#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct EmbeddedImageBase64PreparationTests {
    @Test func actualInlineDataDecodePreservesExactBytesWithoutMainWork() async {
        let fixture = await Task.detached {
            let data = Data(repeating: 42, count: 1024 * 1024)
            let encoded = data.base64EncodedString()
            func ref(_ value: String) -> ImageRef {
                ImageRef(artifactId: nil, base64: value, url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil)
            }
            return (data, ref(encoded), ref("data:image/png;base64," + encoded))
        }.value
        let loader = ArtifactImageLoader(), probe = EmbeddedImageBase64Probe()
        loader.base64Probe = probe
        #expect(await loader.data(for: fixture.1, sessionKey: "fixture") == fixture.0)
        #expect(await loader.data(for: fixture.2, sessionKey: "fixture") == fixture.0)
        let counts = probe.snapshot()
        #expect(counts.main == 0)
        #expect(counts.main + counts.worker == 2)
    }
    @Test func invalidAndExistingCapControlsRemainExact() async {
        let invalid = await Task.detached {
            ImageRef(artifactId: nil, base64: "!!!invalid!!!", url: nil, mimeType: "image/png", alt: nil, width: nil, height: nil)
        }.value
        let loader = ArtifactImageLoader()
        #expect(await loader.data(for: invalid, sessionKey: "fixture") == nil)
        #expect(ArtifactImageLoader.decodeBase64("QUJD", maxBytes: 3) == Data("ABC".utf8))
        #expect(ArtifactImageLoader.decodeBase64("QUJD", maxBytes: 2) == nil)
        #expect(ArtifactImageLoader.decodeBase64("data:image/png;base64,QUJD", maxBytes: 3) == Data("ABC".utf8))
    }
}
#endif
