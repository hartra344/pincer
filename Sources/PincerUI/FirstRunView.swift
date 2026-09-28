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
        HStack(spacing: 12) {
            if let number = state.stepNumber {
                FirstRunProgress(number: number, stage: state.stage)
            }
            Spacer(minLength: 0)
            if self.canClose {
                Button(state.step == .gatewaySetup ? "Skip to Chats" : "Close") { self.model.send(.cancel) }
                    .keyboardShortcut(".", modifiers: .command)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct FirstRunProgress: View {
    let number: Int
    let stage: FirstRunStage

    var body: some View {
        let stages = FirstRunState.countedStages
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(stages, id: \.self) { stage in
                    Capsule()
                        .fill(stage <= self.stage ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: stage == self.stage ? 18 : 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Text("Step \(self.number) of \(stages.count) · \(self.stage.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One screen: a scrolling column (so large Dynamic Type never clips) and a button bar.
private struct FirstRunPage<Content: View, Buttons: View>: View {
    let symbol: String?
    var symbolColor: Color?
    let title: String
    let message: String?
    /// Centered in the window while it fits (Welcome).
    var centered = false
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons

    init(symbol: String? = nil, symbolColor: Color? = nil, title: String, message: String? = nil, centered: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons)
    {
        self.centered = centered
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.title = title
        self.message = message
        self.content = content()
        self.buttons = buttons()
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
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .defaultScrollAnchor(self.centered ? .center : .top, for: .alignment)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { self.buttons }
                VStack(spacing: 10) { self.buttons }
            }
            .controlSize(.large)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

/// Back, with Esc on macOS.
private struct BackButton: View {
    let model: FirstRunModel

    var body: some View {
        Button("Back") { self.model.send(.back) }
            .keyboardShortcut(.cancelAction)
    }
}

/// A monospaced, selectable command with a labeled Copy button.
private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(self.command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Clipboard.copy(self.command)
                self.copied = true
            } label: {
                Label(self.copied ? "Copied" : "Copy", systemImage: self.copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(self.copied ? "Copied" : "Copy command")
            .accessibilityHint(self.command)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.1)))
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
        if step == .verify { self.announce("Connected to \(state.resolvedName)") }
    }
}

// MARK: Welcome

private struct FirstRunWelcome: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(symbol: "bubble.left.and.text.bubble.right", title: "Welcome to Pincer",
                     message: "Chat with your OpenClaw agents from your Mac, iPhone, and iPad.", centered: true) {
            EmptyView()
        } buttons: {
            Button("Try the Demo") { self.model.send(.tryDemo) }
            Spacer(minLength: 0)
            Button("Get Started") { self.model.send(.getStarted) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: Do you have a gateway?

private struct FirstRunHaveGateway: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(title: "Do you have an OpenClaw Gateway?",
                     message: "Pincer connects to a Gateway you run on your own computer or server.") {
            VStack(spacing: 12) {
                self.choice("Yes, it's running", symbol: "checkmark.circle", yes: true)
                    .keyboardShortcut(.defaultAction)
                self.choice("No, help me set one up", symbol: "questionmark.circle", yes: false)
            }
        } buttons: {
            BackButton(model: self.model)
            Spacer(minLength: 0)
        }
    }

    private func choice(_ title: String, symbol: String, yes: Bool) -> some View {
        Button {
            self.model.send(.answerHaveGateway(yes))
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: Set up OpenClaw

private struct FirstRunInstall: View {
    let model: FirstRunModel

    var body: some View {
        FirstRunPage(symbol: "terminal", title: "Set up OpenClaw",
                     message: "Run these on the computer that will host your Gateway. It takes about 5 minutes.") {
            self.step(1, "Install OpenClaw", command: FirstRunCopy.installCommand, caption: "Follow the prompts. Choose Quick start.")
            DisclosureGroup("On Windows") {
                CommandBox(command: FirstRunCopy.installCommandWindows).padding(.top, 6)
            }
            self.step(2, "Keep it running", command: FirstRunCopy.keepRunningCommand)
            self.step(3, "Check it's working", command: FirstRunCopy.statusCommand)
            Link("Full install guide", destination: FirstRunCopy.installGuideURL)
        } buttons: {
            BackButton(model: self.model)
            Button("Try the Demo") { self.model.send(.tryDemo) }
            Spacer(minLength: 0)
            Button("My Gateway Is Running") { self.model.send(.installed) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private func step(_ number: Int, _ title: String, command: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)").font(.headline)
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
        FirstRunPage(title: "Find your Gateway", message: "Where is OpenClaw running?") {
            if !state.discovered.isEmpty {
                self.nearby(state.discovered)
            }
            Picker("Location", selection: Binding(get: { self.model.state.location },
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
            HStack(spacing: 16) {
                Button("Advanced…", action: self.advanced).buttonStyle(.borderless)
                Link("Help me choose", destination: FirstRunCopy.chooseHelpURL)
            }
            .font(.callout)
        } buttons: {
            BackButton(model: self.model)
            Spacer(minLength: 0)
            if state.canSkip {
                Button("Continue Anyway") { self.model.send(.skip) }
            }
            Button {
                self.model.send(.checkAddress)
            } label: {
                if state.reachability.isChecking {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                } else {
                    Text("Continue")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!state.canCheckAddress)
        }
        #if os(macOS)
        // iOS leaves the keyboard down so the help and commands above the field stay visible.
        .onAppear { if state.trimmedAddress.isEmpty || state.location != .thisMac { self.addressFocused = true } }
        #endif
        .onChange(of: state.reachability.isChecking) { _, checking in
            if checking { FirstRunAnnouncer.announce("Checking…") }
        }
        .onChange(of: state.reachabilityMessage) { _, message in
            if let message { FirstRunAnnouncer.announce(message) }
        }
    }

    @ViewBuilder private func addressField(_ state: FirstRunState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gateway address").font(.headline)
            TextField("Gateway address", text: Binding(get: { self.model.state.address },
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
                .accessibilityLabel("Gateway address")
            if let error = state.addressError {
                InlineMessage(text: error)
            } else if let message = state.reachabilityMessage {
                InlineMessage(text: message)
            } else if !state.trimmedAddress.isEmpty {
                Text("Pincer will connect to \(state.normalizedAddress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let hint = state.addressHint { InlineMessage(text: hint, isError: false) }
        }
    }

    private func nearby(_ gateways: [FirstRunDiscoveredGateway]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nearby").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(gateways) { gateway in
                Button {
                    self.model.send(.useDiscovered(gateway))
                } label: {
                    HStack {
                        Image(systemName: "server.rack").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
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
        case .thisMac: "This Mac"
        case .tailscale: "Tailscale"
        case .sameNetwork: "Same Wi-Fi"
        }
    }

    static func help(_ location: FirstRunLocation) -> String {
        switch location {
        case .thisMac: "OpenClaw is running on this Mac."
        case .tailscale:
            "Your Gateway is on another device in your tailnet. Turn on Tailscale Serve on the Gateway host, then use its address."
        case .sameNetwork: "Your Gateway is on this network and set to accept connections from it."
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
        FirstRunPage(symbol: "key", title: "Sign in to your Gateway",
                     message: isToken ? "Paste your Gateway token. You'll only need to do this once." : nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isToken ? "Token" : "Password").font(.headline)
                HStack {
                    SecureField(isToken ? "Token" : "Password", text: self.secretBinding)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused(self.$secretFocused)
                        .onSubmit(self.signIn)
                        .accessibilityLabel(isToken ? "Token" : "Password")
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Run this on the Gateway host to see it:").foregroundStyle(.secondary)
                CommandBox(command: isToken ? FirstRunCopy.tokenCommand : FirstRunCopy.passwordCommand)
            }
            Button(isToken ? "Use a password instead" : "Use a token instead") {
                self.model.send(.setAuthMode(isToken ? .password : .token))
            }
            .buttonStyle(.borderless)
            .disabled(state.signInStatus.isBusy)
            Text("Signing in to \(state.normalizedAddress)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } buttons: {
            BackButton(model: self.model)
            Spacer(minLength: 0)
            Button(action: self.signIn) {
                if state.signInStatus == .connecting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Signing in…") }
                } else {
                    Text("Sign In")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
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
        FirstRunPage(symbol: "lock.shield", title: "Approve Pincer on your Gateway",
                     message: "For your security, new devices need your OK. Run this on the Gateway host:") {
            CommandBox(command: FirstRunCopy.approveCommand(requestId: self.requestId))
            if self.requestId == nil {
                Text("Find Pincer in the list and approve its request ID.").font(.caption).foregroundStyle(.secondary)
            }
            if self.model.state.pairingRequestChanged {
                InlineMessage(text: FirstRunCopy.requestChanged, isError: false)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…")
            }
            .accessibilityElement(children: .combine)
            Text("Device ID: \(String(self.deviceId.prefix(16)))…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            DisclosureGroup("Didn't work?", isExpanded: self.$showsHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("If you changed settings, the request ID may have changed. Run openclaw devices list to see the latest one.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandBox(command: FirstRunCopy.listDevicesCommand)
                }
                .padding(.top, 6)
            }
        } buttons: {
            BackButton(model: self.model)
            Spacer(minLength: 0)
        }
        .onAppear { FirstRunAnnouncer.announce("Waiting for approval…") }
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
        FirstRunPage(symbol: "checkmark.circle.fill", symbolColor: .green, title: "You're connected") {
            if let verified = state.verified {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Gateway", value: URL(string: state.normalizedAddress)?.host ?? state.normalizedAddress)
                    if let version = verified.serverVersion { LabeledContent("Version", value: version) }
                    LabeledContent("Access", value: verified.hasFullManagement ? "Full Management" : "Chat and approvals")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.headline)
                    TextField("Name", text: Binding(get: { self.model.state.name },
                                                    set: { self.model.send(.setName($0)) }),
                              prompt: Text(FirstRunState.suggestedName(for: state.normalizedAddress)))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityLabel("Name")
                        .onSubmit { self.model.send(.continueToSetup) }
                }
                if !verified.hasFullManagement {
                    Label("Full Management lets Pincer change Gateway settings and agents. You can turn it on later in Connection.",
                          systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let id = verified.questionsRequestId {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Answering agent questions is waiting for approval:").font(.callout).foregroundStyle(.secondary)
                        CommandBox(command: FirstRunCopy.approveCommand(requestId: id))
                    }
                }
                if let problem = verified.healthProblem {
                    // Information only: it never blocks Continue Setup (spec §2.8).
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        InlineMessage(text: "Your Gateway reported a problem: \(problem)", isError: false)
                        Button("Details", action: self.openHealth)
                            .buttonStyle(.borderless)
                            .accessibilityHint("Saves this Gateway and opens its Health page.")
                    }
                }
            }
        } buttons: {
            BackButton(model: self.model)
            Spacer(minLength: 0)
            Button("Skip to Chats") { self.model.send(.skip) }
            Button("Continue Setup") { self.model.send(.continueToSetup) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
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
        FirstRunPage(symbol: "checkmark.seal", title: "You're all set", message: "Start a chat with your agent any time.") {
            EmptyView()
        } buttons: {
            Spacer(minLength: 0)
            Button("Go to Chats") { self.model.send(.finish) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
