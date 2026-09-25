import PincerKit
import SwiftUI

/// The whole app: shared by the macOS and iOS targets.
public struct PincerScene: Scene {
    @State private var app = AppModel()

    public init() {}

    public var body: some Scene {
        WindowGroup("Pincer", id: "main") {
            RootView()
                .environment(self.app)
                .task { self.app.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Next Unread Chat") { self.app.selectNextUnread() }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(self.app)
        }
        #endif
    }
}

extension AppModel {
    func selectNextUnread() {
        let ordered = self.gateways.sorted { lhs, _ in lhs.id == self.selectedGatewayId }
        for gateway in ordered {
            let unread = gateway.sections().flatMap { $0.channels.flatMap { [$0.row] + $0.threads } }.filter(\.isUnread)
            if let next = unread.first(where: { $0.key != gateway.selectedKey }) {
                self.open(Notifier.Target(gatewayId: gateway.id, sessionKey: next.key))
                return
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var editing: GatewayProfile?
    @State private var addingGateway = false
    @State private var columns: NavigationSplitViewVisibility = .all
    /// On iPhone the split view is a stack; picking a chat pushes it.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(columnVisibility: self.$columns, preferredCompactColumn: self.$compactColumn) {
            Group {
                if let gateway = self.app.selectedGateway {
                    ChannelList(editConnection: { self.editing = gateway.profile },
                                openChat: { self.compactColumn = .detail })
                        .environment(gateway)
                        .id(gateway.id)
                } else {
                    Spacer()
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
            #endif
        } detail: {
            self.detail
        }
        .sheet(isPresented: self.$addingGateway) { ConnectionSheet(existing: nil) }
        .sheet(item: self.$editing) { ConnectionSheet(existing: $0) }
        .onChange(of: self.scenePhase, initial: true) { _, phase in
            self.app.appIsActive = phase == .active
        }
        .onChange(of: self.app.selectedGateway?.selectedKey) { self.app.updateVisible() }
        .onChange(of: self.app.openRequests) { self.compactColumn = .detail }
        .onChange(of: self.app.totalUnread, initial: true) { _, count in
            self.app.notifier.setBadge(count)
            #if os(macOS)
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            #endif
        }
        .onAppear {
            if self.app.gateways.isEmpty { self.addingGateway = true }
        }
    }

    @ViewBuilder private var detail: some View {
        if let gateway = self.app.selectedGateway {
            Group {
                switch gateway.state {
                case let .awaitingPairing(requestId, deviceId):
                    PairingView(requestId: requestId, deviceId: deviceId)
                case let .failed(message) where gateway.sessions.isEmpty:
                    FailedView(message: message) { self.editing = gateway.profile }
                default:
                    if let key = gateway.selectedKey {
                        ChatView(chat: gateway.chat(for: key))
                            .id("\(gateway.id)|\(key)")
                    } else if gateway.state.isConnected {
                        ContentUnavailableView("Pick a chat", systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Choose a session from the sidebar or start a new one."))
                    } else {
                        ProgressView("Connecting to \(gateway.profile.name)…")
                    }
                }
            }
            .environment(gateway)
        } else {
            WelcomeView { self.addingGateway = true }
        }
    }
}

struct WelcomeView: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Pincer", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("A native client for your OpenClaw Gateway. Connect over Tailscale to chat with your agents as yourself — with thinking, tools and images inline.")
        } actions: {
            Button("Add Gateway…", action: self.add)
                .glassProminentButton()
                .controlSize(.large)
        }
    }
}

/// macOS: a tabbed Settings window, like the system's own apps. iOS: one grouped form in a sheet.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                SettingsForm(sections: [.you, .device])
            }
            Tab("Conversation", systemImage: "bubble.left.and.text.bubble.right") {
                SettingsForm(sections: [.conversation, .sidebar])
            }
            Tab("Notifications", systemImage: "bell.badge") {
                SettingsForm(sections: [.notifications])
            }
        }
        .frame(width: 520)
        #else
        SettingsForm(sections: SettingsForm.Section.allCases)
            .navigationTitle("Settings")
        #endif
    }
}

private struct SettingsForm: View {
    enum Section: CaseIterable {
        case you, conversation, sidebar, notifications, device
    }

    let sections: [Section]
    @Environment(AppModel.self) private var app
    @AppStorage("pincer.ownerName") private var ownerName = ""
    @AppStorage(ThinkingDisplay.storageKey) private var thinkingDisplay = ThinkingDisplay.defaultValue
    @AppStorage("pincer.loadWebImages") private var loadWebImages = true
    @AppStorage("pincer.showSubagentRuns") private var showSubagentRuns = false
    @State private var notifications = true

    var body: some View {
        Form {
            ForEach(self.sections, id: \.self) { self.section($0) }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .onAppear { self.notifications = self.app.notifier.enabled }
    }

    @ViewBuilder private func section(_ section: Section) -> some View {
        switch section {
        case .you:
            SwiftUI.Section {
                TextField("Display name", text: self.$ownerName, prompt: Text(Owner.displayName))
            } header: {
                Text("You")
            } footer: {
                Text("Your messages show under this name, whichever channel they came from.")
            }
        case .conversation:
            SwiftUI.Section("Conversation") {
                Picker(selection: self.$thinkingDisplay) {
                    ForEach(ThinkingDisplay.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Thinking steps")
                    Text(self.thinkingDisplay.detail + " Includes reasoning and tool calls.")
                }
                Toggle(isOn: self.$loadWebImages) {
                    Text("Load images the agent links from the web")
                    Text("Like OpenClaw's web UI. The image's website can see your IP address.")
                }
            }
        case .sidebar:
            SwiftUI.Section("Sidebar") {
                Toggle(isOn: self.$showSubagentRuns) {
                    Text("List subagent runs under their chat")
                    Text("Off keeps one thread per chat, like Discord. Open a run from its tool call instead.")
                }
            }
        case .notifications:
            SwiftUI.Section("Notifications") {
                Toggle("Notify about replies and approvals", isOn: self.$notifications)
                    .onChange(of: self.notifications) { _, value in self.app.notifier.enabled = value }
            }
        case .device:
            SwiftUI.Section("This device") {
                LabeledContent("Device ID") {
                    Text(DeviceIdentity.loadOrCreate().deviceId.prefix(16) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Role", value: "operator (read, write, approvals)")
            }
        }
    }
}
