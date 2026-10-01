#if os(macOS)
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Suite("Channel error disclosure", .serialized)
struct ChannelErrorDisclosureHostedTests {
    private let error = "getUpdates: 409 Conflict: terminated by another getUpdates request; make sure that only one bot instance is running. The remote endpoint rejected the poll and will retry after its connection is corrected."

    @Test func collapsedDisclosureShowsASeparateControlAndExpandedTextUsesMoreSpace() throws {
        let collapsed = ChannelErrorDisclosure(error: self.error, isExpanded: .constant(false))
            .font(.caption)
            .foregroundStyle(.red)
            .frame(width: 340, alignment: .leading)
        let expanded = ChannelErrorDisclosure(error: self.error, isExpanded: .constant(true))
            .font(.caption)
            .foregroundStyle(.red)
            .frame(width: 340, alignment: .leading)
        let textOnly = Text(self.error)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .textSelection(.enabled)
            .frame(width: 340, alignment: .leading)

        let collapsedHeight = try Self.renderedHeight(of: collapsed)
        let expandedHeight = try Self.renderedHeight(of: expanded)
        let textHeight = try Self.renderedHeight(of: textOnly)

        #expect(collapsedHeight > textHeight,
                "The collapsed disclosure must include a visible control below the selectable error text")
        #expect(expandedHeight > collapsedHeight,
                "Expanded disclosure must show the full error text")
    }

    private static func renderedHeight<Content: View>(of content: Content) throws -> Int {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "SwiftUI should render the channel error disclosure")
        return image.height
    }
}
#endif
