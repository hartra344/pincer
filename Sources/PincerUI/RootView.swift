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
                .themed()
                .task { self.app.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            TranscriptFindCommands()
            CommandGroup(after: .sidebar) {
                Button("Next Unread Chat") { self.app.selectNextUnread() }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                Divider()
                Button("Reload Pincer") { AppRelauncher.relaunch() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
        .commands { GoCommands(app: self.app) }

        #if os(macOS)
        WindowGroup("Gateway Settings", id: "gateway-settings", for: UUID.self) { $gatewayId in
            GatewaySettingsWindow(gatewayId: gatewayId)
                .environment(self.app)
                .themed()
        }
        .defaultSize(width: 860, height: 640)
        .restorationBehavior(.disabled)

        WindowGroup("Automations", id: "automations", for: UUID.self) { $gatewayId in
            AutomationsWindow(gatewayId: gatewayId)
                .environment(self.app)
                .themed()
        }
        .defaultSize(width: 900, height: 640)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(self.app)
                .themed()
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
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var addingGateway = false
    /// iOS: Gateway Settings shown as a sheet.
    @State private var settingsRequest: GatewaySettingsRequest?
    /// iOS: Automations shown as a sheet.
    @State private var automationsRequest: AutomationsRequest?
    /// iOS: app Settings opened from the command palette.
    @State private var showingAppSettings = false
    @State private var paletteRequest: PaletteRequest?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var columns: NavigationSplitViewVisibility = .all
    /// On iPhone the split view is a stack; picking a chat pushes it.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        Group {
            if let gateway = self.app.selectedGateway {
                NavigationSplitView(columnVisibility: self.$columns, preferredCompactColumn: self.$compactColumn) {
                    ChannelList(openChat: { self.compactColumn = .detail })
                        .environment(gateway)
                        .background { self.theme.background(.sidebarBackground)?.ignoresSafeArea() }
                        .id(gateway.id)
                        #if os(macOS)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
                        #endif
                } detail: {
                    self.detail(gateway)
                        .background { self.theme.background(.chatBackground)?.ignoresSafeArea() }
                }
            } else {
                // Outside the split view: on iPhone it collapses to the (empty) sidebar column.
                WelcomeView(add: { self.addingGateway = true }, tryDemo: { self.app.openDemo() })
                    .onAppear { self.compactColumn = .sidebar }
            }
        }
        .overlay {
            CommandPaletteOverlay(request: self.$paletteRequest, openAppSettings: { self.showingAppSettings = true })
        }
        .animation(.snappy(duration: 0.15), value: self.paletteRequest)
        .focusedSceneValue(\.commandPalette, self.showsCommandPalette)
        .focusedSceneValue(\.searchMessages, self.app.selectedGateway == nil ? nil : self.searchMessagesAction)
        .sheet(isPresented: self.$addingGateway) { ConnectionSheet() }
        #if os(iOS)
        .sheet(isPresented: self.$showingAppSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.showingAppSettings = false } } }
            }
        }
        #endif
        .sheet(item: self.$settingsRequest) { request in
            GatewaySettingsWindow(gatewayId: request.id, close: { self.settingsRequest = nil })
        }
        .sheet(item: self.$automationsRequest) { request in
            AutomationsWindow(gatewayId: request.id, close: { self.automationsRequest = nil })
        }
        .environment(\.openGatewaySettings, self.settingsOpener)
        .environment(\.openAutomations, self.automationsOpener)
        .environment(\.searchMessages, self.searchMessagesAction)
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

    /// ⌘K: the palette's root page.
    private var showsCommandPalette: Binding<Bool> {
        Binding(get: { self.paletteRequest != nil },
                set: { self.paletteRequest = $0 ? self.paletteRequest ?? PaletteRequest() : nil })
    }

    private var searchMessagesAction: SearchMessagesAction {
        SearchMessagesAction { query in
            self.paletteRequest = PaletteRequest(page: .messages, query: query)
        }
    }

    private var settingsOpener: GatewaySettingsOpener {
        GatewaySettingsOpener { gateway, destination in
            gateway.settings.requestedDestination = destination
            #if os(macOS)
            self.openWindow(id: "gateway-settings", value: gateway.id)
            #else
            self.settingsRequest = GatewaySettingsRequest(id: gateway.id)
            #endif
        }
    }

    private var automationsOpener: AutomationsOpener {
        AutomationsOpener { gateway in
            #if os(macOS)
            self.openWindow(id: "automations", value: gateway.id)
            #else
            self.automationsRequest = AutomationsRequest(id: gateway.id)
            #endif
        }
    }

    private func detail(_ gateway: GatewayStore) -> some View {
        Group {
            switch gateway.state {
            case let .awaitingPairing(requestId, deviceId):
                PairingView(requestId: requestId, deviceId: deviceId)
            case let .failed(message) where gateway.sessions.isEmpty:
                FailedView(message: message) { self.settingsOpener(gateway, at: .connection) }
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
    }
}

struct WelcomeView: View {
    let add: () -> Void
    let tryDemo: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Pincer", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("A native client for your OpenClaw Gateway. Connect over Tailscale to chat with your agents as yourself — with thinking, tools and images inline.")
        } actions: {
            Button("Add Gateway…", action: self.add)
                .glassProminentButton()
                .controlSize(.large)
            Button("Try the Demo", action: self.tryDemo)
                .glassButton()
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
            Tab("Appearance", systemImage: "paintpalette") {
                SettingsForm(sections: [.appearance, .colors], scrolls: true)
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
        case you, appearance, colors, conversation, sidebar, notifications, device
    }

    let sections: [Section]
    /// Tall tabs scroll in a fixed-height window instead of growing past the screen.
    var scrolls = false
    @Environment(AppModel.self) private var app
    @AppStorage("pincer.ownerName") private var ownerName = ""
    @AppStorage(ThinkingDisplay.storageKey) private var thinkingDisplay = ThinkingDisplay.defaultValue
    @AppStorage("pincer.loadWebImages") private var loadWebImages = true
    @AppStorage("pincer.showSubagentRuns") private var showSubagentRuns = false
    @AppStorage("pincer.showMessagePreviews") private var showMessagePreviews = true
    @AppStorage(AppTheme.presetKey) private var preset = ThemePreset.standard
    @AppStorage(AppTheme.modeKey) private var mode = AppearanceMode.system
    @Environment(\.appTheme) private var theme
    @State private var notifications = true
    @AppStorage(PushRegistrar.relayKey) private var pushRelay = ""

    private func pushStatus(_ gateway: GatewayStore) -> String {
        if !self.pushRelay.isEmpty, PushRegistrar.validRelay(self.pushRelay) == nil { return "Relay must be https://" }
        if self.app.push.deviceToken == nil, !self.pushRelay.isEmpty { return "Waiting for APNs" }
        switch self.app.push.status[gateway.id] {
        case .active: return "Push on"
        case .unsupported: return "Gateway has no Web Push"
        case let .failed(message): return message
        case .off, nil: return gateway.state.isConnected ? "Push off" : "Not connected"
        }
    }

    var body: some View {
        Form {
            ForEach(self.sections, id: \.self) { self.section($0) }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .scrollDisabled(!self.scrolls)
        .fixedSize(horizontal: false, vertical: !self.scrolls)
        .frame(height: self.scrolls ? 520 : nil)
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
        case .appearance:
            SwiftUI.Section {
                Picker("Appearance", selection: self.$mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                ThemePresetGrid(selection: self.$preset)
            } header: {
                Text("Theme")
            } footer: {
                Text("Themes set the accent, links, avatars and backgrounds. Default follows your system accent color.")
            }
        case .colors:
            SwiftUI.Section {
                ForEach(ThemeRole.allCases) { role in
                    ThemeColorRow(role: role, theme: self.theme)
                }
            } header: {
                HStack {
                    Text("Colors")
                    Spacer()
                    if !self.theme.overrides.isEmpty {
                        Button("Reset All") { AppTheme.resetOverrides() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Pick a color to override the theme for just that part.")
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
                Toggle(isOn: self.$showMessagePreviews) {
                    Text("Show last message under each chat")
                    Text("A one-line preview of the latest message in the chat list.")
                }
                Toggle(isOn: self.$showSubagentRuns) {
                    Text("List subagent runs under their chat")
                    Text("Off keeps one thread per chat. Open a run from its tool call instead.")
                }
            }
        case .notifications:
            SwiftUI.Section {
                Toggle("Notify about replies and approvals", isOn: self.$notifications)
                    .onChange(of: self.notifications) { _, value in
                        self.app.notifier.enabled = value
                        self.app.syncPush()
                    }
                #if os(iOS)
                TextField("Push relay", text: self.$pushRelay, prompt: Text("https://relay.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { self.app.syncPush() }
                ForEach(self.app.gateways.filter { !$0.profile.isDemo }) { gateway in
                    LabeledContent(gateway.profile.name, value: self.pushStatus(gateway))
                }
                #endif
            } header: {
                Text("Notifications")
            } footer: {
                #if os(iOS)
                Text("To get notified while Pincer is closed, enter a Pincer push relay. Your gateway encrypts each notification to this device, so the relay can't read it. The gateway needs Web Push (push.web.subscribe).")
                #endif
            }
        case .device:
            SwiftUI.Section("This device") {
                LabeledContent("Device ID") {
                    Text(DeviceIdentity.loadOrCreate().deviceId.prefix(16) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Role", value: "operator (read, write, approvals, questions)")
            }
        }
    }
}

/// Swatches for the built-in themes.
private struct ThemePresetGrid: View {
    @Binding var selection: ThemePreset

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
            ForEach(ThemePreset.allCases) { preset in
                Button { self.selection = preset } label: { self.swatch(preset) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.label) theme")
                    .accessibilityAddTraits(preset == self.selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ preset: ThemePreset) -> some View {
        let selected = preset == self.selection
        let colors = preset.swatch
        return VStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(colors.indices, id: \.self) { index in
                    Circle()
                        .fill(colors[index].gradient)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .frame(width: 22, height: 22)
                }
            }
            Text(preset.label)
                .font(.caption)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? AnyShapeStyle(colors[0].opacity(0.15)) : AnyShapeStyle(.quinary)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? colors[0] : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One themeable color: a picker, and a reset button once the user has overridden it. The picker
/// edits local state, so the color panel isn't reset to the old color while the save round-trips
/// through UserDefaults.
private struct ThemeColorRow: View {
    let role: ThemeRole
    let theme: AppTheme
    @State private var picked: Color?

    var body: some View {
        let overridden = self.theme.overrides[self.role] != nil
        HStack {
            ColorPicker(selection: Binding(
                get: { self.picked ?? self.theme.color(self.role) },
                set: { color in
                    self.picked = color
                    AppTheme.setOverride(color, for: self.role)
                }
            ), supportsOpacity: false) {
                HStack(spacing: 6) {
                    Text(self.role.label)
                    if overridden {
                        Text("Custom").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if overridden {
                Button {
                    AppTheme.setOverride(nil, for: self.role)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Use the theme's color")
                .accessibilityLabel("Reset \(self.role.label)")
            }
        }
        // Reset or Reset All: follow the theme again.
        .onChange(of: overridden) { _, overridden in
            if !overridden { self.picked = nil }
        }
    }
}
