/// Local window context, not a Gateway protocol field.
package struct ChatWindowCommandTarget: Equatable, Sendable {
    package let ref: ChatWindowRef
    package let isDetached: Bool
    package init(ref: ChatWindowRef, isDetached: Bool) { self.ref = ref; self.isDetached = isDetached }
    // Neutral extraction preserves the command's current main-window target.
    package static func resolve(main: Self?, focused: Self?) -> Self? { main }
}
