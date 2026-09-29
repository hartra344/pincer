import AuthenticationServices
import PincerKit
import SwiftUI

// MCP OAuth sign-in. The Gateway starts the attempt and receives the provider's callback itself;
// Pincer shows the authorization page in a system web session that closes when the Gateway
// redirects to `pincer://mcp-oauth/done`. The demo has no real provider, so it shows a simulated
// consent sheet instead.

/// Runs one sign-in at a time for a page. Owned by the view as `@State`.
@MainActor @Observable
final class MCPSignInFlow {
    /// The demo's simulated consent request.
    var simulated: MCPOAuthAttempt?
    /// A real attempt that is still waiting (in the web session or the user's browser).
    private(set) var waiting: MCPOAuthAttempt?
    private(set) var isStarting = false
    /// How the last attempt ended, when it's worth saying (denied, timed out, failed).
    var message: String?
    /// The server whose sign-in ended without finishing: its page offers the Gateway host command.
    private(set) var fallbackServer: String?
    /// The window the web session hangs from (macOS: the Gateway Settings window).
    weak var window: AnyObject? {
        didSet { self.presenter.window = self.window }
    }

    private var session: ASWebAuthenticationSession?
    private let presenter = MCPWebAuthPresenter()
    private(set) var handedOff = false
    private var expiry: Task<Void, Never>?

    func isSigningIn(_ name: String) -> Bool {
        self.isStarting || self.simulated?.server == name || self.waiting?.server == name
    }

    func start(_ name: String, model: MCPServersModel) async {
        guard !self.isStarting, self.waiting == nil, self.simulated == nil else { return }
        self.isStarting = true
        self.message = nil
        self.fallbackServer = nil
        defer { self.isStarting = false }
        guard let attempt = await model.startSignIn(name) else { return }
        if attempt.isSimulated {
            self.simulated = attempt
        } else {
            self.begin(attempt, model: model)
        }
    }

    private func begin(_ attempt: MCPOAuthAttempt, model: MCPServersModel) {
        self.waiting = attempt
        self.handedOff = false
        let session = ASWebAuthenticationSession(url: attempt.authorizationURL,
                                                 callbackURLScheme: MCPServers.returnURLScheme) { [weak self] url, error in
            Task { @MainActor in await self?.finished(attempt, url: url, error: error, model: model) }
        }
        session.presentationContextProvider = self.presenter
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            self.waiting = nil
            self.message = L("Couldn't open the sign-in page.")
            self.fallbackServer = attempt.server
            Task { await model.cancelSignIn(attempt) }
            return
        }
        if let expiresAt = attempt.expiresAt {
            self.expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, expiresAt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.timedOut(attempt, model: model)
            }
        }
    }

    private func timedOut(_ attempt: MCPOAuthAttempt, model: MCPServersModel) async {
        guard self.waiting?.id == attempt.id else { return }
        self.end()
        self.message = L("Sign-in timed out. Try again.")
        self.fallbackServer = attempt.server
        await model.cancelSignIn(attempt)
    }

    private func end() {
        self.expiry?.cancel()
        self.expiry = nil
        self.waiting = nil
        self.session?.cancel()
        self.session = nil
    }

    private func finished(_ attempt: MCPOAuthAttempt, url: URL?, error: Error?, model: MCPServersModel) async {
        self.session = nil
        guard self.waiting?.id == attempt.id, !self.handedOff else { return }
        self.end()
        if let url {
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value
            if state == "denied" {
                self.message = L("Sign-in was denied.")
                self.fallbackServer = attempt.server
                await model.cancelSignIn(attempt)
            } else {
                await model.load()
            }
        } else {
            if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                self.message = error.localizedDescription
            }
            self.fallbackServer = attempt.server
            await model.cancelSignIn(attempt)
        }
    }

    /// Moves the sign-in to the default browser; the Gateway's `mcp.oauth.changed` refreshes the page.
    func openInBrowser(_ openURL: OpenURLAction) {
        guard let attempt = self.waiting else { return }
        self.handedOff = true
        self.session?.cancel()
        self.session = nil
        openURL(attempt.authorizationURL)
    }

    func cancel(model: MCPServersModel) async {
        if let attempt = self.waiting {
            self.end()
            await model.cancelSignIn(attempt)
        } else if let attempt = self.simulated {
            self.simulated = nil
            await model.cancelSignIn(attempt)
        }
    }

    func denySimulated(model: MCPServersModel) async {
        guard let attempt = self.simulated else { return }
        self.simulated = nil
        self.message = L("Sign-in was denied.")
        self.fallbackServer = attempt.server
        await model.cancelSignIn(attempt)
    }

    func allowSimulated(model: MCPServersModel) async {
        guard let attempt = self.simulated else { return }
        self.simulated = nil
        if !(await model.completeSignIn(attempt, code: "demo", callbackURL: nil)) {
            self.message = model.operation(for: attempt.server).error ?? L("Sign-in didn't finish.")
        }
    }

    /// Finishes a waiting sign-in with a pasted code or callback link.
    func complete(pasted: String, model: MCPServersModel) async -> Bool {
        guard let attempt = self.waiting else { return false }
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = URL(string: text).flatMap { $0.scheme != nil && $0.host != nil ? $0 : nil }
        if await model.completeSignIn(attempt, code: link == nil ? text : nil, callbackURL: link) {
            self.end()
            return true
        }
        return false
    }

    /// Drops the waiting state once the Gateway reports the server's sign-in finished.
    func reconcile(_ name: String, state: MCPAuthState?) {
        guard let attempt = self.waiting, attempt.server == name, state == .authorized else { return }
        self.end()
    }
}

