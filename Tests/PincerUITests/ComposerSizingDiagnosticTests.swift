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
    var width: CGFloat = 360
    var maxLines: Int = 12

    var body: some View {
        ComposerTextView(
            placeholder: "Message", text: self.$fixture.text, maxLines: self.maxLines,
            onSubmit: {}, onMedia: { _ in }, autoFocus: { false })
            .frame(width: self.width, alignment: .leading)
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
        let wrapText = Self.realisticText(bytes: 500)
        let styleText = Self.realisticText(bytes: 32 * 1024)
        let cases: [(label: String, text: String, width: CGFloat, maxLines: Int)] = [
            ("short", "Short sizing control.", 360, 12),
            ("32 KiB", text32KiB, 360, 12),
            ("32 KiB trailing edit", text32KiB + "x", 360, 12),
            ("128 KiB", text128KiB, 360, 12),
            ("128 KiB trailing edit", text128KiB + "x", 360, 12),
            ("wrapped wide", wrapText, 360, 12),
            ("wrapped narrow", wrapText, 180, 12),
            ("without trailing newline", "First line", 360, 12),
            ("trailing newline", "First line\n", 360, 12),
            ("same text fewer lines", styleText, 360, 3),
            ("same text restored line cap", styleText, 360, 12),
        ]

        var output: [String] = []
        var maximumSampleCount = 0
        var measuredHeights: [String: Double] = [:]
        for item in cases {
            let (label, text, width, maxLines) = item
            var previousHeight: CGFloat?
            if label.contains("trailing edit") {
                previousHeight = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerNSTextView }.first?.enclosingScrollView?.frame.height)
            }
            ComposerSizingProbe.reset(enabled: true)
            fixture.text = text
            host.rootView = ComposerSizingDiagnosticHost(fixture: fixture, width: width, maxLines: maxLines)
            host.layoutSubtreeIfNeeded()
            if let previousHeight {
                let native = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerNSTextView }.first)
                #expect(native.string == text)
                #expect(abs((native.enclosingScrollView?.frame.height ?? 0) - previousHeight) <= 1,
                        "same-width edits retain the completed multiline height while remeasuring")
            }
            await Task.yield()

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
            #expect(samples.allSatisfy { !$0.isMainThread }, "full-draft height measurement must run off the main thread")
            #expect(sample.width > 0 && sample.width <= Double(width) + 0.5)
            #expect(sample.lineHeight > 0 && sample.maxLines == maxLines)
            #expect(sample.returnedHeight <= heightCap + 0.5, "the composer retains its existing maximum height")
            #expect(abs(actualHeight - sample.returnedHeight) <= 1, "the actual native composer uses the measured height")
            if label == "short" {
                #expect(sample.returnedHeight <= sample.lineHeight + 1, "the short control remains a single-line composer")
            }
            measuredHeights[label] = sample.returnedHeight
            let maximumElapsed = samples.map(\.elapsedNanoseconds).max() ?? 0
            let totalElapsed = samples.reduce(UInt64(0)) { $0 + $1.elapsedNanoseconds }
            output.append("\(label): utf16=\(sample.attributedLength), samples=\(samples.count), max=\(maximumElapsed)ns, total=\(totalElapsed)ns, width=\(sample.width), line=\(sample.lineHeight), maxLines=\(sample.maxLines), height=\(sample.returnedHeight), nativeHeight=\(actualHeight)")
        }

        #expect(maximumSampleCount <= 64, "diagnostic storage remains bounded for each fixture case")
        #expect((measuredHeights["wrapped narrow"] ?? .zero) > (measuredHeights["wrapped wide"] ?? .greatestFiniteMagnitude))
        #expect((measuredHeights["trailing newline"] ?? .zero) > (measuredHeights["without trailing newline"] ?? .greatestFiniteMagnitude))
        #expect((measuredHeights["same text fewer lines"] ?? .greatestFiniteMagnitude)
                < (measuredHeights["same text restored line cap"] ?? .zero))
        print("\nComposer sizing diagnostic (real hosted sizeThatFits)\n" + output.joined(separator: "\n"))
    }

    @Test func speculativeWidthsDoNotSupersedeFiniteMeasurement() async throws {
        let measurement = ComposerHeightMeasurement()
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let text = Self.realisticText(bytes: 128 * 1024)
        var published = 0
        ComposerSizingProbe.reset(enabled: true)
        defer { ComposerSizingProbe.reset(enabled: false); measurement.detach() }

        _ = measurement.height(for: text, font: font, lineHeight: lineHeight,
                               width: 360, maxLines: 12, onHeightChange: { published += 1 })
        for width in [CGFloat.zero, .infinity] {
            _ = measurement.height(for: text, font: font, lineHeight: lineHeight,
                                   width: width, maxLines: 12, onHeightChange: { published += 1 })
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while published == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(published == 1, "transient sizing probes must not invalidate the finite-width result")
        let height = measurement.height(for: text, font: font, lineHeight: lineHeight,
                                        width: 360, maxLines: 12, onHeightChange: { published += 1 })
        #expect(height == ceil(lineHeight * 12))
        #expect(ComposerSizingProbe.samples.count == 1)
        #expect(ComposerSizingProbe.samples.allSatisfy { $0.width == 360 && !$0.isMainThread })
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

#if os(iOS)
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import PincerUI

@MainActor
@Observable
private final class IOSComposerSizingFixture {
    var text = ""
}

@MainActor
private struct IOSComposerSizingHost: View {
    @Bindable var fixture: IOSComposerSizingFixture

    var body: some View {
        ComposerTextView(
            placeholder: "Message", text: self.$fixture.text, maxLines: 12,
            onSubmit: {}, onMedia: { _ in }, autoFocus: { false })
            .frame(width: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
@Suite("iOS composer sizing diagnostic", .serialized)
struct IOSComposerSizingDiagnosticTests {
    @Test func hostedComposerMeasuresOffMainAndKeepsItsHeightCap() async throws {
        let fixture = IOSComposerSizingFixture()
        let host = UIHostingController(rootView: IOSComposerSizingHost(fixture: fixture))
        let window = UIWindow(frame: CGRect(x: -4000, y: -4000, width: 420, height: 700))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        defer {
            ComposerSizingProbe.reset(enabled: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        ComposerSizingProbe.reset(enabled: true)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(Self.descendants(of: host.view).contains { $0 is ComposerUITextView },
                "the hosted production ComposerTextView creates its native UITextView")

        let cases = [
            ("short", "Short sizing control."),
            ("32 KiB", Self.realisticText(bytes: 32 * 1024)),
            ("32 KiB trailing edit", Self.realisticText(bytes: 32 * 1024) + "x"),
            ("128 KiB", Self.realisticText(bytes: 128 * 1024)),
            ("128 KiB trailing edit", Self.realisticText(bytes: 128 * 1024) + "x"),
        ]
        var output: [String] = []
        var maximumSampleCount = 0

        for (label, text) in cases {
            var previousHeight: CGFloat?
            if label.contains("trailing edit") {
                previousHeight = try #require(Self.descendants(of: host.view).compactMap { $0 as? ComposerUITextView }.first?.bounds.height)
            }
            ComposerSizingProbe.reset(enabled: true)
            fixture.text = text
            host.rootView = IOSComposerSizingHost(fixture: fixture)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if let previousHeight {
                let native = try #require(Self.descendants(of: host.view).compactMap { $0 as? ComposerUITextView }.first)
                #expect(native.text == text)
                #expect(abs(native.bounds.height - previousHeight) <= 1,
                        "same-width edits retain the completed multiline height while remeasuring")
            }
            let deadline = Date().addingTimeInterval(2)
            while !ComposerSizingProbe.samples.contains(where: { $0.attributedLength == text.utf16.count }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(5))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()

            let samples = ComposerSizingProbe.samples.filter { $0.attributedLength == text.utf16.count }
            let sample = try #require(samples.last, "\(label) reaches the production attributed-string sizing function")
            let native = try #require(Self.descendants(of: host.view).compactMap { $0 as? ComposerUITextView }.first)
            maximumSampleCount = max(maximumSampleCount, ComposerSizingProbe.samples.count)
            let actualHeight = Double(native.bounds.height)
            let heightCap = ceil(sample.lineHeight * Double(sample.maxLines))
            #expect(samples.allSatisfy { !$0.isMainThread }, "full-draft height measurement must run off the main thread")
            #expect(sample.width > 0 && sample.width <= 360.5)
            #expect(sample.maxLines == 12 && sample.lineHeight > 0)
            #expect(sample.returnedHeight <= heightCap + 0.5)
            #expect(abs(actualHeight - sample.returnedHeight) <= 1, "the actual UITextView uses the measured height")
            if label == "short" {
                // Native glyph bounds with font leading can exceed UIFont.lineHeight.
                // The short control must remain below a two-line height.
                #expect(sample.returnedHeight < sample.lineHeight * 2)
            }
            output.append("\(label): utf16=\(sample.attributedLength), samples=\(samples.count), width=\(sample.width), line=\(sample.lineHeight), maxLines=\(sample.maxLines), height=\(sample.returnedHeight), nativeHeight=\(actualHeight)")
        }

        let fontText = "Dynamic type font refresh control."
        fixture.text = fontText
        host.rootView = IOSComposerSizingHost(fixture: fixture)
        ComposerSizingProbe.reset(enabled: true)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let baselineFontSample = try await Self.waitForSample(length: fontText.utf16.count, host: host)

        ComposerSizingProbe.reset(enabled: true)
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let enlargedFontSample = try await Self.waitForFontSample(
            length: fontText.utf16.count,
            largerThan: baselineFontSample.lineHeight,
            host: host)
        #expect(enlargedFontSample.lineHeight > baselineFontSample.lineHeight,
                "a Dynamic Type font change invalidates and recomputes the measurement")
        #expect(!enlargedFontSample.isMainThread)
        maximumSampleCount = max(maximumSampleCount, ComposerSizingProbe.samples.count)
        output.append("Dynamic Type font change: utf16=\(enlargedFontSample.attributedLength), samples=\(ComposerSizingProbe.samples.count), width=\(enlargedFontSample.width), line=\(enlargedFontSample.lineHeight), height=\(enlargedFontSample.returnedHeight)")

        #expect(maximumSampleCount <= 64)
        print("\niOS composer sizing diagnostic (real hosted sizeThatFits)\n" + output.joined(separator: "\n"))
    }

    private static func waitForSample(length: Int, host: UIHostingController<IOSComposerSizingHost>) async throws -> ComposerSizingSample {
        let deadline = Date().addingTimeInterval(2)
        while !ComposerSizingProbe.samples.contains(where: { $0.attributedLength == length }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(5))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return try #require(ComposerSizingProbe.samples.last { $0.attributedLength == length })
    }

    private static func waitForFontSample(
        length: Int,
        largerThan lineHeight: Double,
        host: UIHostingController<IOSComposerSizingHost>
    ) async throws -> ComposerSizingSample {
        let deadline = Date().addingTimeInterval(2)
        while !ComposerSizingProbe.samples.contains(where: { $0.attributedLength == length && $0.lineHeight > lineHeight }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(5))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return try #require(ComposerSizingProbe.samples.last { $0.attributedLength == length })
    }

    private static func realisticText(bytes: Int) -> String {
        let sentence = "The evening equipment check found a new vibration near the north pump, so the team recorded the readings and scheduled a follow-up inspection. "
        let repetitions = bytes / sentence.utf8.count
        let remainder = bytes % sentence.utf8.count
        return String(repeating: sentence, count: repetitions) + String(sentence.prefix(remainder))
    }

    private static func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
#endif
