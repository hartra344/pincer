import PincerKit
import SwiftUI

/// What the chat's single inspector slot shows. Opening one panel closes the other.
enum ChatInspectorPanel: Hashable {
    case runs, workspace, portals
}

extension Binding where Value == ChatInspectorPanel? {
    /// A Bool view of one panel: on while that panel is shown; off only clears the slot if it still holds it.
    func isShowing(_ panel: ChatInspectorPanel) -> Binding<Bool> {
        Binding<Bool>(get: { self.wrappedValue == panel },
                      set: { shown in
                          if shown { if self.wrappedValue != panel { self.wrappedValue = panel } }
                          else if self.wrappedValue == panel { self.wrappedValue = nil }
                      })
    }
}

/// Adds the Runs and Browser toolbar buttons and the inspector slot to the selected chat. Applied by
/// `ChatChrome`, outside the per-chat `.id`, so the panel stays open across chat switches.
struct ChatInspectorChrome: ViewModifier {
    @Binding var panel: ChatInspectorPanel?
    /// The last panel shown, so dismissal animates out the content it had instead of flashing Runs.
    @State private var shown: ChatInspectorPanel = .runs
    /// This window's portal web views; they outlive the panel, so reopening it is instant.
    @State private var portalCache = PortalWebCache()
    /// Open Files-tab documents and unsaved drafts; closing the panel asks before dropping them from view.
    @State private var drafts = FilesDraftKeeper()
    @State private var confirmClose: ChatInspectorPanel??
    @State private var workspaceTitle: String?
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey
    private var filesKey: String? { self.windowKey ?? self.gateway.focusedKey ?? self.gateway.selectedKey }
    /// The slot binding the buttons use: a change that would hide an edited file asks first.
    private var guarded: Binding<ChatInspectorPanel?> {
        Binding(get: { self.panel }, set: { new in
            if self.drafts.isDirty(for: self.filesKey), self.panel == .workspace, new != .workspace { self.confirmClose = .some(new) } else { self.panel = new }
        })
    }
    private func confirmBinding(compact: Bool) -> Binding<Bool> {
        Binding(get: { self.confirmClose != nil && self.isCompact == compact },
                set: { if !$0 { self.confirmClose = nil } })
    }

    private func discardClose() {
        self.drafts.discard(self.filesKey)
        if let target = self.confirmClose { self.panel = target }
        self.confirmClose = nil
    }
    private var current: ChatInspectorPanel { self.panel ?? self.shown }
    /// False while the split view's headers show their own Runs and Browser buttons (#427).
    var showsToolbarButton = true
    /// False in a split view, whose headers follow each side's chat themselves.
    var tracksPortals = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { self.sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    /// Trailing inspector on macOS and regular-width iPad; a sheet on compact iPhone.
    private func presented(_ compact: Bool) -> Binding<Bool> {
        Binding(get: { self.panel != nil && self.isCompact == compact },
                set: { if !$0, self.panel != nil { self.guarded.wrappedValue = nil } })
    }

    func body(content: Content) -> some View {
        content
            .modifier(PortalsTracking(key: self.tracksPortals ? self.gateway.portalChatKey(window: self.windowKey) : nil))
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    if self.showsToolbarButton { RunsToolbarButton(isPresented: self.guarded.isShowing(.runs), isCompact: self.isCompact) }
                }
                ToolbarItem(placement: .primaryAction) {
                    if self.showsToolbarButton { BrowserToolbarButton(isPresented: self.guarded.isShowing(.workspace), isCompact: self.isCompact) }
                }
                ToolbarItem(placement: .primaryAction) {
                    if self.showsToolbarButton { PortalsToolbarButton(isPresented: self.guarded.isShowing(.portals), isCompact: self.isCompact) }
                }
                #else
                if self.showsToolbarButton {
                    ToolbarItem(placement: .primaryAction) {
                        RunsToolbarButton(isPresented: self.guarded.isShowing(.runs), isCompact: self.isCompact)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        BrowserToolbarButton(isPresented: self.guarded.isShowing(.workspace), isCompact: self.isCompact)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        PortalsToolbarButton(isPresented: self.guarded.isShowing(.portals), isCompact: self.isCompact)
                    }
                }
                #endif
            }
            .onChange(of: self.panel) { _, new in
                if let new { self.shown = new } else { self.workspaceTitle = nil }
            }
            .inspector(isPresented: self.presented(false)) {
                Group {
                    switch self.current {
                    case .workspace:
                        WorkspacePanel(drafts: self.drafts)
                            .inspectorColumnWidth(min: 360, ideal: 560, max: 1000)
                    case .portals:
                        PortalsPanel(cache: self.portalCache)
                            .inspectorColumnWidth(min: 360, ideal: 560, max: 1000)
                    default:
                        RunsPanel()
                            .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
                    }
                }
            }
            .sheet(isPresented: self.presented(true)) {
                NavigationStack {
                    Group {
                        switch self.current {
                        case .workspace: WorkspacePanel(drafts: self.drafts)
                        case .portals: PortalsPanel(cache: self.portalCache)
                        case .runs: RunsPanel()
                        }
                    }
                    .onPreferenceChange(WorkspaceTitlePreference.self) { self.workspaceTitle = $0 }
                    .navigationTitle(WorkspaceTitlePreference.sheetTitle(panel: self.current, workspaceTitle: self.workspaceTitle))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    // Inside the sheet: a presenter whose sheet is up can't show a second modal.
                    .modifier(DiscardPrompt(isPresented: self.confirmBinding(compact: true), discard: self.discardClose))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("Done")) { self.guarded.wrappedValue = nil }
                        }
                    }
                }
                .presentationDetents(self.current == .runs ? [.medium, .large] : [.large])
                // Pulling down inside a portal page scrolls it; Done closes the sheet.
                .presentationContentInteraction(self.current == .runs ? .automatic : .scrolls)
                .interactiveDismissDisabled(self.drafts.isDirty(for: self.filesKey))
            }
            .modifier(DiscardPrompt(isPresented: self.confirmBinding(compact: false), discard: self.discardClose))
    }
}

