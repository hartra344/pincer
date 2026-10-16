import PincerKit
import SwiftUI

/// The workspace inspector: a tab strip over what the agent is working with. Only Browser for now;
/// Portals and Files come later, so tabs are an enum rather than a hardcoded view.
struct WorkspacePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case browser
        var id: String { self.rawValue }
        var title: String { L("Browser") }
    }

    @Environment(GatewayStore.self) private var gateway
    @State private var tab: Tab = .browser

    var body: some View {
        let model = self.gateway.browserPanel
        VStack(spacing: 0) {
            WorkspaceTabStrip(tab: self.$tab, model: model)
            Divider()
            switch self.tab {
            case .browser:
                BrowserPanelView(model: model)
            }
        }
    }
}

/// `Browser ▾`: the tab name with a menu of the agent's open pages.
private struct WorkspaceTabStrip: View {
    @Binding var tab: WorkspacePanel.Tab
    let model: BrowserPanelModel

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Menu {
                if self.model.tabs.isEmpty {
                    Text("No pages open", bundle: .module)
                }
                ForEach(self.model.tabs) { page in
                    Button {
                        self.model.select(targetId: page.id)
                    } label: {
                        let text = Self.menuTitle(of: page)
                        if page.id == self.model.selectedTargetId {
                            Label(text, systemImage: "checkmark")
                        } else {
                            Text(text)
                        }
                    }
                }
            } label: {
                Label(self.tab.title, systemImage: "globe")
                    .font(.callout.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(self.model.selectedTab.map { L("Browser, \(Self.title(of: $0))") } ?? L("Browser"))
            .accessibilityHint(L("Choose a page"))
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
    }

    /// Title, then the host.
    static func menuTitle(of page: BrowserPageTab) -> String {
        let title = Self.title(of: page)
        guard let host = page.url?.host(percentEncoded: false), host != title else { return title }
        return "\(title) · \(host)"
    }

    static func title(of page: BrowserPageTab) -> String {
        if !page.title.isEmpty { return page.title }
        return page.url?.host(percentEncoded: false) ?? L("Untitled page")
    }
}

/// The Browser toolbar button (⌥⌘B). On compact iPhone it only shows while the panel is open; "Show
/// Browser" in the chat's ⋯ menu covers the rest.
struct BrowserToolbarButton: View {
    @Binding var isPresented: Bool
    let isCompact: Bool
    var isFocused = true
    var focus: () -> Void = {}

    var body: some View {
        if !self.isCompact || self.isPresented {
            let title = self.isPresented ? L("Hide Browser") : L("Show Browser")
            self.focusedPaneShortcut(Button {
                if self.isFocused {
                    self.isPresented.toggle()
                } else {
                    self.focus()
                    self.isPresented = true
                }
            } label: {
                Label(L("Browser"), systemImage: "globe")
                    .foregroundStyle(self.isPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            })
            #if os(iOS)
            .buttonStyle(.plain)
            #endif
            .help(self.isPresented ? L("Hide Browser (⌥⌘B)") : L("Show Browser (⌥⌘B)"))
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder private func focusedPaneShortcut(_ button: some View) -> some View {
        if self.isFocused {
            button.shortcut(.showBrowser)
        } else {
            button
        }
    }
}

/// "Show Browser" for the chat's session menu.
struct ShowBrowserButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(self.isPresented ? L("Hide Browser") : L("Show Browser"), systemImage: "globe") {
            self.isPresented.toggle()
        }
    }
}
