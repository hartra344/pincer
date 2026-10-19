import PincerKit

/// The chat sidebar: an `NSOutlineView` source list on macOS (`SidebarList+AppKit.swift`) and a
/// `UICollectionView` list on iOS (`SidebarList+UIKit.swift`), fed the same inputs.
struct SidebarList {
    let model: SidebarModel
    let selectedKey: String?
    let gateway: GatewayStore
    let actions: SidebarActions
    var theme = AppTheme()
}

extension Array {
    /// The element at `index`, or nil when it's out of bounds.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
