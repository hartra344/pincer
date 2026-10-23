import PincerKit
import SwiftUI

/// Settings → Conversation → Composer: live Markdown styling, and on iOS the formatting bar above the keyboard.
struct ComposerFormattingSettingsSection: View {
    @AppStorage(ComposerMarkdownSettings.liveStylingKey) private var liveStyling = true
    #if os(iOS)
    @AppStorage(ComposerMarkdownSettings.formatBarKey) private var showsFormatBar = false
    #endif

    var body: some View {
        Section {
            Toggle(isOn: self.$liveStyling) {
                Text("Style Markdown as you type", bundle: .module)
                Text("Bold, italic, code and lists show as you write. Your message is still sent as plain Markdown.", bundle: .module)
            }
            #if os(iOS)
            Toggle(isOn: self.$showsFormatBar) {
                Text("Show formatting bar", bundle: .module)
                Text("A row of Markdown formatting buttons above the keyboard.", bundle: .module)
            }
            #endif
        } header: {
            Text("Composer", bundle: .module)
        } footer: {
            Text("Formatting shortcuts, smart lists and pasting formatted text as Markdown keep working when styling is off.", bundle: .module)
        }
    }
}
