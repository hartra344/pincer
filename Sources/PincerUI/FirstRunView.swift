import PincerKit
import SwiftUI

/// The first-run wizard (#175): from launch to a connected, set-up gateway. Drives
/// `AppModel.firstRun`; every change goes through `FirstRunModel.send` from an action or
/// `onChange`, never from `body`.
struct FirstRunView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        FirstRunScreens(model: self.app.firstRun)
    }
}

/// Something to do after a sheet or cover is dismissed.
struct AfterDismiss {
    let run: @MainActor () -> Void
}

/// iOS: inside the first-run cover, queues an action for once the cover is gone. Always equal, so
/// setting it never invalidates the views that read it (#119).
struct FirstRunDismissQueue: Equatable {
    let enqueue: @MainActor (AfterDismiss) -> Void

    @MainActor func callAsFunction(_ action: AfterDismiss) { self.enqueue(action) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var firstRunAfterDismiss: FirstRunDismissQueue?
}

/// iOS "Add Gateway…" over the chat list: a full-screen cover, so nothing hands off sheet to sheet (#133).
struct FirstRunCover: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var afterDismiss: AfterDismiss?

    func body(content: Content) -> some View {
        #if os(iOS)
        @Bindable var model = self.app.firstRun
        content.fullScreenCover(isPresented: $model.isSheetPresented, onDismiss: self.dismissed) {
            FirstRunView()
                .environment(\.firstRunAfterDismiss, FirstRunDismissQueue { self.afterDismiss = $0 })
        }
        #else
        content
        #endif
    }

    private func dismissed() {
        let action = self.afterDismiss
        self.afterDismiss = nil
        action?.run()
    }
}

