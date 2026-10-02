import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// #561: syntax foregrounds need to remain readable over the code background selected in AppTheme.
@MainActor
@Suite("Tool syntax theme contrast", .serialized)
struct ToolSyntaxThemeContrastTests {
    @Test func resolvedColorCacheKeysTheSurfaceAndHasAStrictBound() {
        let cache = TranscriptSyntaxColors.ResolutionCache()
        cache.insert(0x123456, background: 0x111111, dark: false, increasedContrast: false)
        #expect(cache.value(background: 0x222222, dark: false, increasedContrast: false) == nil,
                "a changed resolved surface cannot reuse the earlier foreground")
        #expect(cache.value(background: 0x111111, dark: false, increasedContrast: false) == 0x123456)

        for index in 1...20 {
            cache.insert(UInt32(index), background: UInt32(0x300000 + index), dark: false, increasedContrast: false)
        }
        #expect(cache.count == 16)
        #expect(cache.value(background: 0x111111, dark: false, increasedContrast: false) == nil,
                "least-recently-used surface colors are evicted")
    }

    @Test func actualTokenAttributeContrastsWithCustomizedCodeBackground() throws {
        // This isolated snapshot models a supported custom AppTheme background. The current
        // fixed light key color is exactly the same RGB, exposing that syntax colors do not
        // account for the actual surface.
        let codeBackground = ThemeColor(0x0550AE, 0x79C0FF)
        let theme = AppTheme(preset: .standard, mode: .light, overrides: [.codeBackground: codeBackground])
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Syntax", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:syntax:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "syntax", name: "Syntax"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let toolId = "syntax-theme-exec-\(UUID().uuidString)"
        let tool = ToolActivity(id: toolId, name: "exec", arguments: #"{"command":"run"}"#,
                                result: #"{"token":1}"#, isError: false, isRunning: false)
        var turn = AssistantTurn(id: "syntax-theme-turn", timestamp: Date(timeIntervalSince1970: 1))
        turn.tools = [tool]
        turn.isStreaming = true
        let disclosure = context.disclosure
        disclosure.set("steps:\(turn.id)", expanded: true)
        disclosure.set("tool:\(toolId)", expanded: true)
        var settings = TranscriptSettings.current(for: context)
        settings.theme = theme
        var builder = TranscriptLayoutBuilder(context: context, settings: settings)
        let row = builder.layout(.entry(.assistant(turn)), width: 500)
        let card = try #require(row.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(part) = placed.part { return part }
            return nil
        }.first, "the real transcript builder produces the expanded exec card")
        let output = try #require(card.sections.first { $0.id == "\(toolId):output" },
                                  "the syntax-colored JSON is the rendered exec output section")
        let keyToken = try #require(ToolHighlights.make(ToolCallPresentation.make(tool)).output.first { $0.kind == .key })
        #expect(output.text.string == ToolCallPresentation.make(tool).output?.text)
        let terminalBlock = try #require(card.decor.first { item in
            if case let .block(frame, .terminal, _) = item { return frame.contains(output.frame) }
            return false
        }, "the output section belongs to the terminal block that draws codeBackground")
        if case let .block(frame, .terminal, _) = terminalBlock {
            #expect(frame.contains(output.frame), "the actual output section is inside the themed terminal surface")
        }
        let foreground = try #require(output.text.attribute(.foregroundColor, at: keyToken.range.location,
                                                             effectiveRange: nil) as? PColor,
                                      "the actual JSON key token receives a syntax foreground")
        let background = try #require(theme.platformColor(.codeBackground),
                                      "the snapshot resolves the terminal block's customized code background")

        let colors = try Self.resolvedRGBA(foreground: foreground, background: background)
        let contrast = Self.contrast(colors.0, colors.1)
        #expect(contrast >= 4.5,
                "the rendered syntax token should retain normal-text contrast on the active code background; got \(contrast)")

        // AppKit canonicalizes a manually requested high-contrast appearance to Aqua on this host.
        // The renderer therefore snapshots the actual accessibility setting into its layout inputs.
        var highSettings = settings
        highSettings.increasedContrast = true
        #expect(highSettings != settings, "accessibility changes invalidate cached layouts")
        var highBuilder = TranscriptLayoutBuilder(context: context, settings: highSettings)
        let highRow = highBuilder.layout(.entry(.assistant(turn)), width: 500)
        let highCard = try #require(highRow.parts.compactMap { placed -> TranscriptPart.Tool? in
            if case let .tool(part) = placed.part { return part }
            return nil
        }.first)
        let highOutput = try #require(highCard.sections.first { $0.id == "\(toolId):output" })
        #expect(highOutput.text.string == output.text.string)
        let highForeground = try #require(highOutput.text.attribute(.foregroundColor, at: keyToken.range.location,
                                                                     effectiveRange: nil) as? PColor)
        let highContrastColors = try Self.resolvedRGBA(foreground: highForeground, background: background, increased: true)
        let highContrast = Self.contrast(highContrastColors.0, highContrastColors.1)
        let achievable = max(Self.contrast(Self.RGB(red: 0, green: 0, blue: 0), colors.1),
                             Self.contrast(Self.RGB(red: 1, green: 1, blue: 1), colors.1))
        #expect(highContrast >= 7 && highContrast <= achievable,
                "increased contrast reaches 7:1 where this custom blue allows it; got \(highContrast)")

        let darkColors = try Self.resolvedRGBA(foreground: foreground, background: background, dark: true)
        #expect(Self.contrast(darkColors.0, darkColors.1) >= 4.5,
                "dark syntax resolves against the matching custom terminal surface")
    }

    @Test func largeSyntaxApplicationKeepsSourceAndBoundsColorResolutionCost() throws {
        let line = #"{"name":"Pincer","count":12,"ready":true}"#
        let source = String(repeating: line + "\n", count: 500)
        let tokens = ToolSyntax.jsonTokens(in: source)
        let distinctKinds = Dictionary(grouping: tokens, by: \.kind).compactMapValues(\.first)
        let plain = NSAttributedString(string: source)
        let theme = AppTheme(preset: .standard, mode: .system)
        let clock = ContinuousClock()
        var rendered = NSAttributedString(string: "")
        var resolvedCount = 0
        #if os(macOS)
        let appearance = try #require(NSAppearance(named: .aqua))
        #else
        let traits = UITraitCollection(userInterfaceStyle: .light)
        #endif
        let elapsed = clock.measure {
            for _ in 0..<5 {
                rendered = TranscriptSyntaxColors.apply(tokens, to: plain, surface: .terminal, theme: theme)
                for token in distinctKinds.values {
                    guard let color = rendered.attribute(.foregroundColor, at: token.range.location,
                                                          effectiveRange: nil) as? PColor else { continue }
                    #if os(macOS)
                    appearance.performAsCurrentDrawingAppearance { resolvedCount += color.usingColorSpace(.sRGB) == nil ? 0 : 1 }
                    #else
                    _ = color.resolvedColor(with: traits)
                    resolvedCount += 1
                    #endif
                }
            }
        }
        #expect(!tokens.isEmpty && distinctKinds.count >= 3)
        #expect(rendered.string == source, "syntax attributes leave all source characters untouched")
        #expect(resolvedCount >= distinctKinds.count * 5, "the probe resolves each produced token kind")
        #expect(elapsed < PerfBudget.limit(.milliseconds(200)), "5 large apply-and-resolve passes took \(elapsed)")
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private static func resolvedRGBA(foreground: PColor, background: PColor,
                                     dark: Bool = false, increased: Bool = false) throws -> (RGB, RGB)
    {
        #if os(macOS)
        let appearanceName: NSAppearance.Name = increased
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        let appearance = try #require(NSAppearance(named: appearanceName))
        var colors: (RGB, RGB)?
        appearance.performAsCurrentDrawingAppearance {
            colors = Self.rgb(foreground).flatMap { foreground in
                Self.rgb(background).map { (foreground, $0) }
            }
        }
        return try #require(colors, "both native colors resolve in the light appearance")
        #else
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: increased ? .high : .normal),
        ])
        let foreground = foreground.resolvedColor(with: traits)
        let background = background.resolvedColor(with: traits)
        return (try #require(Self.rgb(foreground)), try #require(Self.rgb(background)))
        #endif
    }

    #if os(macOS)
    private static func rgb(_ color: NSColor) -> RGB? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(Double(red), Double(green), Double(blue))
    }
    #else
    private static func rgb(_ color: UIColor) -> RGB? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return RGB(Double(red), Double(green), Double(blue))
    }
    #endif

    private static func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        func luminance(_ color: RGB) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
