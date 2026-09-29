import Foundation
import Testing
@testable import PincerKit

@Suite struct ImageRefTests {
    private func inline(_ payload: String, alt: String? = nil) -> ImageRef {
        ImageRef(artifactId: nil, base64: payload, url: nil, mimeType: "image/png", alt: alt, width: 2, height: 3)
    }

    @Test func keyPrefersArtifactThenUrlThenInline() {
        #expect(ImageRef(artifactId: "a", base64: "x", url: "u", mimeType: nil, alt: nil, width: nil, height: nil).cacheKey == "a")
        #expect(ImageRef(artifactId: nil, base64: "x", url: "u", mimeType: nil, alt: nil, width: nil, height: nil).cacheKey == "u")
        #expect(ImageRef(artifactId: nil, base64: nil, url: nil, mimeType: nil, alt: nil, width: nil, height: nil).cacheKey == "image")
        #expect(self.inline("AAAA").cacheKey.hasPrefix("inline:4:"))
    }

    @Test func keyStableAcrossCopiesAndDecoding() throws {
        let ref = self.inline(String(repeating: "QUJD", count: 1000))
        let copy = ref
        #expect(copy.cacheKey == ref.cacheKey)
        let decoded = try JSONDecoder().decode(ImageRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded.cacheKey == ref.cacheKey)
        #expect(decoded == ref)
        #expect(decoded.hashValue == ref.hashValue)
    }

    @Test func distinctPayloadsDiffer() {
        let a = self.inline("QUJDRA==")
        let b = self.inline("QUJDRQ==")
        #expect(a.cacheKey != b.cacheKey)
        #expect(a != b)
    }

    @Test func codableShapeUnchanged() throws {
        let ref = self.inline("QUJD", alt: "hi")
        let data = try JSONEncoder().encode(ref)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["base64", "mimeType", "alt", "width", "height"])
        let legacy = Data(#"{"base64":"QUJD","mimeType":"image/png","alt":"hi","width":2,"height":3}"#.utf8)
        #expect(try JSONDecoder().decode(ImageRef.self, from: legacy) == ref)
    }
}
