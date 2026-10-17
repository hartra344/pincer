import PincerKit
import SwiftUI

/// The Browser inspector: a tab strip over the agent's browser and the chat's Files. Portals have their own panel.
struct WorkspacePanel: View {
    enum Tab: Hashable {
        case browser
        case files
    }

    @Environment(GatewayStore.self) private var gateway
    /// nil until the user picks a tab.
    @State private var picked: Tab?
    @State private var newTab = false
    @AppStorage(SessionFilesModel.showInPanelKey) private var showFiles = true
    @Environment(\.chatWindowKey) private var windowKey
    /// Owned by the window's inspector chrome: the open file and its draft survive the panel closing.
    let drafts: FilesDraftKeeper
    @State private var pendingTab: Tab?

    /// How long the inspector slide takes to settle. A var so a probe can shorten or lengthen it.
    static var slideSettleDelay: Duration = .milliseconds(350)

    var body: some View {
        let model = self.gateway.browserPanel
        let filesKey = self.windowKey ?? self.gateway.focusedKey ?? self.gateway.selectedKey
        let filesModel = filesKey.map { self.gateway.filesModel(for: $0) }
        let filesShown = self.showFiles && (filesModel?.isAvailable ?? false)
        let fallback: Tab = .browser
        let dirty = self.drafts.isDirty(for: filesKey)
        let initial: Tab = (dirty && filesShown) ? .files : fallback
        let tab: Tab = (self.picked == .files && !filesShown) ? fallback : (self.picked ?? initial)
        let pick = Binding<Tab?>(get: { self.picked }, set: { new in
            if dirty, tab == .files, new != .files { self.pendingTab = new } else { self.picked = new }
        })
        VStack(spacing: 0) {
            WorkspaceTabStrip(tab: pick, newTab: self.$newTab, model: model, current: tab, showsFiles: filesShown)
            Divider()
            if tab == .files {
                if let filesModel {
                    FilesPanelView(model: filesModel, state: self.drafts.session(for: filesModel.sessionKey)).id(filesModel.sessionKey)
                } else {
                    ContentUnavailableView(L("Select a chat to see its files"), systemImage: "doc.text.magnifyingglass")
                }
            } else {
                BrowserPanelView(model: model, newTab: self.$newTab)
            }
        }
        .confirmationDialog(L("Discard changes?"), isPresented: Binding(get: { self.pendingTab != nil }, set: { if !$0 { self.pendingTab = nil } }), titleVisibility: .visible) {
            Button(L("Discard Changes"), role: .destructive) {
                self.drafts.discard(filesKey)
                self.picked = self.pendingTab
                self.pendingTab = nil
            }
            Button(L("Keep Editing"), role: .cancel) { self.pendingTab = nil }
        } message: {
            Text("Your edits to this file haven't been saved.", bundle: .module)
        }
        .modifier(NewTabPrompt(isPresented: self.$newTab, model: model))
        .modifier(SheetTitle(title: tab == .files ? L("Files") : L("Browser")))
    }
}

/// The iPhone sheet's navigation title follows the selected tab; the macOS inspector has no title bar of its own.
struct SheetTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationTitle(self.title)
        #else
        content
        #endif
    }
}

/// `Browser ▾`: the tab name with a menu of the agent's open pages, then Files.
private struct WorkspaceTabStrip: View {
    @Binding var tab: WorkspacePanel.Tab?
    @Binding var newTab: Bool
    let model: BrowserPanelModel
    let current: WorkspacePanel.Tab
    let showsFiles: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Menu {
                if self.model.tabs.isEmpty {
                    Text("No pages open", bundle: .module)
                }
                Button(L("New Tab…"), systemImage: "plus") {
                    self.tab = .browser
                    self.newTab = true
                }
                .disabled(self.model.status == .needsFullManagement || self.model.status == .notRunning)
                if !self.model.tabs.isEmpty { Divider() }
                ForEach(self.model.tabs) { page in
                    Button {
                        self.tab = .browser
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
                Label(L("Browser"), systemImage: "globe")
                    .font(.callout.weight(self.current == .browser ? .semibold : .regular))
            } primaryAction: {
                self.tab = .browser
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(self.model.selectedTab.map { L("Browser, \(Self.title(of: $0))") } ?? L("Browser"))
            .accessibilityHint(L("Choose a page"))
            if self.showsFiles {
                Button { self.tab = .files } label: {
                    Label(L("Files"), systemImage: "folder")
                        .font(.callout.weight(self.current == .files ? .semibold : .regular))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(self.current == .files ? .isSelected : [])
            }
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
