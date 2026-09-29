import PincerKit
import SwiftUI

/// The whole app: shared by the macOS and iOS targets.
public struct PincerScene: Scene {
    /// One for the app's lifetime, so launch work (connecting, the Quick Capture hotkey) doesn't
    /// wait for a main window, which may never be created.
    @State private var app = AppModel.shared

    public init() {
        // PincerKit's sentences are keys in this catalog.
        PincerStrings.bundle = .module
        SVGRasterizer.install()
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
            ChatWindowCommands(app: self.app)
            ExportChatCommands()
            ReadAloudCommands()
            CommandGroup(after: .newItem) {
                Button(L("Add Gateway…")) {
                    self.app.firstRun.present()
                    QuickCaptureController.shared.showMainWindow()
                }
                .shortcut(.addGateway)
            }
            CommandGroup(after: .sidebar) {
                Button(L("Next Unread Chat")) { self.app.selectNextUnread() }
                    .shortcut(.nextUnreadChat)
                Divider()
                Button(L("Reload Pincer")) { AppRelauncher.relaunch() }
                    .shortcut(.reloadPincer)
            }
        }
        #endif
        .commands { GoCommands(app: self.app) }

        #if os(macOS)
        // Restored on relaunch, unlike the settings windows below (#48).
        WindowGroup(L("Chat"), id: ChatWindow.sceneId, for: ChatWindowRef.self) { $ref in
            ChatWindow(ref: ref)
                .environment(self.app)
                .themed()
        }
        .defaultSize(width: 720, height: 780)

        WindowGroup(L("Gateway Settings"), id: "gateway-settings", for: UUID.self) { $gatewayId in
            GatewaySettingsWindow(gatewayId: gatewayId)
                .environment(self.app)
                .themed()
        }
        .defaultSize(width: 860, height: 640)
        .restorationBehavior(.disabled)

        WindowGroup(L("Automations"), id: "automations", for: UUID.self) { $gatewayId in
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
            let unread = gateway.sections().flatMap { $0.allChannels.flatMap { [$0.row] + $0.threads } }.filter(\.isUnread)
            if let next = unread.first(where: { $0.key != gateway.selectedKey }) {
                self.open(Notifier.Target(gatewayId: gateway.id, sessionKey: next.key))
                gateway.revealInSidebar(next.key)
                return
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.appTheme) private var theme
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Unthemed on iPhone, the sidebar's inset-grouped cards need the grouped backdrop to show.
    private var sidebarBackground: Color? {
        if let color = self.theme.background(.sidebarBackground) { return color }
        #if os(iOS)
        if self.sizeClass == .compact { return Color(.systemGroupedBackground) }
        #endif
        return nil
    }

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
                        .background { self.sidebarBackground?.ignoresSafeArea() }
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
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { self.showingAppSettings = false } } }
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
        #if os(macOS)
        .environment(\.openChatWindow, .window(self.openWindow))
        #endif
        .modifier(AppActivityTracking())
        .modifier(CompactColumnRouting(column: self.$compactColumn))
        .modifier(MainChatVisibility(compactColumn: self.compactColumn))
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
                    .modifier(ChatSplitHost(gateway: gateway))
                    .modifier(ChatChrome())
                } else if gateway.state.isConnected {
                    ContentUnavailableView(L("Pick a chat"), systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Choose a chat from the sidebar or start a new one.", bundle: .module))
                } else {
                    ProgressView(L("Connecting to \(gateway.profile.name)…"))
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
                SettingsForm(sections: SettingsForm.Section.generalTab)
            }
            Tab("Appearance", systemImage: "paintpalette") {
                SettingsForm(sections: SettingsForm.Section.appearanceTab)
            }
            Tab("Conversation", systemImage: "bubble.left.and.text.bubble.right") {
                SettingsForm(sections: SettingsForm.Section.conversationTab)
            }
            Tab("Notifications", systemImage: "bell.badge") {
                SettingsForm(sections: SettingsForm.Section.notificationsTab)
            }
            Tab(L("Shortcuts"), systemImage: "keyboard") {
                SettingsForm(sections: SettingsForm.Section.shortcutsTab)
            }
        }
        .frame(width: 520)
        #else
        SettingsForm(sections: SettingsForm.Section.available)
            .navigationTitle(L("Settings"))
        #endif
    }
}

