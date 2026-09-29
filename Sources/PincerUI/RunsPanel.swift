import PincerKit
import SwiftUI

/// Adds the Runs toolbar button and the Runs inspector to the selected chat. Applied by
/// `ChatChrome`, outside the per-chat `.id`, so the panel stays open across chat switches.
struct RunsPanelChrome: ViewModifier {
    @Binding var isPresented: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { self.sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    /// Trailing inspector on macOS and regular-width iPad; a sheet on compact iPhone.
    private func presented(_ compact: Bool) -> Binding<Bool> {
        Binding(get: { self.isPresented && self.isCompact == compact },
                set: { if $0 != self.isPresented { self.isPresented = $0 } })
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) { RunsToolbarButton(isPresented: self.$isPresented, isCompact: self.isCompact) }
            }
            .inspector(isPresented: self.presented(false)) {
                RunsPanel()
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
            }
            .sheet(isPresented: self.presented(true)) {
                NavigationStack {
                    RunsPanel()
                        .navigationTitle(L("Runs"))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L("Done")) { self.isPresented = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

private struct RunsToolbarButton: View {
    @Binding var isPresented: Bool
    /// Compact iPhone: the nav bar is crowded, so the button only shows while helpers run;
    /// "Show Runs" in the chat's ⋯ menu covers the rest (#180).
    let isCompact: Bool
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatWindowKey) private var windowKey

    var body: some View {
        // Kept while the panel is open, so it (and ⌥⌘R) can always close it again.
        if let key = self.windowKey ?? self.gateway.selectedKey, self.isPresented || self.gateway.hasRuns(sessionKey: key),
           case let running = self.gateway.subagentTree(rootKey: key).runningCount,
           RunsToolbarVisibility.shows(isCompact: self.isCompact, isPresented: self.isPresented, running: running)
        {
            Button {
                self.isPresented.toggle()
            } label: {
                Label(L("Runs"), systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(running > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .symbolEffect(.pulse, isActive: running > 0)
            }
            .shortcut(.showRuns)
            .help(running == 0 ? L("Runs") : running == 1 ? L("Runs — 1 helper running") : L("Runs — \(running) helpers running"))
            .accessibilityValue(running > 0 ? L("\(running) running") : "")
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

    var body: some View {
        Button(self.isPresented ? L("Hide Runs") : L("Show Runs"), systemImage: "point.3.connected.trianglepath.dotted") {
            self.isPresented.toggle()
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
            if let key = self.windowKey ?? self.gateway.selectedKey {
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
        .onChange(of: self.windowKey ?? self.gateway.selectedKey) { self.focusedSession = nil }
    }
}
