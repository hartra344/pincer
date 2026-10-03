#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Observable
private final class ComposerSizingDiagnosticFixture {
    var text = ""
}

@MainActor
private struct ComposerSizingDiagnosticHost: View {
    @Bindable var fixture: ComposerSizingDiagnosticFixture

    var body: some View {
        ComposerTextView(
            placeholder: "Message", text: self.$fixture.text, maxLines: 12,
            onSubmit: {}, onMedia: { _ in }, autoFocus: { false })
            .frame(width: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Measures the real AppKit representable's sizeThatFits path for a few edited draft sizes.
/// Timings are diagnostic output only: SwiftUI scheduling and simulator load have no hard limit here.
@MainActor
@Suite("Composer sizing diagnostic", .serialized)
struct ComposerSizingDiagnosticTests {
    @Test func hostedComposerReportsActualSizingCostAndHeightCap() async throws {
        let fixture = ComposerSizingDiagnosticFixture()
        let host = NSHostingView(rootView: ComposerSizingDiagnosticHost(fixture: fixture))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            ComposerSizingProbe.reset(enabled: false)
            window.close()
        }

        ComposerSizingProbe.reset(enabled: true)
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.descendants(of: host).contains { $0 is ComposerNSTextView },
                "the hosted production ComposerTextView creates its native NSTextView")

        let text32KiB = Self.realisticText(bytes: 32 * 1024)
        let text128KiB = Self.realisticText(bytes: 128 * 1024)
        let cases: [(String, String)] = [
            ("short", "Short sizing control."),
            ("32 KiB", text32KiB),
            ("32 KiB trailing edit", text32KiB + "x"),
            ("128 KiB", text128KiB),
            ("128 KiB trailing edit", text128KiB + "x"),
        ]

        var output: [String] = []
        var maximumSampleCount = 0
        for (label, text) in cases {
            ComposerSizingProbe.reset(enabled: true)
            fixture.text = text
            host.rootView = ComposerSizingDiagnosticHost(fixture: fixture)
            await Task.yield()
            host.layoutSubtreeIfNeeded()

            let deadline = Date().addingTimeInterval(2)
            while !ComposerSizingProbe.samples.contains(where: { $0.attributedLength == text.utf16.count }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
                host.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()

            let samples = ComposerSizingProbe.samples.filter { $0.attributedLength == text.utf16.count }
            let sample = try #require(samples.last, "\(label) reaches the production attributed-string sizing function")
            let native = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerNSTextView }.first)
            let actualHeight = try #require(native.enclosingScrollView).frame.height
            maximumSampleCount = max(maximumSampleCount, ComposerSizingProbe.samples.count)
            let heightCap = ceil(sample.lineHeight * Double(sample.maxLines))
            #expect(!sample.isMainThread, "full-draft height measurement must run off the main thread")
            #expect(sample.width > 0 && sample.width <= 360.5)
            #expect(sample.lineHeight > 0 && sample.maxLines == 12)
            #expect(sample.returnedHeight <= heightCap + 0.5, "the composer retains its existing maximum height")
            #expect(abs(actualHeight - sample.returnedHeight) <= 1, "the actual native composer uses the measured height")
            if label == "short" {
                #expect(sample.returnedHeight <= sample.lineHeight + 1, "the short control remains a single-line composer")
            }
            let maximumElapsed = samples.map(\.elapsedNanoseconds).max() ?? 0
            let totalElapsed = samples.reduce(UInt64(0)) { $0 + $1.elapsedNanoseconds }
            output.append("\(label): utf16=\(sample.attributedLength), samples=\(samples.count), max=\(maximumElapsed)ns, total=\(totalElapsed)ns, width=\(sample.width), line=\(sample.lineHeight), maxLines=\(sample.maxLines), height=\(sample.returnedHeight), nativeHeight=\(actualHeight)")
        }

        #expect(maximumSampleCount <= 64, "diagnostic storage remains bounded for each fixture case")
        print("\nComposer sizing diagnostic (real hosted sizeThatFits)\n" + output.joined(separator: "\n"))
    }

    private static func realisticText(bytes: Int) -> String {
        let sentence = "The evening equipment check found a new vibration near the north pump, so the team recorded the readings and scheduled a follow-up inspection. "
        let repetitions = bytes / sentence.utf8.count
        let remainder = bytes % sentence.utf8.count
        return String(repeating: sentence, count: repetitions) + String(sentence.prefix(remainder))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
#endif
