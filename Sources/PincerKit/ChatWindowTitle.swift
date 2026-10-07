/// The native title's presentation context, shared by main and detached chat chrome.
package enum ChatWindowTitle {
    package static func title(_ chatTitle: String, isDetached: Bool) -> String {
        isDetached ? L("\(chatTitle) — Chat window") : chatTitle
    }
}