#if os(macOS)
/// Sizes a settings tab to its content's height, capped so the window always fits the screen.
/// Applied to every tab by `SettingsForm`, so adding sections can't push the window off screen.
struct SettingsHeightCap: ViewModifier {
    /// Room for the title bar and tab toolbar, plus a margin so the window never touches the Dock.
    static let windowChrome: CGFloat = 140
    /// Tall enough for any tab on a large display, without a towering window.
    static let comfortableMax: CGFloat = 720
    static let minimum: CGFloat = 240

    let maxHeight: CGFloat

    static func limit(visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight else { return self.comfortableMax }
        return max(self.minimum, min(self.comfortableMax, visibleScreenHeight - self.windowChrome))
    }

    @MainActor static func screenLimit() -> CGFloat {
        self.limit(visibleScreenHeight: (NSApp?.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height)
    }

    func body(content: Content) -> some View {
        CappedHeightLayout(maxHeight: self.maxHeight) { content }
    }
}

/// Reports `min(ideal height, maxHeight)`, so short content stays compact and tall content scrolls.
private struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, self.maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif

enum ReactionFeature {
    static let enabledKey = "pincer.reactions.enabled"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? self.defaultEnabled
    }
}

struct SettingsForm: View {
    enum Section: CaseIterable {
        case you, launch, quickCapture, menuBar, appearance, avatars, colors, conversation, readAloud, sidebar, notifications, keyboardShortcuts, device, storage, tips

        /// Sections that exist on this platform.
        static var available: [Self] {
            #if os(macOS)
            Self.allCases
            #else
            Self.allCases.filter { $0 != .launch && $0 != .quickCapture && $0 != .menuBar }
            #endif
        }

        #if os(macOS)
        static let generalTab: [Self] = [.you, .launch, .quickCapture, .menuBar, .device, .storage, .tips]
        static let appearanceTab: [Self] = [.appearance, .avatars, .colors]
        static let conversationTab: [Self] = [.conversation, .readAloud, .sidebar]
        static let notificationsTab: [Self] = [.notifications]
        static let shortcutsTab: [Self] = [.keyboardShortcuts]
        /// The Settings window's tabs, in order.
        static let macTabs = [generalTab, appearanceTab, conversationTab, notificationsTab, shortcutsTab]
        #endif
    }

    let sections: [Section]
    #if os(macOS)
    /// Every tab hugs its content but never grows taller than this; longer tabs scroll.
    var maxHeight = SettingsHeightCap.screenLimit()
    #endif
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