/// Anchors the web session to the Gateway Settings window (macOS) or the active window (iOS).
private final class MCPWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var window: AnyObject?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return (self.window as? NSWindow) ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return (self.window as? UIWindow) ?? active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

#if os(macOS)
/// Reports the window this view is in.
private struct MCPWindowReader: NSViewRepresentable {
    let report: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { self.report(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { self.report(window) } }
    }
}
#endif

/// Asks for the code or link the provider ended on, for when the Gateway's callback didn't reach this device.
struct MCPPasteCodeSheet: View {
    let complete: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Code or link"), text: self.$text, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if self.failed {
                        Label(L("The Gateway didn't accept that. Check it and try again."), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Paste the code the provider showed, or the full link you were sent to after approving.", bundle: .module)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Paste Code or URL"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Complete")) {
                        self.isWorking = true
                        Task {
                            if await self.complete(self.text) { self.dismiss() } else { self.failed = true }
                            self.isWorking = false
                        }
                    }
                    .disabled(self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 240)
        #endif
    }
}

/// The demo's stand-in for a provider's consent page.
struct MCPSimulatedConsentSheet: View {
    let attempt: MCPOAuthAttempt
    let allow: () -> Void
    let deny: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "person.badge.key").font(.system(size: 40)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Allow Pincer to use \(self.attempt.server)?", bundle: .module).font(.headline)
                Text("This is a simulated sign-in for the demo. No account is used.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(L("Deny"), action: self.deny)
                    Button(L("Allow"), action: self.allow).buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L("Sign In"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel"), action: self.cancel) }
            }
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}

extension View {
    /// Presents the demo consent sheet for `flow` and anchors its web session to this view's window.
    func mcpSignIn(_ flow: MCPSignInFlow, model: MCPServersModel) -> some View {
        self
            .sheet(item: Binding(get: { flow.simulated }, set: { if $0 == nil { flow.simulated = nil } })) { attempt in
                MCPSimulatedConsentSheet(
                    attempt: attempt,
                    allow: { Task { await flow.allowSimulated(model: model) } },
                    deny: { Task { await flow.denySimulated(model: model) } },
                    cancel: { Task { await flow.cancel(model: model) } })
            }
            #if os(macOS)
            .background(MCPWindowReader { flow.window = $0 })
            #endif
    }
}
