import CoreGraphics
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #561: both real edit counts should remain visible in a narrow transcript tool header.
@MainActor
@Suite("Narrow file edit header counts")
struct NarrowFileEditHeaderCountsTests {
    private struct Fixture {
        let edit: ToolFileEdit
        let header: TranscriptToolHeaderView
        let scratch: ScratchDefaults
    }

    @Test func oneAddedAndRemovedLineRemainVisibleAtNarrowAndWideWidths() throws {
        let narrow = try Self.card(width: 250)
        defer { narrow.scratch.remove() }
        let wide = try Self.card(width: 520)
        defer { wide.scratch.remove() }

        for (fixture, width) in [(narrow, CGFloat(250)), (wide, CGFloat(520))] {
            #expect(fixture.edit.additionsLabel == "+1" && fixture.edit.deletionsLabel == "−1")
            #expect(fixture.header.bounds.width > 0 && fixture.header.bounds.width <= width,
                    "the actual produced header fits within the requested row width")
            #expect(fixture.edit.primaryPath == "src/net/retry.ts")
            #expect(fixture.edit.statusLabel == "Edited")
            #expect(fixture.header.accessibilityText.contains("retry.ts")
                    && fixture.header.accessibilityText.contains("Edited")
                    && fixture.header.accessibilityText.contains("1 added")
                    && fixture.header.accessibilityText.contains("1 removed"),
                    "the real header retains its filename, status and counts")

            let ink = try Self.countInk(in: fixture.header)
            #expect(ink.deletion > 0, "the deleted-line count must paint red text (pixels: \(ink))")
            #expect(ink.addition > 0, "the added-line count must paint green text (pixels: \(ink))")
        }
    }

    private static func card(width: CGFloat) throws -> Fixture {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity())
        let sessionKey = "agent:main:narrow-edit-\(UUID().uuidString)"
        let context = TranscriptContext(
            gateway: gateway,
            disclosure: TranscriptDisclosure(),
            agent: AgentSummary(id: "main", name: "Main"),
            sessionKey: sessionKey,
            previewImage: { _ in },
            saveFile: { _, _ in },
            chat: gateway.chat(for: sessionKey))
        let renderer = TranscriptRenderer(context: context)
        let args = try #require(String(data: JSONSerialization.data(withJSONObject: [
            "path": "src/net/retry.ts",
            "old_string": "let delay = 1;\nlet retries = 2;",
            "new_string": "let delay = 2;\nlet retries = 2;",
        ]), encoding: .utf8))
        let tool = ToolActivity(id: "edit-\(UUID().uuidString)", name: "edit", arguments: args,
                                result: "Updated retry policy.", isError: false, isRunning: false)
        var turn = AssistantTurn(id: "turn-\(UUID().uuidString)", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: width)
        let part = try #require(layout.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(tool) = placed.part { return tool }
            return nil
        }.first)
        let edit = try #require(part.edit, "the actual layout builder must classify the produced edit")
        let row = TranscriptRowView(frame: CGRect(x: 0, y: 0, width: width, height: layout.height))
        row.apply(layout, actions: renderer)
        let header = try #require(Self.header(in: row), "the real row must configure its tool header")
        return Fixture(edit: edit, header: header, scratch: scratch)
    }

    private static func header(in view: TranscriptBaseView) -> TranscriptToolHeaderView? {
        for child in view.subviews {
            if let header = child as? TranscriptToolHeaderView { return header }
            if let container = child as? TranscriptBaseView, let found = Self.header(in: container) { return found }
        }
        return nil
    }

    private static func countInk(in view: TranscriptToolHeaderView) throws -> (deletion: Int, addition: Int) {
        #if os(macOS)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try #require(rep.cgImage)
        #else
        view.overrideUserInterfaceStyle = .light
        view.setNeedsDisplay()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // SwiftPM's hosted runner has no UIWindowScene. Invoke this configured native view's
        // actual drawing path in a renderer context instead of relying on snapshotting a windowless
        // hierarchy, which can return a blank image without indicating a layout failure.
        let image = try #require(UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.draw(view.bounds)
        }.cgImage)
        #endif
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return (0, 0) }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        var deletion = 0
        var addition = 0
        for pixel in 0..<(image.width * image.height) {
            let offset = pixel * 4
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
            guard bytes[offset + 3] > 160 else { continue }
            if red > 80 && red > green * 3 / 2 && red > blue * 3 / 2 { deletion += 1 }
            if green > 50 && green > red * 3 / 2 && green > blue * 11 / 10 { addition += 1 }
        }
        return (deletion, addition)
    }
}

#if os(iOS)
extension TranscriptUIKitHostedTests {
    @Test func narrowEditHeaderPaintsBothCounts() throws {
        try NarrowFileEditHeaderCountsTests().oneAddedAndRemovedLineRemainVisibleAtNarrowAndWideWidths()
    }
}
#endif
