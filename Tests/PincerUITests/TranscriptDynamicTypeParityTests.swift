#if os(iOS)
import Foundation
@testable import PincerKit
import Testing
import UIKit
@testable import PincerUI

/// #434: the premeasure worker builds text from a snapshot of the main-actor fonts and applies `withTraits` off main.
/// At a non-default Dynamic Type size its sizes must still equal what main measures. (AppKit has no Dynamic Type, so
/// `TranscriptPremeasureTests.workerSizesMatchMainSizes` is its only parity gate.)
@MainActor
@Suite("TranscriptDynamicTypeParity", .serialized)
struct TranscriptDynamicTypeParityTests {
    static let sources = TranscriptPremeasureTests.sources + [
        "Mixed **bold _and italic_** runs, ~~struck~~ text, `code` and a [link](https://example.com) that wrap across several lines at large sizes.",
        "| Name | Notes |\n|---|---:|\n| alpha | a fairly long note that has to wrap in a narrow column, more than once |\n| beta | short |",
    ]

    /// An environment whose fonts were built at `category`, from a private style: `TranscriptStyle.reload()` would bump
    /// the shared generation, and suites running alongside (TranscriptPremeasure) would drop their in-flight results.
    /// Each category gets its own negative generation, so the worker never mixes up sizes between them.
    static func environment(at category: UIContentSizeCategory) -> TextBuildEnvironment {
        let shared = TextBuildEnvironment.current(dark: false)
        let generations: [UIContentSizeCategory: Int] = [.large: -1, .accessibilityLarge: -2, .accessibilityExtraExtraExtraLarge: -3]
        return TextBuildEnvironment(fonts: TranscriptFonts(TranscriptStyle(textSize: category)), colors: shared.colors,
                                    styleGeneration: generations[category]!, dark: false, mathScale: shared.mathScale)
    }

    @Test func buildingAnEnvironmentLeavesTheSharedStyleAlone() {
        let generation = TranscriptStyle.generation
        _ = Self.environment(at: .accessibilityExtraExtraExtraLarge)
        #expect(TranscriptStyle.generation == generation)
    }

    private func premeasure(_ source: String, width: CGFloat, env: TextBuildEnvironment) async -> PremeasuredRow {
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: env.styleGeneration, dark: false)
        let job = PremeasureJob(rowId: "r", bodies: [key], contentWidth: width, epoch: 0)
        return await withCheckedContinuation { continuation in
            TranscriptPremeasurer.shared.submit([job], env: env, epoch: TranscriptPremeasureEpoch()) { continuation.resume(returning: $0[0]) }
        }
    }

    @Test(arguments: [UIContentSizeCategory.accessibilityLarge, .accessibilityExtraExtraExtraLarge])
    func workerSizesMatchMainSizesAtANonDefaultTextSize(_ category: UIContentSizeCategory) async throws {
        let defaultBody = Self.environment(at: .large).fonts.body.pointSize
        let env = Self.environment(at: category)
        let body = env.fonts.body.pointSize
        try #require(body > defaultBody, "the style follows the content size category (\(defaultBody) -> \(body))")
        var compared = 0
        for source in Self.sources {
            for width in [320, 480, 700] as [CGFloat] {
                let row = await premeasure(source, width: width, env: env)
                let result = try! #require(row.bodies.first)
                let main = TranscriptText.build(MarkdownCache.blocks(source), tone: .primary, env: env, hooks: .main(cached: false, dark: false))!
                #expect(result.segments.count == main.count)
                for height in result.heights {
                    let text: NSAttributedString
                    switch main[height.index] {
                    case let .text(string), let .quote(string), let .code(_, _, string): text = string
                    default: continue
                    }
                    let size = TranscriptText.size(text, width: height.width, exact: height.exact)
                    #expect(size.height == height.height && size.width == height.usedWidth,
                            "\(category.rawValue) at \(width): worker \(height.height) vs main \(size.height)")
                    compared += 1
                }
            }
        }
        #expect(compared > 0)
    }

    @Test func largerTextMeasuresTaller() async {
        let source = String(repeating: "A line of body text that wraps. ", count: 12)
        let normal = await premeasure(source, width: 360, env: Self.environment(at: .large))
        let large = await premeasure(source, width: 360, env: Self.environment(at: .accessibilityExtraExtraExtraLarge))
        let a = try! #require(normal.bodies.first?.heights.first), b = try! #require(large.bodies.first?.heights.first)
        #expect(b.height > a.height, "the worker's fonts follow the text size: \(a.height) -> \(b.height)")
    }
}
#endif
