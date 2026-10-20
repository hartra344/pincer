import CoreGraphics
import Foundation
import ImageIO
import PincerKit
import UniformTypeIdentifiers

@MainActor
func runRefactorPass3Checks() {
    let context = ImageEncoding.bitmapContext(width: 4, height: 3, alpha: .premultipliedLast)
    check(context?.width == 4 && context?.height == 3 && context?.alphaInfo == .premultipliedLast, "ImageEncoding bitmap context")
    if let image = context?.makeImage() {
        let png = ImageEncoding.data(image, type: .png)
        let jpeg = ImageEncoding.data(image, type: .jpeg, quality: 0.8)
        let pngSource = png.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        let jpegSource = jpeg.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        check(pngSource.flatMap { CGImageSourceGetType($0) as String? } == UTType.png.identifier, "ImageEncoding PNG")
        check(jpegSource.flatMap { CGImageSourceGetType($0) as String? } == UTType.jpeg.identifier, "ImageEncoding JPEG")
    } else {
        check(false, "ImageEncoding image")
    }

    let provider = try? JSONDecoder().decode(TTSProvider.self, from: Data(#"{"id":"openai","name":"OpenAI","configured":true}"#.utf8))
    check(provider?.id == "openai", "JSONValueDecodable decodes")
    var failure: String?
    do { _ = try JSONDecoder().decode(TTSStatus.self, from: Data("[1]".utf8)) } catch let DecodingError.dataCorrupted(context) {
        failure = context.debugDescription
    } catch {}
    check(failure == "not an object", "JSONValueDecodable keeps the failure text")

    let groups = Reactions.groups(agent: ["👍", "👍"], agentName: "Ada", mine: ["🎉", "👍"])
    check(groups == [ReactionGroup(emoji: "👍", actors: [.agent("Ada"), .you]), ReactionGroup(emoji: "🎉", actors: [.you])],
          "reaction groups keep first-seen order and dedupe actors")
}