    var body: some View {
        Form {
            ForEach(self.sections, id: \.self) { self.section($0) }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .modifier(SettingsHeightCap(maxHeight: self.maxHeight))
        #endif
    }

    @ViewBuilder private func section(_ section: Section) -> some View {
        switch section {
        case .you:
            SwiftUI.Section {
                TextField(L("Display name"), text: self.$ownerName, prompt: Text(Owner.displayName))
            } header: {
                Text("You", bundle: .module)
            } footer: {
                Text("Your messages show under this name, whichever channel they came from.", bundle: .module)
            }
        case .tips:
            TipsSettingsSection()
        case .readAloud:
            ReadAloudSettingsSection()
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
                Picker(L("Appearance"), selection: self.$mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                ThemePresetGrid(selection: self.$preset)
            } header: {
                Text("Theme", bundle: .module)
            } footer: {
                Text("Themes set the accent, links, avatars and backgrounds. Default follows your system accent color.", bundle: .module)
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
                    Text("Colors", bundle: .module)
                    Spacer()
                    if !self.theme.overrides.isEmpty {
                        Button(L("Reset All")) { AppTheme.resetOverrides() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Pick a color to override the theme for just that part.", bundle: .module)
            }
        case .conversation:
            SwiftUI.Section(L("Conversation")) {
                Picker(selection: self.$thinkingDisplay) {
                    ForEach(ThinkingDisplay.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Thinking steps", bundle: .module)
                    Text(self.thinkingDisplay.detail + " Includes reasoning and tool calls.")
                }
                Toggle(isOn: self.$loadWebImages) {
                    Text("Load images the agent links from the web", bundle: .module)
                    Text("Like OpenClaw's web UI. The image's website can see your IP address.", bundle: .module)
                }
                Toggle(isOn: self.$reactionsEnabled) {
                    Text("Enable experimental reactions", bundle: .module)
                    Text("Off by default. Reactions may not interoperate across channels or Gateways.", bundle: .module)
                }
            }
        case .sidebar:
            SwiftUI.Section(L("Sidebar")) {
                Toggle(isOn: self.$showMessagePreviews) {
                    Text("Show last message under each chat", bundle: .module)
                    Text("A one-line preview of the latest message in the chat list.", bundle: .module)
                }
                Toggle(isOn: self.$showSubagentRuns) {
                    Text("List subagent runs under their chat", bundle: .module)
                    Text("Off keeps one thread per chat. Open a run from its tool call instead.", bundle: .module)
                }
            }
        case .notifications:
            NotificationSettingsSection()
        case .keyboardShortcuts:
            #if os(macOS)
            KeyboardShortcutsSettingsSections()
            #else
            // iPad with a hardware keyboard; iPhone has no menu commands to rebind.
            if UIDevice.current.userInterfaceIdiom == .pad {
                SwiftUI.Section {
                    NavigationLink(L("Keyboard Shortcuts")) { KeyboardShortcutsSettingsPage() }
                } footer: {
                    Text("For a hardware keyboard.", bundle: .module)
                }
            }
            #endif
        case .device:
            SwiftUI.Section(L("This device")) {
                LabeledContent(L("Device ID")) {
                    Text(DeviceIdentity.loadOrCreate().deviceId.prefix(16) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent(L("Role"), value: "operator (read, write, approvals, questions)")
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
            LabeledContent(L("Cached transcripts")) {
                if !self.enabled {
                    Text("Off", bundle: .module)
                } else if let usage {
                    Text(usage.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button(L("Clear Cache…"), role: .destructive) { self.confirming = true }
                .disabled(!self.enabled || self.usage == 0)
                .confirmationDialog(L("Clear cached transcripts?"), isPresented: self.$confirming, titleVisibility: .visible) {
                    Button(L("Clear Cache"), role: .destructive) {
                        Task {
                            await self.app.clearTranscriptCache()
                            await self.measure()
                        }
                    }
                } message: {
                    Text("Chats are downloaded again from your Gateways when you open them, and message search is rebuilt. Nothing on your Gateways is deleted.", bundle: .module)
                }
            LabeledContent(L("Outbox")) {
                Text(self.app.unsentCount == 1 ? "1 message" : "\(self.app.unsentCount.formatted()) messages")
                    .monospacedDigit()
            }
            Button(L("Clear Outbox…"), role: .destructive) { self.confirmingUnsent = true }
                .disabled(self.app.unsentCount == 0)
                .confirmationDialog(L("Clear the outbox?"), isPresented: self.$confirmingUnsent, titleVisibility: .visible) {
                    Button(L("Clear Outbox"), role: .destructive) { self.app.discardUnsentMessages() }
                } message: {
                    Text("Queued and failed messages are deleted from this device without being sent. Chats and cached transcripts aren’t affected.", bundle: .module)
                }
        } header: {
            Text("Storage", bundle: .module)
        } footer: {
            Text("Chat history is kept on this device so chats open instantly, even offline, and so you can search your messages. Messages you write offline wait here until they send.", bundle: .module)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg) {
            ForEach(ThemePreset.allCases) { preset in
                Button { self.selection = preset } label: { self.swatch(preset) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("\(preset.label) theme"))
                    .accessibilityAddTraits(preset == self.selection ? .isSelected : [])
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func swatch(_ preset: ThemePreset) -> some View {
        let selected = preset == self.selection
        let colors = preset.swatch
        return VStack(spacing: Theme.Spacing.sm) {
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
        .padding(.vertical, Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(selected ? AnyShapeStyle(colors[0].opacity(0.15)) : AnyShapeStyle(.quinary)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(selected ? colors[0] : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
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
                HStack(spacing: Theme.Spacing.sm) {
                    Text(self.role.label)
                    if overridden {
                        Text("Custom", bundle: .module).font(.caption).foregroundStyle(.secondary)
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
                .help(L("Use the theme's color"))
                .accessibilityLabel(L("Reset \(self.role.label)"))
            }
        }
        // Reset or Reset All: follow the theme again.
        .onChange(of: overridden) { _, overridden in
            if !overridden { self.picked = nil }
        }
    }
}
