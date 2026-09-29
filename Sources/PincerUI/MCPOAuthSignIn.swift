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
    var error: String?

    private var session: ASWebAuthenticationSession?
    private let presenter = MCPWebAuthPresenter()
    private var handedOff = false

    func isSigningIn(_ name: String) -> Bool {
        self.isStarting || self.simulated?.server == name || self.waiting?.server == name
    }

    func start(_ name: String, model: MCPServersModel) async {
        guard !self.isStarting, self.waiting == nil, self.simulated == nil else { return }
        self.isStarting = true
        self.error = nil
        defer { self.isStarting = false }
        guard let attempt = await model.startSignIn(name) else {
            self.error = model.operation(for: name).error ?? L("Couldn't start sign-in.")
            return
        }
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
            self.error = L("Couldn't open the sign-in page.")
            Task { await model.cancelSignIn(attempt) }
        }
    }

    private func finished(_ attempt: MCPOAuthAttempt, url: URL?, error: Error?, model: MCPServersModel) async {
        self.session = nil
        guard self.waiting?.id == attempt.id else { return }
        if self.handedOff { return }
        self.waiting = nil
        if let url {
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value
            if state == "denied" {
                await model.cancelSignIn(attempt)
            } else {
                await model.load()
            }
        } else if let error {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                self.error = error.localizedDescription
            }
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
            self.waiting = nil
            self.session?.cancel()
            self.session = nil
            await model.cancelSignIn(attempt)
        } else if let attempt = self.simulated {
            self.simulated = nil
            await model.cancelSignIn(attempt)
        }
    }

    func allowSimulated(model: MCPServersModel) async {
        guard let attempt = self.simulated else { return }
        self.simulated = nil
        if !(await model.completeSignIn(attempt, code: "demo", callbackURL: nil)) {
            self.error = model.operation(for: attempt.server).error ?? L("Sign-in didn't finish.")
        }
    }

    /// Drops the waiting state once the Gateway reports the server's sign-in finished.
    func reconcile(_ name: String, state: MCPAuthState?) {
        guard let attempt = self.waiting, attempt.server == name, self.handedOff || self.session == nil else { return }
        if state == .authorized { self.waiting = nil }
    }
}

/// Anchors the web session to the frontmost window.
private final class MCPWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// The demo's stand-in for a provider's consent page.
struct MCPSimulatedConsentSheet: View {
    let attempt: MCPOAuthAttempt
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "person.badge.key").font(.system(size: 40)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Allow Pincer to use \(self.attempt.server)?", bundle: .module).font(.headline)
                Text("This is a simulated sign-in for the demo. No account is used.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(L("Deny"), role: .cancel, action: self.deny)
                    Button(L("Allow"), action: self.allow).buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L("Sign In"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}

extension View {
    /// Presents the demo consent sheet and sign-in errors for `flow`.
    func mcpSignIn(_ flow: MCPSignInFlow, model: MCPServersModel) -> some View {
        self
            .sheet(item: Binding(get: { flow.simulated }, set: { if $0 == nil { flow.simulated = nil } })) { attempt in
                MCPSimulatedConsentSheet(
                    attempt: attempt,
                    allow: { Task { await flow.allowSimulated(model: model) } },
                    deny: { Task { await flow.cancel(model: model) } })
            }
            .alert(L("Couldn't Sign In"), isPresented: Binding(get: { flow.error != nil }, set: { if !$0 { flow.error = nil } })) {
                Button(L("OK"), role: .cancel) { flow.error = nil }
            } message: {
                Text(flow.error ?? "")
            }
    }
}
