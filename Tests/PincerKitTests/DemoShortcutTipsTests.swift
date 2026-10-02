import Testing
@testable import PincerKit

@Suite("Demo shortcut tips")
struct DemoShortcutTipsTests {
    @Test func demoTipsReflectCustomizedAndClearedShortcuts() {
        let custom = DemoGateway.thingsToTry(usedTool: false, paletteShortcut: "⌃⌥P", findShortcut: "⌃⌥F")
        #expect(custom.contains("⌃⌥P"))
        #expect(custom.contains("⌃⌥F"))
        #expect(!custom.contains("⌘K"))
        #expect(!custom.contains("⌘F"))
        let cleared = DemoGateway.thingsToTry(usedTool: false, paletteShortcut: nil, findShortcut: nil)
        #expect(!cleared.contains("⌘K"))
        #expect(!cleared.contains("⌘F"))
        #expect(cleared.contains("command palette"))
        #expect(cleared.contains("Japan trip"))
    }
    @Test func demoQuickCaptureTipReflectsGlobalHotkeyAndDisabledState() {
        let custom = DemoGateway.thingsToTry(usedTool: false, quickCaptureShortcut: "⌃⌥Q")
        #expect(custom.contains("⌃⌥Q"))
        #expect(!custom.contains("⌃⇧Space"))
        let disabled = DemoGateway.thingsToTry(usedTool: false, quickCaptureShortcut: nil)
        #expect(!disabled.contains("⌃⇧Space"))
        #expect(disabled.contains("Quick Capture"))
    }

}
