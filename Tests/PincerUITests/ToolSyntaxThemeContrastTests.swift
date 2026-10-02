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
    @Test func actualTokenAttributeContrastsWithCustomizedCodeBackground() throws {
        // This isolated snapshot models a supported custom AppTheme background. The current
        // fixed light key color is exactly the same RGB, exposing that syntax colors do not
        // account for the actual surface.
        let codeBackground = try #require(ThemeColor(hex: "0550AE"))
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

        let colors = try Self.lightRGBA(foreground: foreground, background: background)
        let contrast = Self.contrast(colors.0, colors.1)
        #expect(contrast >= 4.5,
                "the rendered syntax token should retain normal-text contrast on the active code background; got \(contrast)")
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private static func lightRGBA(foreground: PColor, background: PColor) throws -> (RGB, RGB) {
        #if os(macOS)
        let appearance = try #require(NSAppearance(named: .aqua))
        var colors: (RGB, RGB)?
        appearance.performAsCurrentDrawingAppearance {
            colors = Self.rgb(foreground).flatMap { foreground in
                Self.rgb(background).map { (foreground, $0) }
            }
        }
        return try #require(colors, "both native colors resolve in the light appearance")
        #else
        let traits = UITraitCollection(userInterfaceStyle: .light)
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