private struct FirstRunScreens: View {
    let model: FirstRunModel
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.firstRunAfterDismiss) private var firstRunAfterDismiss
    @State private var advanced: AdvancedRequest?

    var body: some View {
        let state = self.model.state
        VStack(spacing: 0) {
            FirstRunHeader(model: self.model, canClose: !self.app.gateways.isEmpty)
            Group {
                switch state.step {
                case .welcome: FirstRunWelcome(model: self.model)
                case .haveGateway: FirstRunHaveGateway(model: self.model)
                case .install: FirstRunInstall(model: self.model)
                case .findGateway: FirstRunFind(model: self.model, advanced: { self.advanced = AdvancedRequest(state: state) })
                case .signIn:
                    if case let .awaitingPairing(requestId, deviceId) = state.signInStatus {
                        FirstRunPairing(model: self.model, requestId: requestId, deviceId: deviceId)
                    } else {
                        FirstRunSignInScreen(model: self.model)
                    }
                case .verify: FirstRunVerify(model: self.model, openHealth: self.openHealth)
                case .gatewaySetup: FirstRunGatewaySetup(model: self.model, openSettings: self.openSettings)
                case .done: FirstRunDone(model: self.model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .sheet(item: self.$advanced) { request in
            ConnectionSheet(draft: request.draft)
        }
        .onChange(of: state.step) { _, step in
            FirstRunAnnouncer.announce(step: step, state: self.model.state)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: FirstRunTour.showAdvanced)) { _ in
            self.advanced = self.advanced == nil && state.step == .findGateway ? AdvancedRequest(state: self.model.state) : nil
        }
        #endif
    }

    /// A settings link inside the embedded setup: leave for the chat list, then open it.
    private func openSettings(_ destination: SettingsDestination) {
        guard let id = self.model.gateway?.id else { return }
        self.leave(then: destination, gatewayId: id)
    }

    /// Verify's Details: saves the gateway (as Skip to Chats does), then opens its Health page.
    private func openHealth() {
        self.leave(then: .health, gatewayId: self.model.state.profileId)
    }

    /// Skip to the chat list, then open `destination` for the gateway once the wizard is gone.
    private func leave(then destination: SettingsDestination, gatewayId: UUID) {
        let opener = self.openGatewaySettings
        let app = self.app
        let open = { @MainActor in
            if let gateway = app.gateways.first(where: { $0.id == gatewayId }) { opener(gateway, at: destination) }
        }
        if let afterDismiss = self.firstRunAfterDismiss {
            afterDismiss(AfterDismiss(run: open))
            self.model.send(.skip)
        } else {
            self.model.send(.skip)
            open()
        }
    }
}

/// Advanced…: the full connection form with what's been entered so far.
private struct AdvancedRequest: Identifiable {
    let id = UUID()
    let draft: ConnectionDraft

    init(state: FirstRunState) {
        var draft = ConnectionDraft()
        draft.url = state.trimmedAddress.isEmpty ? "" : state.normalizedAddress
        draft.name = state.trimmedAddress.isEmpty ? draft.name : state.resolvedName
        draft.authMode = state.authMode
        self.draft = draft
    }
}

// MARK: Chrome

/// "Step N of 5", a dot per stage, and Close (⌘.) when there's somewhere to go back to.
private struct FirstRunHeader: View {
    let model: FirstRunModel
    let canClose: Bool

    var body: some View {
        let state = self.model.state
        HStack(spacing: Theme.Spacing.xl) {
            if let number = state.stepNumber {
                FirstRunProgress(number: number, stage: state.stage)
            }
            Spacer(minLength: 0)
            if self.canClose {
                Button(state.step == .gatewaySetup ? L("Skip to Chats") : L("Close")) { self.model.send(.cancel) }
                    .keyboardShortcut(".", modifiers: .command)
                    .firstRunLink()
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.xl)
    }
}

private struct FirstRunProgress: View {
    let number: Int
    let stage: FirstRunStage

    var body: some View {
        let stages = FirstRunState.countedStages
        HStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(stages, id: \.self) { stage in
                    Capsule()
                        .fill(stage <= self.stage ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: stage == self.stage ? 18 : 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Text("Step \(self.number) of \(stages.count) · \(self.stage.title)", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One screen: a scrolling column (so large Dynamic Type never clips) and a button bar pinned to the
/// bottom: secondary buttons on the left and the primary on the right, or, when that doesn't fit,
/// the primary full width on top with the others in a row under it.
private struct FirstRunPage<Content: View, Secondary: View, Primary: View>: View {
    let symbol: String?
    var symbolColor: Color?
    let title: String
    let message: String?
    /// Centered in the window while it fits (Welcome).
    var centered = false
    /// Welcome keeps its buttons in the content, so it has no button bar.
    var showsFooter = true
    @ViewBuilder let content: Content
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let primary: Primary

    init(symbol: String? = nil, symbolColor: Color? = nil, title: String, message: String? = nil, centered: Bool = false,
         showsFooter: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder secondary: () -> Secondary,
         @ViewBuilder primary: () -> Primary = { EmptyView() })
    {
        self.centered = centered
        self.showsFooter = showsFooter
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.title = title
        self.message = message
        self.content = content()
        self.secondary = secondary()
        self.primary = primary()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.largeTitle)
                            .foregroundStyle(self.symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                            .accessibilityHidden(true)
                    }
                    Text(self.title)
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    self.content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, Theme.Spacing.section)
            }
            .defaultScrollAnchor(self.centered ? .center : .top, for: .alignment)
            .frame(maxHeight: .infinity)
            if self.showsFooter { self.footer }
        }
    }

    @ViewBuilder private var footer: some View {
        Divider()
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xl) {
                self.secondary
                Spacer(minLength: 12)
                self.primary
            }
            VStack(spacing: Theme.Spacing.xl) {
                self.primary.environment(\.firstRunWideButtons, true)
                HStack(spacing: Theme.Spacing.section) { self.secondary }
            }
        }
        .controlSize(.large)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.row)
    }
}

extension EnvironmentValues {
    /// The footer stacked: primary buttons fill the width.
    @Entry var firstRunWideButtons = false
}

/// The screen's main action: prominent, Return, full width when the footer is stacked.
private struct PrimaryButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.firstRunWideButtons) private var wide

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: self.action) {
            self.label.frame(maxWidth: self.wide ? .infinity : nil)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }
}

extension PrimaryButton where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

