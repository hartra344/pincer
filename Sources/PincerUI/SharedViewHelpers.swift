import SwiftUI

/// The toolbar **Refresh** button the Gateway Settings pages and panels share: runs `action` in a
/// task, disabled while `isDisabled`, with a "Refresh" tooltip unless `showsHelp` is false.
struct RefreshButton: View {
    var isDisabled: Bool
    var showsHelp = true
    var action: @MainActor () async -> Void

    var body: some View {
        let button = Button { Task { await self.action() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            .disabled(self.isDisabled)
        if self.showsHelp {
            button.help(L("Refresh"))
        } else {
            button
        }
    }
}

extension View {
    /// An inline navigation bar title on iOS; nothing elsewhere.
    func inlineNavigationBarTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
