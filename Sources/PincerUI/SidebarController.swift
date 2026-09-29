import PincerKit

/// Platform-free state shared by the AppKit and UIKit sidebar lists: the id lookups built from
/// the model, the "programmatic change" guard that keeps selection and expansion callbacks from
/// echoing back, and which row the selection should sit on.
@MainActor
final class SidebarController {
    private(set) var headers: [String: SidebarModel.Header] = [:]
    private(set) var entries: [String: SidebarModel.Entry] = [:]
    private(set) var isProgrammatic = false

    /// Rebuilds the id lookups for `model`.
    func index(_ model: SidebarModel) {
        self.headers = [:]
        self.entries = [:]
        for group in model.groups {
            self.headers[group.header.id] = group.header
            for entry in group.entries {
                self.entries[entry.id] = entry
            }
        }
    }

    /// Runs `body` as a change made by us, not the user. Nests.
    func programmatic(_ body: () -> Void) {
        let was = self.isProgrammatic
        self.isProgrammatic = true
        body()
        self.isProgrammatic = was
    }

    /// The list-item id the selection should be on, or `nil` for none.
    static func selectionTarget(selectedKey: String?, hidesSelection: Bool = false) -> String? {
        guard !hidesSelection else { return nil }
        return selectedKey.map(SidebarModel.entryId)
    }
}
