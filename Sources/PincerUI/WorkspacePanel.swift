import PincerKit
import SwiftUI

/// The workspace inspector: a tab strip over what the agent is working with. Only Browser for now;
/// Portals and Files come later, so tabs are an enum rather than a hardcoded view.
struct WorkspacePanel: View {
    enum Tab: Hashable {
        case browser
        case portal(String)
        case files
    }

    @Environment(GatewayStore.self) private var gateway
    /// nil until the user picks a tab: then Browser, or the first portal when the browser needs Full Management.
    @State private var picked: Tab?
    @Environment(\.scenePhase) private var scenePhase
    /// Owned by the window's inspector chrome, so loaded portals survive reopening the panel.
    let cache: PortalWebCache
    @State private var closing: PortalSummary?
    @State private var lastClosingTitle = ""
    /// The panel has finished sliding in; the first web view is created only after.
    @State private var settled = false
    @State private var dismissedCloseError: String?
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
        let store = self.gateway.portals
        let portals = store.unavailable ? [] : store.portals
        // A portal that closed falls back to Browser.
        let browserWorks = model.status != .needsFullManagement
        let filesKey = self.windowKey ?? self.gateway.focusedKey ?? self.gateway.selectedKey
        let filesModel = filesKey.map { self.gateway.filesModel(for: $0) }
        let filesShown = self.showFiles && (filesModel?.isAvailable ?? false)
        let fallback: Tab = browserWorks ? .browser : portals.first.map { .portal($0.id) } ?? .browser
        let dirty = self.drafts.isDirty(for: filesKey)
        let initial: Tab = (dirty && filesShown) ? .files : fallback
        let tab: Tab = (self.picked == .files && !filesShown) ? fallback : (self.picked ?? initial)
        let selected = portals.first { tab == .portal($0.id) }
        let pick = Binding<Tab?>(get: { self.picked }, set: { new in
            if dirty, tab == .files, new != .files { self.pendingTab = new } else { self.picked = new }
        })
        VStack(spacing: 0) {
            WorkspaceTabStrip(tab: pick, newTab: self.$newTab, model: model, portals: portals, selectedPortal: selected?.id, current: tab, showsFiles: filesShown) { self.closing = $0 }
            Divider()
            if let error = store.closeError, error != self.dismissedCloseError {
                PortalBanner(symbol: "exclamationmark.triangle", dismiss: { self.dismissedCloseError = error }) { Text(error) }
                Divider()
            }
            if tab == .files {
                if let filesModel {
                    FilesPanelView(model: filesModel, state: self.drafts.session(for: filesModel.sessionKey)).id(filesModel.sessionKey)
                } else {
                    ContentUnavailableView(L("Select a chat to see its files"), systemImage: "doc.text.magnifyingglass")
                }
            } else if let selected {
                PortalView(portal: selected, cache: self.cache, canLoad: self.settled) { self.closing = selected }
                    .id(selected.id)
            } else {
                BrowserPanelView(model: model, newTab: self.$newTab)
            }
        }
        .task {
            try? await Task.sleep(for: Self.slideSettleDelay)
            self.settled = true
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
        .modifier(SheetTitle(title: tab == .files ? L("Files") : (selected?.title ?? L("Browser"))))
        .onChange(of: self.closing) { _, new in if let new { self.lastClosingTitle = new.title } }
        .onChange(of: portals.map(\.id)) { _, ids in self.cache.prune(keeping: Set(ids)) }
        .onChange(of: self.scenePhase) { _, phase in if phase != .active { self.cache.pauseAllMedia() } }
        .portalCloseConfirmation(title: self.closing?.title ?? self.lastClosingTitle, isPresented: Binding(get: { self.closing != nil }, set: { if !$0 { self.closing = nil } })) {
            guard let portal = self.closing else { return }
            self.closing = nil
            Task { await store.close(portal.id) }
        }
    }
}

/// The iPhone sheet's navigation title follows the selected tab; the macOS inspector has no title bar of its own.
private struct SheetTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationTitle(self.title)
        #else
        content
        #endif
    }
}

