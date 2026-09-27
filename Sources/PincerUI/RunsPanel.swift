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
                ToolbarItem(placement: .primaryAction) { RunsToolbarButton(isPresented: self.$isPresented) }
            }
            .inspector(isPresented: self.presented(false)) {
                RunsPanel()
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
            }
            .sheet(isPresented: self.presented(true)) {
                NavigationStack {
                    RunsPanel()
                        .navigationTitle("Runs")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.isPresented = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

private struct RunsToolbarButton: View {
    @Binding var isPresented: Bool
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        // Kept while the panel is open, so it (and ⌥⌘R) can always close it again.
        if let key = self.gateway.selectedKey, self.isPresented || self.gateway.hasRuns(sessionKey: key) {
            let running = self.gateway.subagentTree(rootKey: key).runningCount
            Button {
                self.isPresented.toggle()
            } label: {
                Label("Runs", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(running > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .symbolEffect(.pulse, isActive: running > 0)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help(running > 0 ? "Runs — \(running) helper\(running == 1 ? "" : "s") running" : "Runs")
            .accessibilityValue(running > 0 ? "\(running) running" : "")
        }
    }
}

/// "Show Runs" for the chat's session menu.
struct ShowRunsButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(self.isPresented ? "Hide Runs" : "Show Runs", systemImage: "point.3.connected.trianglepath.dotted") {
            self.isPresented.toggle()
        }
    }
}

/// Tree | Timeline for the selected chat.
struct RunsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case tree = "Tree", timeline = "Timeline"
        var id: String { self.rawValue }
    }

    @Environment(GatewayStore.self) private var gateway
    @State private var tab: Tab = .tree
    /// Session whose latest run the timeline highlights; nil for the chat itself.
    @State private var focusedSession: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: self.$tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if let key = self.gateway.selectedKey {
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
                ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .onChange(of: self.gateway.selectedKey) { self.focusedSession = nil }
    }
}
