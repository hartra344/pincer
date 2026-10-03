import Testing
@testable import PincerKit

@Suite("Tool syntax contrast")
struct ToolSyntaxContrastTests {
    @Test func retainsPaletteColorsThatAlreadyPasses() {
        let light: [(UInt32, UInt32)] = [
            (0x0550AE, 0xFFFFFF), (0x953800, 0xFFFFFF), (0x116329, 0xFFFFFF),
            (0x6639BA, 0xFFFFFF), (0x57606A, 0xFFFFFF),
        ]
        for (foreground, background) in light {
            #expect(ToolSyntaxContrast.ratio(foreground: foreground, background: background) >= 4.5)
            #expect(ToolSyntaxContrast.foreground(foreground, on: background) == foreground)
        }
        let dark: [(UInt32, UInt32)] = [
            (0x79C0FF, 0x1C1C1E), (0xFFA657, 0x1C1C1E), (0x7EE787, 0x1C1C1E),
            (0xD2A8FF, 0x1C1C1E), (0x8B949E, 0x1C1C1E),
        ]
        for (foreground, background) in dark {
            #expect(ToolSyntaxContrast.ratio(foreground: foreground, background: background) >= 4.5)
            #expect(ToolSyntaxContrast.foreground(foreground, on: background) == foreground)
        }
    }

    @Test func repairsMatchingCustomBackgroundAndHighContrastPalette() {
        let custom: UInt32 = 0x0550AE
        let repaired = ToolSyntaxContrast.foreground(custom, on: custom)
        #expect(repaired != custom)
        #expect(ToolSyntaxContrast.ratio(foreground: repaired, background: custom) >= 4.5)

        let high = ToolSyntaxContrast.foreground(0x888888, on: 0xFFFFFF, increased: true)
        #expect(high != 0x888888)
        #expect(ToolSyntaxContrast.ratio(foreground: high, background: 0xFFFFFF) >= 7)

        let achievableHigh = ToolSyntaxContrast.foreground(0x0550AE, on: 0x333333, increased: true)
        #expect(ToolSyntaxContrast.ratio(foreground: achievableHigh, background: 0x333333) >= 7)
    }

    @Test func usesBestAchievableEndpointWhenHighTargetIsImpossible() {
        let background: UInt32 = 0x777777
        let foreground = ToolSyntaxContrast.foreground(0x888888, on: background, increased: true)
        let best = max(ToolSyntaxContrast.ratio(foreground: 0x000000, background: background),
                       ToolSyntaxContrast.ratio(foreground: 0xFFFFFF, background: background))
        #expect(ToolSyntaxContrast.ratio(foreground: foreground, background: background) == best)
        #expect(best < 7)
    }
}
