import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PincerKit

@Suite("Shared helpers (refactor pass 3)")
struct SharedHelpersPass3Tests {
    private func solidImage(alpha: CGImageAlphaInfo = .premultipliedLast) -> CGImage {
        let context = ImageEncoding.bitmapContext(width: 4, height: 3, alpha: alpha)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return context.makeImage()!
    }

    private func decoded(_ data: Data) -> (type: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (type, image.width, image.height)
    }

    @Test func bitmapContextMatchesTheInlineParameters() throws {
        for alpha in [CGImageAlphaInfo.premultipliedFirst, .premultipliedLast, .noneSkipLast] {
            let context = try #require(ImageEncoding.bitmapContext(width: 7, height: 5, alpha: alpha))
            #expect(context.width == 7 && context.height == 5)
            #expect(context.bitsPerComponent == 8)
            #expect(context.alphaInfo == alpha)
            #expect(context.colorSpace?.model == .rgb)
        }
        #expect(ImageEncoding.bitmapContext(width: 0, height: 5, alpha: .premultipliedLast) == nil)
    }

    @Test func encodesPNGAndJPEG() throws {
        let image = self.solidImage()
        let png = try #require(ImageEncoding.data(image, type: .png))
        #expect(self.decoded(png)?.type == UTType.png.identifier)
        #expect(self.decoded(png)?.width == 4 && self.decoded(png)?.height == 3)
        let jpeg = try #require(ImageEncoding.data(image, type: .jpeg, quality: 0.5))
        #expect(self.decoded(jpeg)?.type == UTType.jpeg.identifier)
    }

    @Test func jpegQualityAndPropertiesPassThrough() throws {
        let context = try #require(ImageEncoding.bitmapContext(width: 64, height: 64, alpha: .noneSkipLast))
        for x in 0..<64 { // noisy content so quality changes the size
            context.setFillColor(CGColor(red: CGFloat(x % 7) / 7, green: CGFloat(x % 5) / 5, blue: CGFloat(x % 3) / 3, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 64))
        }
        let image = try #require(context.makeImage())
        let low = try #require(ImageEncoding.data(image, type: .jpeg, quality: 0.1))
        let high = try #require(ImageEncoding.data(image, type: .jpeg, quality: 1))
        #expect(low.count < high.count)
        let rotated = try #require(ImageEncoding.data(image, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
        ]))
        let source = try #require(CGImageSourceCreateWithData(rotated as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyOrientation] as? UInt32 == CGImagePropertyOrientation.right.rawValue)
    }

    @Test func jsonValueDecodableDecodesAndKeepsTheFailureText() throws {
        let decoder = JSONDecoder()
        let provider = try decoder.decode(TTSProvider.self, from: Data(#"{"id":"openai","name":"OpenAI","configured":true}"#.utf8))
        #expect(provider.id == "openai" && provider.configured)
        #expect(provider == TTSProvider(JSONValue.object(["id": "openai", "name": "OpenAI", "configured": true])))
        for (type, text): (any Decodable.Type, String) in [(TTSProvider.self, "missing id"), (TTSProviderState.self, "missing id"),
                                                             (TTSPersona.self, "missing id"), (TTSStatus.self, "not an object")] {
            do {
                _ = try decoder.decode(type, from: Data("[1]".utf8))
                Issue.record("\(type) decoded an array")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.debugDescription == text)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func reactionGroupBuilderKeepsFirstSeenOrderAndDedupesActors() {
        var builder = ReactionGroupBuilder()
        builder.add("👍", .agent("Ada"))
        builder.add("🎉", .you)
        builder.add("👍", .you)
        builder.add("👍", .agent("Ada"))
        #expect(builder.groups == [ReactionGroup(emoji: "👍", actors: [.agent("Ada"), .you]),
                                   ReactionGroup(emoji: "🎉", actors: [.you])])
    }

    @Test func reactionGroupsUseTheBuilder() {
        let mine = Reactions.groups(agent: ["👍", "👍"], agentName: "Ada", mine: ["🎉", "👍"])
        #expect(mine == [ReactionGroup(emoji: "👍", actors: [.agent("Ada"), .you]), ReactionGroup(emoji: "🎉", actors: [.you])])
    }
}
