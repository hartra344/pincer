import PincerKit
import SwiftUI

/// Shows or hides the main window's sidebar (#564).
///
/// iPad: the Runs panel's `.inspector` wraps the chat in its own container, which drops the split
/// view's sidebar button from the chat's navigation bar, so once the sidebar is hidden nothing
/// brings it back. `ChatChrome` puts this toggle's button there instead, and ⌃⌘S (a Pincer
/// shortcut on iPad) and the command palette use it too. macOS keeps the system's own toolbar
/// button and View ▸ Show/Hide Sidebar.
struct SidebarToggle {
    /// Whether the sidebar is hidden, so the chat needs a button to bring it back.
    let isCollapsed: Bool
    let toggle: () -> Void

    /// The visibility after a toggle: a hidden sidebar comes back beside the chat.
    static func toggled(_ visibility: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        visibility == .detailOnly ? .all : .detailOnly
    }

    var title: String { self.isCollapsed ? L("Show Sidebar") : L("Hide Sidebar") }

    #if os(macOS)
    /// macOS: the system View ▸ Show/Hide Sidebar action, for the command palette.
    @MainActor static func toggleSystemSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
    #endif
}

extension EnvironmentValues {
    /// The main window's sidebar toggle; nil on macOS and on iPhone (compact), whose split view
    /// is a stack.
    @Entry var sidebarToggle: SidebarToggle?
}

extension FocusedValues {
    /// The key window's sidebar toggle, for ⌃⌘S on iPad.
    @Entry var sidebarToggle: SidebarToggle?
}

#if os(iOS)
/// iPad: View ▸ Show/Hide Sidebar (⌃⌘S) in the hardware keyboard's menu. It replaces iPadOS 26's
/// own ⌃⌘S item: adding a second one crashes UIKit's menu builder with a duplicate key command,
/// and the system's doesn't reach the split view past the Runs inspector. macOS has the system's.
struct SidebarCommands: Commands {
    @FocusedValue(\.sidebarToggle) private var sidebar

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(self.sidebar?.title ?? L("Toggle Sidebar")) { self.sidebar?.toggle() }
                .shortcut(.toggleSidebar)
                .disabled(self.sidebar == nil)
        }
    }
}

/// The chat's "Show Sidebar" button while the sidebar is hidden on iPad.
struct ShowSidebarButton: View {
    @Environment(\.sidebarToggle) private var sidebar

    var body: some View {
        if let sidebar, sidebar.isCollapsed {
            Button(L("Show Sidebar"), systemImage: "sidebar.leading", action: sidebar.toggle)
                .accessibilityIdentifier("show-sidebar")
        }
    }
}
#endif