/// "Discard changes?" for closing the panel with an edited file.
private struct DiscardPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let discard: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(L("Discard changes?"), isPresented: self.$isPresented, titleVisibility: .visible) {
            Button(L("Discard Changes"), role: .destructive, action: self.discard)
            Button(L("Keep Editing"), role: .cancel) {}
        } message: {
            Text("Your edits to this file haven't been saved.", bundle: .module)
        }
    }
}

/// Shows and hides the Runs panel. In a split view header (#427) it's for that side's chat: pressed
/// on the side without focus, it focuses that side and shows its runs; only the focused side's
/// button takes ⌥⌘R.
struct RunsToolbarButton: View {
    @Binding var isPresented: Bool
    /// Compact iPhone: the nav bar is crowded, so the button only shows while helpers run;
    /// "Show Runs" in the chat's ⋯ menu covers the rest (#180).
    let isCompact: Bool
    var sessionKey: String?
    var isFocused = true
    var focus: () -> Void = {}
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey

    var body: some View {
        // Kept while the panel is open, so it (and ⌥⌘R) can always close it again.
        if let key = self.sessionKey ?? self.windowKey ?? self.gateway.selectedKey,
           (self.isPresented && self.isFocused) || self.gateway.hasRuns(sessionKey: key),
           case let running = self.gateway.subagentTree(rootKey: key).runningCount,
           RunsToolbarVisibility.shows(isCompact: self.isCompact, isPresented: self.isPresented, running: running)
        {
            let runningLabel = running == 0 ? L("Runs")
                : running == 1 ? L("Runs — 1 helper running")
                : L("Runs — \(running) helpers running")
            self.focusedPaneShortcut(Button {
                if self.isFocused {
                    self.isPresented.toggle()
                } else {
                    self.focus()
                    self.isPresented = true
                }
            } label: {
                Label {
                    Text(L("Runs"))
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .frame(width: 18, height: 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        if running > 0 {
                            Text(running > 99 ? "99+" : "\(running)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, running > 9 ? 3 : 0)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.red, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                    .foregroundStyle(running > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .symbolEffect(.pulse, isActive: running > 0)
            })
            #if os(iOS)
            // Keep SwiftUI drawing the composite icon; native toolbar label extraction loses its badge.
            .buttonStyle(.plain)
            #endif
            .help(runningLabel)
            .accessibilityLabel(runningLabel)
        }
    }

    @ViewBuilder private func focusedPaneShortcut(_ button: some View) -> some View {
        if self.isFocused {
            button
                .shortcut(.showRuns)
        } else {
            button
        }
    }
}

enum RunsToolbarVisibility {
    static func shows(isCompact: Bool, isPresented: Bool, running: Int) -> Bool {
        !isCompact || isPresented || running > 0
    }
}

/// "Show Runs" for the chat's session menu.
struct ShowRunsButton: View {
    @Binding var isPresented: Bool
    var sessionKey: String? = nil
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey

    var body: some View {
        let key = self.sessionKey ?? self.windowKey ?? self.gateway.selectedKey
        if self.isPresented || key.map({ self.gateway.hasRuns(sessionKey: $0) }) == true {
            Button(self.isPresented ? L("Hide Runs") : L("Show Runs"), systemImage: "point.3.connected.trianglepath.dotted") {
                self.isPresented.toggle()
            }
        }
    }
}

/// Tree | Timeline for the selected chat.
struct RunsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case tree = "Tree", timeline = "Timeline"
        var id: String { self.rawValue }
        var title: String { self == .tree ? L("Tree") : L("Timeline") }
    }

    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey
    @State private var tab: Tab = .tree
    /// Session whose latest run the timeline highlights; nil for the chat itself.
    @State private var focusedSession: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("View"), selection: self.$tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.lg)
            Divider()
            if let key = self.windowKey ?? self.gateway.focusedKey {
                let tree = self.gateway.subagentTree(rootKey: key)
                switch self.tab {
                case .tree:
                    SubagentTreeView(rootKey: key, tree: tree) { node in
                        self.focusedSession = node.key
                        self.tab = .timeline
                    }
                case .timeline:
                    RunTimelineView(rootKey: key, tree: tree, focusedSession: self.focusedSession ?? key)
                }
            } else {
                ContentUnavailableView(L("No chat selected"), systemImage: "bubble.left.and.bubble.right")
            }
        }
        .onChange(of: self.windowKey ?? self.gateway.focusedKey) { self.focusedSession = nil }
    }
}