/// `Browser ▾`: the tab name with a menu of the agent's open pages, then one tab per portal (only when
/// there are portals, so a Browser-only panel keeps its PR 1 look).
private struct WorkspaceTabStrip: View {
    @Binding var tab: WorkspacePanel.Tab?
    @Binding var newTab: Bool
    let model: BrowserPanelModel
    let portals: [PortalSummary]
    let selectedPortal: String?
    let current: WorkspacePanel.Tab
    let showsFiles: Bool
    let close: (PortalSummary) -> Void

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
            if !self.portals.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(self.portals) { portal in
                            PortalTab(portal: portal, isSelected: self.selectedPortal == portal.id,
                                      select: { self.tab = .portal(portal.id) }, close: { self.close(portal) })
                        }
                    }
                }
            }
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

private struct PortalTab: View {
    let portal: PortalSummary
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button(action: self.select) {
                Label(Self.shortened(self.portal.title), systemImage: "globe")
                    .font(.callout.weight(self.isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(self.portal.title)
            .accessibilityLabel(L("Portal: \(self.portal.title)"))
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
            if !self.portal.isRedacted {
                Button(action: self.close) {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        .frame(minWidth: Self.closeTarget, minHeight: Self.closeTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("Close Portal"))
                .accessibilityLabel(L("Close portal \(self.portal.title)"))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(self.isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.clear), in: Capsule())
        .contextMenu {
            if !self.portal.isRedacted {
                Button(L("Close Portal"), systemImage: "xmark.circle", role: .destructive, action: self.close)
            }
        }
    }

    #if os(iOS)
    static let closeTarget: CGFloat = 44
    #else
    static let closeTarget: CGFloat = 24
    #endif

    /// One line, about 24 characters; the full title is in the help.
    static func shortened(_ title: String) -> String {
        title.count > 24 ? title.prefix(23) + "…" : title
    }
}

/// The Browser toolbar button (⌥⌘B). On compact iPhone it only shows while the panel is open; "Show
/// Browser" in the chat's ⋯ menu covers the rest.
struct BrowserToolbarButton: View {
    @Binding var isPresented: Bool
    let isCompact: Bool
    var isFocused = true
    var focus: () -> Void = {}
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        if !self.isCompact || self.isPresented {
            let count = self.gateway.portals.unavailable ? 0 : self.gateway.portals.portals.count
            let title = self.isPresented ? L("Hide Browser") : L("Show Browser")
            self.focusedPaneShortcut(Button {
                if self.isFocused {
                    self.isPresented.toggle()
                } else {
                    self.focus()
                    self.isPresented = true
                }
            } label: {
                Label {
                    Text(L("Browser"))
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "globe")
                        if count > 0 {
                            Text(count > 99 ? "99+" : "\(count)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, count > 9 ? 3 : 0)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 8, y: -6)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .foregroundStyle(self.isPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            })
            #if os(iOS)
            .buttonStyle(.plain)
            #endif
            .help(Self.help(isPresented: self.isPresented, count: count))
            .accessibilityLabel(count > 0 ? "\(L("Browser")) — \(Self.portalsOpen(count))" : title)
        }
    }

    static func help(isPresented: Bool, count: Int) -> String {
        let base = isPresented ? L("Hide Browser (⌥⌘B)") : L("Show Browser (⌥⌘B)")
        return count > 0 ? "\(base) — \(Self.portalsOpen(count))" : base
    }

    static func portalsOpen(_ count: Int) -> String {
        count == 1 ? L("1 portal open") : L("\(count) portals open")
    }

    static func portalCount(_ count: Int) -> String {
        count == 1 ? L("1 portal") : L("\(count) portals")
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
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let count = self.gateway.portals.unavailable ? 0 : self.gateway.portals.portals.count
        let title = self.isPresented ? L("Hide Browser") : L("Show Browser")
        let shown = switch (self.isPresented, count) {
        case (_, 0): title
        case (true, 1): L("Hide Browser · 1 portal")
        case (true, _): L("Hide Browser · \(count) portals")
        case (false, 1): L("Show Browser · 1 portal")
        case (false, _): L("Show Browser · \(count) portals")
        }
        Button(shown, systemImage: "globe") {
            self.isPresented.toggle()
        }
    }
}
