/// Local window context, not a Gateway protocol field.
package struct ChatWindowCommandTarget: Equatable, Sendable {
    package let ref: ChatWindowRef
    package let isDetached: Bool
    package init(ref: ChatWindowRef, isDetached: Bool) { self.ref = ref; self.isDetached = isDetached }
    package static func resolve(main: Self?, focused: Self?, isAvailable: (ChatWindowRef) -> Bool = { _ in true }) -> Self? {
        guard let target = focused ?? main, isAvailable(target.ref) else { return nil }
        return target
    }
}
