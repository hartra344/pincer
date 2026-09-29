import PincerKit
import SwiftUI

/// The whole app: shared by the macOS and iOS targets.
public struct PincerScene: Scene {
    /// One for the app's lifetime, so launch work (connecting, the Quick Capture hotkey) doesn't
    /// wait for a main window, which may never be created.
    @State private var app = AppModel.shared

    public init() {
        #if os(macOS)
        QuickCaptureController.shared.install(app: AppModel.shared)
        #endif
    }

    public var body: some Scene {
        WindowGroup("Pincer", id: "main") {
            RootView()
                .deepLinkRouting()
                .environment(self.app)
                .themed()
                .task {
                    self.app.start()
                    #if os(macOS)
                    QuickCaptureController.shared.launch()
                    #endif
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .commands {
            TranscriptFindCommands()
            CommandGroup(after: .newItem) {
                Button("Add Gateway…") {
                    self.app.firstRun.present()
                    QuickCaptureController.shared.showMainWindow()
                }
            }
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

        PincerMenuBar(app: self.app)
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
    /// iOS: Gateway Settings shown as a sheet.
    @State private var settingsRequest: GatewaySettingsRequest?
    /// iOS: runs once the Gateway Settings sheet is gone (#133).
    @State private var afterSettingsDismiss: AfterDismiss?
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
            if self.showsFirstRun {
                // Outside the split view: on iPhone it collapses to the (empty) sidebar column.
                FirstRunView()
                    .onAppear { self.compactColumn = .sidebar }
            } else if let gateway = self.app.selectedGateway {
                NavigationSplitView(columnVisibility: self.$columns, preferredCompactColumn: self.$compactColumn) {
                    ChannelList(openChat: { self.compactColumn = .detail })
                        .environment(gateway)
                        .background { self.theme.background(.sidebarBackground)?.ignoresSafeArea() }
                        .id(gateway.id)
                        #if os(macOS)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
                        #endif
                } detail: {
                    GatewayDetail(gateway: gateway)
                        .background { self.theme.background(.chatBackground)?.ignoresSafeArea() }
                }
            }
        }
        .overlay {
            CommandPaletteOverlay(request: self.$paletteRequest, openAppSettings: { self.showingAppSettings = true })
        }
        .animation(.snappy(duration: 0.15), value: self.paletteRequest)
        .focusedSceneValue(\.commandPalette, self.showsCommandPalette)
        .focusedSceneValue(\.searchMessages, self.app.selectedGateway == nil ? nil : self.searchMessagesAction)
        .modifier(FirstRunCover())
        .modifier(SetupWizardPresenter())
        .modifier(TipsOverlay())
        #if os(iOS)
        .sheet(isPresented: self.$showingAppSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.showingAppSettings = false } } }
            }
        }
        #endif
        .sheet(item: self.$settingsRequest, onDismiss: self.settingsDismissed) { request in
            GatewaySettingsWindow(gatewayId: request.id, close: { self.settingsRequest = nil },
                                  closeThen: { action in
                                      self.afterSettingsDismiss = AfterDismiss(run: action)
                                      self.settingsRequest = nil
                                  })
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
        .modifier(CompactColumnRouting(column: self.$compactColumn))
        .background { UnreadBadgeSync() }
        #if os(macOS)
        .modifier(MainWindowFronting())
        #endif
        .onAppear {
            self.app.firstRun.showIfNoGateways()
            #if os(macOS)
            QuickCaptureController.shared.openWindow = self.openWindow
            #endif
        }
    }

    /// The first-run wizard fills the window with no gateways; on macOS "Add Gateway…" shows it
    /// here too (iOS covers the chat list instead).
    private var showsFirstRun: Bool {
        let presentation = self.app.firstRun.presentation
        #if os(macOS)
        return presentation != nil || self.app.selectedGateway == nil
        #else
        return presentation == .window || self.app.selectedGateway == nil
        #endif
    }

    private func settingsDismissed() {
        let action = self.afterSettingsDismiss
        self.afterSettingsDismiss = nil
        action?.run()
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
        GatewaySettingsOpener { gateway, destination, routes in
            gateway.settings.requestedRoutes = routes
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
}

/// iPhone: opening a chat shows the detail column; a link to an unknown gateway shows the list.
/// Its own modifier to keep `RootView.body` within the type checker's limits.
private struct CompactColumnRouting: ViewModifier {
    @Binding var column: NavigationSplitViewColumn
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .onChange(of: self.app.openRequests) { self.column = .detail }
            .onChange(of: self.app.gatewayListRequests) { self.column = .sidebar }
    }
}

/// Keeps the app badge in sync with unread chats. Its own view because the count reads every
/// session: watching it from `RootView` rebuilt the sidebar whenever a chat was read.
private struct UnreadBadgeSync: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.clear
            .onChange(of: self.app.totalUnread, initial: true) { _, count in
                self.app.notifier.setBadge(count)
                #if os(macOS)
                NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                #endif
            }
    }
}

/// The split view's detail column. Its own view so only it, not `RootView` and the sidebar it
/// builds, re-renders when the selected chat changes.
private struct GatewayDetail: View {
    let gateway: GatewayStore
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings

