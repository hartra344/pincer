import PincerKit
import SwiftUI

/// Adds the Runs toolbar button and the Runs inspector to the selected chat. Applied by
/// `ChatChrome`, outside the per-chat `.id`, so the panel stays open across chat switches.
struct RunsPanelChrome: ViewModifier {
    @Binding var isPresented: Bool
    /// False while the split view's headers show their own Runs buttons (#427).
    var showsToolbarButton = true
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
                ToolbarItem(placement: .primaryAction) {
                    if self.showsToolbarButton { RunsToolbarButton(isPresented: self.$isPresented, isCompact: self.isCompact) }
                }
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
