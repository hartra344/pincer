/// The native title's presentation context, shared by main and detached chat chrome.
package enum ChatWindowTitle {
    // Neutral extraction: preserve the current identical title in both contexts.
    package static func title(_ chatTitle: String, isDetached: Bool) -> String { chatTitle }
}