extension View {
    /// A text button that reads as a link: the accent color, like `Link` (macOS borderless is gray).
    func firstRunLink() -> some View {
        #if os(macOS)
        self.buttonStyle(.link)
        #else
        self.buttonStyle(.borderless)
        #endif
    }
}

/// Back, with Esc on macOS.
private struct BackButton: View {
    let model: FirstRunModel

    var body: some View {
        Button(L("Back")) { self.model.send(.back) }
            .keyboardShortcut(.cancelAction)
    }
}

/// A monospaced, selectable command with a labeled Copy button.
private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            Text(self.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(self.command)
                self.copied = true
            } label: {
                Label(self.copied ? L("Copied") : L("Copy"), systemImage: self.copied ? L("checkmark") : L("doc.on.doc"))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(self.copied ? L("Copied") : L("Copy command"))
            .accessibilityHint(self.command)
        }
        .padding(Theme.Spacing.xl)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Color.secondary.opacity(0.1)))
        .task(id: self.copied) {
            guard self.copied else { return }
            try? await Task.sleep(for: .seconds(2))
            self.copied = false
        }
    }
}

/// An inline error or note under a field.
private struct InlineMessage: View {
    let text: String
    var isError = true

    var body: some View {
        Label {
            Text(self.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: self.isError ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(.callout)
        .foregroundStyle(self.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}

enum FirstRunAnnouncer {
    /// Status changes VoiceOver should hear once (not on every retry).
    @MainActor static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    @MainActor static func announce(step: FirstRunStep, state: FirstRunState) {
        if step == .verify { self.announce(L("Connected to \(state.resolvedName)")) }
    }
}

// MARK: Welcome

private struct FirstRunWelcome: View {
    let model: FirstRunModel

    var body: some View {
        // The demo is one tap from the very first screen, in the content and never a footer extra:
        // it's how App Review and Apple developers get in (#175).
        FirstRunPage(symbol: "bubble.left.and.text.bubble.right", title: L("Welcome to Pincer"),
                     message: L("Chat with your OpenClaw agents from your Mac, iPhone, and iPad."), centered: true,
                     showsFooter: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Button { self.model.send(.getStarted) } label: {
                    Text("Get Started", bundle: .module).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("firstRun.getStarted")
                Button { self.model.send(.tryDemo) } label: {
                    Text("Try the Demo", bundle: .module).frame(maxWidth: .infinity)
                }
                .keyboardShortcut("d", modifiers: .command)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("firstRun.tryDemo")
                .accessibilityHint(FirstRunCopy.demoCaption)
                Text(FirstRunCopy.demoCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            .controlSize(.large)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.top, Theme.Spacing.sm)
        } secondary: {
            EmptyView()
        }
    }
}

// MARK: Do you have a gateway?

private struct FirstRunHaveGateway: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(title: L("Do you have an OpenClaw Gateway?"),
                     message: L("Pincer connects to a Gateway you run on your own computer or server.")) {
            VStack(spacing: Theme.Spacing.xl) {
                self.choice(L("Yes, it's running"), symbol: "checkmark.circle", yes: true)
                    .keyboardShortcut(.defaultAction)
                self.choice(L("No, help me set one up"), symbol: "questionmark.circle", yes: false)
            }
        } secondary: {
            BackButton(model: self.model)
        }
    }

    private func choice(_ title: String, symbol: String, yes: Bool) -> some View {
        Button {
            self.model.send(.answerHaveGateway(yes))
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.sm)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: Set up OpenClaw

private struct FirstRunInstall: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(symbol: "terminal", title: L("Set up OpenClaw"),
                     message: L("Run these on the computer that will host your Gateway. It takes about 5 minutes.")) {
            self.step(1, L("Install OpenClaw"), command: FirstRunCopy.installCommand, caption: L("Follow the prompts. Choose Quick start."))
            DisclosureGroup(L("On Windows")) {
                CommandBox(command: FirstRunCopy.installCommandWindows).padding(.top, Theme.Spacing.sm)
            }
            self.step(2, L("Keep it running"), command: FirstRunCopy.keepRunningCommand)
            self.step(3, L("Check it's working"), command: FirstRunCopy.statusCommand)
            Link(L("Full install guide"), destination: FirstRunCopy.installGuideURL)
        } secondary: {
            BackButton(model: self.model)
            Button(L("Try the Demo")) { self.model.send(.tryDemo) }
        } primary: {
            PrimaryButton(L("My Gateway Is Running")) { self.model.send(.installed) }
        }
    }

    private func step(_ number: Int, _ title: String, command: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(verbatim: "\(number). \(title)").font(.headline)
            CommandBox(command: command)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Find your gateway

private struct FirstRunFind: View {
    let model: FirstRunModel
    let advanced: () -> Void
    @FocusState private var addressFocused: Bool

    var body: some View {
        let state = self.model.state
        FirstRunPage(title: L("Find your Gateway"), message: L("Where is OpenClaw running?")) {
            if !state.discovered.isEmpty {
                self.nearby(state.discovered)
            }
            Picker(L("Location"), selection: Binding(get: { self.model.state.location },
                                                  set: { self.model.send(.setLocation($0)) })) {
                ForEach(FirstRunLocation.available(macOS: FirstRunModel.isMacOS)) { location in
                    Text(Self.title(location)).tag(location)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(Self.help(state.location))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.location == .tailscale {
                ForEach(FirstRunCopy.tailscaleServeCommands, id: \.self) { CommandBox(command: $0) }
            }
            self.addressField(state)
            HStack(spacing: Theme.Spacing.xxl) {
                Button(L("Advanced…"), action: self.advanced).firstRunLink()
                Link(L("Help me choose"), destination: FirstRunCopy.chooseHelpURL)
            }
            .font(.callout)
        } secondary: {
            BackButton(model: self.model)
            // Only after a failed reachability check of a valid, secure address (never for invalid or insecure ones).
            if state.canSkip {
                Button(L("Continue Anyway")) { self.model.send(.skip) }
            }
        } primary: {
            PrimaryButton {
                self.model.send(.checkAddress)
            } label: {
                if state.reachability.isChecking {
                    HStack(spacing: Theme.Spacing.sm) { ProgressView().controlSize(.small); Text("Checking…", bundle: .module) }
                } else {
                    Text(state.canSkip ? L("Try Again") : L("Continue"))
                }
            }
            .disabled(!state.canCheckAddress)
        }
        #if os(macOS)
        // iOS leaves the keyboard down so the help and commands above the field stay visible.
        .onAppear { if state.trimmedAddress.isEmpty || state.location != .thisMac { self.addressFocused = true } }
        #endif
        .onChange(of: state.reachability.isChecking) { _, checking in
            if checking { FirstRunAnnouncer.announce(L("Checking…")) }
        }
        .onChange(of: state.reachabilityMessage) { _, message in
            if let message { FirstRunAnnouncer.announce(message) }
        }
    }

    @ViewBuilder private func addressField(_ state: FirstRunState) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Gateway address", bundle: .module).font(.headline)
            TextField(L("Gateway address"), text: Binding(get: { self.model.state.address },
                                                       set: { self.model.send(.setAddress($0)) }),
                      prompt: Text(Self.placeholder(state.location)))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused(self.$addressFocused)
                .onSubmit { self.model.send(.checkAddress) }
                .accessibilityLabel(L("Gateway address"))
            if let error = state.addressError {
                InlineMessage(text: error)
            } else if let message = state.reachabilityMessage {
                InlineMessage(text: message)
            } else if !state.trimmedAddress.isEmpty {
                Text("Pincer will connect to \(state.normalizedAddress)", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let hint = state.addressHint { InlineMessage(text: hint, isError: false) }
        }
    }

    private func nearby(_ gateways: [FirstRunDiscoveredGateway]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Nearby", bundle: .module).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(gateways) { gateway in
                Button {
                    self.model.send(.useDiscovered(gateway))
                } label: {
                    HStack {
                        Image(systemName: "server.rack").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text(gateway.name)
                            Text(gateway.address).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(gateway.name), \(gateway.address)")
            }
        }
    }

    static func title(_ location: FirstRunLocation) -> String {
        switch location {
        case .thisMac: L("This Mac")
        case .tailscale: L("Tailscale")
        case .sameNetwork: L("Same Wi-Fi")
        }
    }

    static func help(_ location: FirstRunLocation) -> String {
        switch location {
        case .thisMac: L("OpenClaw is running on this Mac.")
        case .tailscale:
            L("Your Gateway is on another device in your tailnet. Turn on Tailscale Serve on the Gateway host, then use its address.")
        case .sameNetwork: L("Your Gateway is on this network and set to accept connections from it.")
        }
    }

    static func placeholder(_ location: FirstRunLocation) -> String {
        switch location {
        case .thisMac: FirstRunLocation.thisMacAddress
        case .tailscale: "wss://my-mac.tailnet-name.ts.net"
        case .sameNetwork: "ws://192.168.1.20:18789"
        }
    }
}

// MARK: Sign in

private struct FirstRunSignInScreen: View {
    let model: FirstRunModel
    @FocusState private var secretFocused: Bool

    var body: some View {
        let state = self.model.state
        let isToken = state.authMode != .password
        FirstRunPage(symbol: "key", title: L("Sign in to your Gateway"),
                     message: isToken ? L("Paste your Gateway token. You'll only need to do this once.") : nil) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(isToken ? L("Token") : L("Password")).font(.headline)
                HStack {
                    SecureField(isToken ? L("Token") : L("Password"), text: self.secretBinding)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused(self.$secretFocused)
                        .onSubmit(self.signIn)
                        .accessibilityLabel(isToken ? L("Token") : L("Password"))
                    #if os(iOS)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in self.model.secret = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    #endif
                }
                if let error = state.signInStatus.error { InlineMessage(text: error) }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Run this on the Gateway host to see it:", bundle: .module).foregroundStyle(.secondary)
                CommandBox(command: isToken ? FirstRunCopy.tokenCommand : FirstRunCopy.passwordCommand)
            }
            Button(isToken ? L("Use a password instead") : L("Use a token instead")) {
                self.model.send(.setAuthMode(isToken ? .password : .token))
            }
            .firstRunLink()
            .disabled(state.signInStatus.isBusy)
            Text("Signing in to \(state.normalizedAddress)", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        } secondary: {
            BackButton(model: self.model)
        } primary: {
            PrimaryButton(action: self.signIn) {
                if state.signInStatus == .connecting {
                    HStack(spacing: Theme.Spacing.sm) { ProgressView().controlSize(.small); Text("Signing in…", bundle: .module) }
                } else {
                    Text("Sign In", bundle: .module)
                }
            }
            .disabled(state.signInStatus.isBusy || self.model.secret.isEmpty)
        }
        .onAppear { self.secretFocused = true }
        .onChange(of: state.signInStatus.error) { _, error in
            // Keep what was typed and put the cursor back in the field.
            guard let error else { return }
            self.secretFocused = true
            FirstRunAnnouncer.announce(error)
        }
    }

    /// Writes only when the text changes (#119).
    private var secretBinding: Binding<String> {
        Binding(get: { self.model.secret },
                set: { if $0 != self.model.secret { self.model.secret = $0 } })
    }

    private func signIn() {
        self.model.send(.signIn(hasSecret: !self.model.secret.isEmpty))
    }
}

// MARK: Approve this device

private struct FirstRunPairing: View {
    let model: FirstRunModel
    let requestId: String?
    let deviceId: String
    @State private var showsHelp = false

    var body: some View {
        FirstRunPage(symbol: "lock.shield", title: L("Approve Pincer on your Gateway"),
                     message: L("For your security, new devices need your OK. Run this on the Gateway host:")) {
            CommandBox(command: FirstRunCopy.approveCommand(requestId: self.requestId))
            if self.requestId == nil {
                Text("Find Pincer in the list and approve its request ID.", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
            if self.model.state.pairingRequestChanged {
                InlineMessage(text: FirstRunCopy.requestChanged, isError: false)
            }
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…", bundle: .module)
            }
            .accessibilityElement(children: .combine)
            Text("Device ID: \(String(self.deviceId.prefix(16)))…", bundle: .module)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(FirstRunCopy.approveElsewhere)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("Didn't work?"), isExpanded: self.$showsHelp) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("If you changed settings, the request ID may have changed. Run openclaw devices list to see the latest one.", bundle: .module)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandBox(command: FirstRunCopy.listDevicesCommand)
                }
                .padding(.top, Theme.Spacing.sm)
            }
        } secondary: {
            BackButton(model: self.model)
        }
        .onAppear { FirstRunAnnouncer.announce(L("Waiting for approval…")) }
        .onChange(of: self.model.state.pairingRequestChanged) { _, changed in
            if changed { FirstRunAnnouncer.announce(FirstRunCopy.requestChanged) }
        }
    }
}

// MARK: Verify

private struct FirstRunVerify: View {
    let model: FirstRunModel
    let openHealth: () -> Void

    var body: some View {
        let state = self.model.state
        FirstRunPage(symbol: "checkmark.circle.fill", symbolColor: .green, title: L("You're connected")) {
            if let verified = state.verified {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    LabeledContent(L("Gateway"), value: URL(string: state.normalizedAddress)?.host ?? state.normalizedAddress)
                    if let version = verified.serverVersion { LabeledContent(L("Version"), value: version) }
                    LabeledContent(L("Access"), value: verified.hasFullManagement ? "Full Management" : "Chat and approvals")
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Name", bundle: .module).font(.headline)
                    TextField(L("Name"), text: Binding(get: { self.model.state.name },
                                                    set: { self.model.send(.setName($0)) }),
                              prompt: Text(FirstRunState.suggestedName(for: state.normalizedAddress)))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel(L("Name"))
                        .onSubmit { self.model.send(.continueToSetup) }
                }
                if !verified.hasFullManagement {
                    Label(L("Full Management lets Pincer change Gateway settings and agents. You can turn it on later in Connection."),
                          systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let id = verified.questionsRequestId {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Answering agent questions is waiting for approval:", bundle: .module).font(.callout).foregroundStyle(.secondary)
                        CommandBox(command: FirstRunCopy.approveCommand(requestId: id))
                    }
                }
                if verified.healthProblem != nil {
                    // Information only: it never blocks Continue Setup (spec §2.8).
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                        InlineMessage(text: FirstRunCopy.healthReported, isError: false)
                        Button(L("Details"), action: self.openHealth)
                            .firstRunLink()
                            .accessibilityHint(L("Saves this Gateway and opens its Health page."))
                    }
                }
            }
        } secondary: {
            BackButton(model: self.model)
            Button(L("Skip to Chats")) { self.model.send(.skip) }
        } primary: {
            PrimaryButton(L("Continue Setup")) { self.model.send(.continueToSetup) }
        }
    }
}

// MARK: Set up (the per-gateway steps)

private struct FirstRunGatewaySetup: View {
    let model: FirstRunModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        if let gateway = self.model.gateway {
            FirstRunEmbeddedSetup(model: self.model, gateway: gateway, setup: gateway.setup, openSettings: self.openSettings)
        } else {
            ProgressView()
        }
    }
}

private struct FirstRunEmbeddedSetup: View {
    let model: FirstRunModel
    let gateway: GatewayStore
    let setup: SetupWizardModel
    let openSettings: (SettingsDestination) -> Void

    var body: some View {
        SetupWizardView(setup: self.setup, openSettings: self.openSettings, embedded: true)
            .environment(self.gateway)
            .onChange(of: self.setup.isEmbedded) { _, embedded in
                // Finish or Close in the steps: on to the chat list.
                if !embedded { self.model.send(.gatewaySetupEnded) }
            }
    }
}

// MARK: Done

private struct FirstRunDone: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(symbol: "checkmark.seal", title: L("You're all set"), message: L("Start a chat with your agent any time.")) {
            EmptyView()
        } secondary: {
            EmptyView()
        } primary: {
            PrimaryButton(L("Go to Chats")) { self.model.send(.finish) }
        }
    }
}