    var body: some View {
        let gateway = self.gateway
        Group {
            switch gateway.state {
            case let .awaitingPairing(requestId, deviceId):
                PairingView(requestId: requestId, deviceId: deviceId)
            case let .failed(message) where gateway.sessions.isEmpty:
                FailedView(message: message) { self.openGatewaySettings(gateway, at: .connection) }
            default:
                if let key = gateway.selectedKey {
                    let chat = gateway.chat(for: key)
                    // The per-chat `.id` stays inside a stable, full-size container, with the title and
                    // toolbar outside it. Replacing the view under the toolbar, or the toolbar with
                    // it, makes macOS redraw every toolbar button on each switch. Toolbar items need
                    // the same care (#262); see CONTRIBUTING.md and `ToolbarStabilityCheck`.
                    ZStack {
                        ChatView(chat: chat)
                            .id("\(gateway.id)|\(key)")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(ChatChrome())
                } else if gateway.state.isConnected {
                    ContentUnavailableView("Pick a chat", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Choose a session from the sidebar or start a new one."))
                } else {
                    ProgressView("Connecting to \(gateway.profile.name)…")
                }
            }
        }
        .environment(gateway)
        .onChange(of: gateway.selectedKey) { self.app.updateVisible() }
    }
}

#if os(macOS)
/// Brings the main window forward when a wizard opens on it, e.g. from Gateway Settings or the
/// menu bar, so it isn't left behind another window (#131).
private struct MainWindowFronting: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .onChange(of: self.app.firstRun.presentationCount) { QuickCaptureController.shared.showMainWindow() }
            .onChange(of: self.app.selectedGateway?.setup.isPresented ?? false) { _, presented in
                if presented { QuickCaptureController.shared.showMainWindow() }
            }
    }
}
#endif

/// macOS: a tabbed Settings window, like the system's own apps. iOS: one grouped form in a sheet.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                SettingsForm(sections: [.you, .launch, .quickCapture, .menuBar, .device, .storage, .tips])
            }
            Tab("Appearance", systemImage: "paintpalette") {
                SettingsForm(sections: [.appearance, .avatars, .colors], scrolls: true)
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
        SettingsForm(sections: SettingsForm.Section.available)
            .navigationTitle("Settings")
        #endif
    }
}

enum ReactionFeature {
    static let enabledKey = "pincer.reactions.enabled"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? self.defaultEnabled
    }
}

private struct SettingsForm: View {
    enum Section: CaseIterable {
        case you, launch, quickCapture, menuBar, appearance, avatars, colors, conversation, sidebar, notifications, device, storage, tips

        /// Sections that exist on this platform.
        static var available: [Self] {
            #if os(macOS)
            Self.allCases
            #else
            Self.allCases.filter { $0 != .launch && $0 != .quickCapture && $0 != .menuBar }
            #endif
        }
    }

    let sections: [Section]
    /// Tall tabs scroll in a fixed-height window instead of growing past the screen.
    var scrolls = false
    @Environment(AppModel.self) private var app
    @AppStorage("pincer.ownerName") private var ownerName = ""
    @AppStorage(ThinkingDisplay.storageKey) private var thinkingDisplay = ThinkingDisplay.defaultValue
    @AppStorage(ReactionFeature.enabledKey) private var reactionsEnabled = ReactionFeature.defaultEnabled
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
        case .tips:
            TipsSettingsSection()
        case .launch:
            #if os(macOS)
            LaunchAtLoginSettingsSection()
            #endif
        case .quickCapture:
            #if os(macOS)
            QuickCaptureSettingsSection()
            #endif
        case .menuBar:
            #if os(macOS)
            MenuBarSettingsSection()
            #endif
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
        case .avatars:
            AvatarSettingsSection()
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
                Toggle(isOn: self.$reactionsEnabled) {
                    Text("Enable experimental reactions")
                    Text("Off by default. Reactions may not interoperate across channels or Gateways.")
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
        case .storage:
            TranscriptCacheSettingsSection()
        }
    }
}

/// How much room cached transcripts take, and a way to clear them (e.g. after a bad cache).
private struct TranscriptCacheSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var usage: Int64?
    @State private var confirming = false
    @State private var confirmingUnsent = false
    private let enabled = TranscriptCache.root != nil

    var body: some View {
        SwiftUI.Section {
            LabeledContent("Cached transcripts") {
                if !self.enabled {
                    Text("Off")
                } else if let usage {
                    Text(usage.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button("Clear Cache…", role: .destructive) { self.confirming = true }
                .disabled(!self.enabled || self.usage == 0)
                .confirmationDialog("Clear cached transcripts?", isPresented: self.$confirming, titleVisibility: .visible) {
                    Button("Clear Cache", role: .destructive) {
                        Task {
                            await self.app.clearTranscriptCache()
                            await self.measure()
                        }
                    }
                } message: {
                    Text("Chats are downloaded again from your gateways when you open them, and message search is rebuilt. Nothing on your gateways is deleted.")
                }
            LabeledContent("Outbox") {
                Text(self.app.unsentCount == 1 ? "1 message" : "\(self.app.unsentCount.formatted()) messages")
                    .monospacedDigit()
            }
            Button("Clear Outbox…", role: .destructive) { self.confirmingUnsent = true }
                .disabled(self.app.unsentCount == 0)
                .confirmationDialog("Clear the outbox?", isPresented: self.$confirmingUnsent, titleVisibility: .visible) {
                    Button("Clear Outbox", role: .destructive) { self.app.discardUnsentMessages() }
                } message: {
                    Text("Queued and failed messages are deleted from this device without being sent. Chats and cached transcripts aren’t affected.")
                }
        } header: {
            Text("Storage")
        } footer: {
            Text("Chat history is kept on this device so chats open instantly, even offline, and so you can search your messages. Messages you write offline wait here until they send.")
        }
        .task { await self.measure() }
    }

    private func measure() async {
        guard self.enabled else { return }
        self.usage = await TranscriptCache.diskUsage()
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
