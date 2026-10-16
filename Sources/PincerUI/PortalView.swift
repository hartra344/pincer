import PincerKit
import SwiftUI

/// One portal: a URL row (current address without the token, Reload, Open in Browser, ⋯), banners, then
/// the origin-locked web view.
struct PortalView: View {
    let portal: PortalSummary
    let cache: PortalWebCache
    /// False while the panel is still sliding in: the first web view waits for it.
    let canLoad: Bool
    let onClose: () -> Void
    @Environment(GatewayStore.self) private var gateway
    @State private var confirmsOpen = false
    @State private var dismissedLoopbackNotice = false

    var body: some View {
        if self.portal.isRedacted {
            ContentUnavailableView(L("This connection can't open portals"), systemImage: "lock.shield",
                                   description: Text("Pincer was connected without permission to open links. Reconnect this Gateway to fix it.", bundle: .module))
        } else {
            let session = self.cache.session(for: self.portal, pin: self.pin, servesDemoPortal: self.gateway.profile.isDemo)
            VStack(spacing: 0) {
                PortalToolbarRow(portal: self.portal, state: session.state, session: session,
                                 confirmsOpen: self.$confirmsOpen, onClose: self.onClose)
                Divider()
                if self.showsLoopbackNotice, !self.dismissedLoopbackNotice {
                    PortalBanner(symbol: "info.circle", dismiss: { self.dismissedLoopbackNotice = true }) {
                        Text("This portal only listens on the gateway's machine, so it may not load here.", bundle: .module)
                    }
                }
                if let blocked = session.state.blocked {
                    PortalBanner(symbol: "arrow.up.forward.app", dismiss: { session.state.blocked = nil }) {
                        Text(L("Blocked a page outside the portal: \(blocked.host)"))
                        if let url = blocked.openURL {
                            Button(L("Open in Browser")) { PortalOpener.open(url) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                PortalWebArea(portal: self.portal, session: session, canLoad: self.canLoad)
            }
            .confirmationDialog(L("Open in your browser?"), isPresented: self.$confirmsOpen, titleVisibility: .visible) {
                Button(L("Open")) {
                    if let url = self.portal.loadURL { PortalOpener.open(url) }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text("This sends the portal's access link to your browser. Anyone with the link can use it until the portal closes.", bundle: .module)
            }
        }
    }

    private var showsLoopbackNotice: Bool {
        guard self.portal.exposure?.isLoopbackOnly == true else { return false }
        let host = URL(string: self.gateway.profile.url)?.host(percentEncoded: false)?.lowercased() ?? ""
        return !(host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127."))
    }

    /// The gateway's certificate pin applies only to a portal served from the gateway's own host.
    private var pin: (host: String, fingerprint: String)? {
        let profile = self.gateway.profile
        guard let host = URL(string: profile.url)?.host(percentEncoded: false)?.lowercased(),
              let fingerprint = profile.tlsFingerprint, !fingerprint.isEmpty,
              self.portal.publicURL.host(percentEncoded: false)?.lowercased() == host else { return nil }
        return (host, fingerprint)
    }
}

/// A compact secondary line above the page: info, then optional actions, then a dismiss button.
struct PortalBanner<Content: View>: View {
    let symbol: String
    let dismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: self.symbol).accessibilityHidden(true)
            self.content
            Spacer(minLength: 0)
            Button(L("Dismiss"), systemImage: "xmark", action: self.dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .contain)
    }
}

private struct PortalToolbarRow: View {
    let portal: PortalSummary
    let state: PortalWebState
    let session: PortalWebSession
    @Binding var confirmsOpen: Bool
    let onClose: () -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { self.sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    private var address: URL { self.state.currentURL ?? self.portal.displayURL }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
            let shown = self.isCompact ? (self.address.host(percentEncoded: false) ?? self.address.absoluteString) : self.address.absoluteString
            Text(shown)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L("Portal address"))
                .accessibilityValue(self.address.absoluteString)
            Button(L("Reload"), systemImage: "arrow.clockwise") { self.session.reload() }
                .help(L("Reload"))
            if !self.isCompact {
                Button(L("Open in Browser"), systemImage: "arrow.up.forward.square") { self.confirmsOpen = true }
                    .help(L("Open in Browser"))
            }
            Menu {
                if self.isCompact {
                    Button(L("Open in Browser"), systemImage: "arrow.up.forward.square") { self.confirmsOpen = true }
                }
                Button(L("Copy Link (without access)"), systemImage: "doc.on.doc") { Clipboard.copy(self.address.absoluteString) }
                Divider()
                Button(L("Close Portal"), systemImage: "xmark.circle", role: .destructive) { self.onClose() }
                    .accessibilityLabel(L("Close portal \(self.portal.title)"))
            } label: {
                Label(L("More"), systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

extension View {
    /// `Close "<title>"?` for the tab ✕, the tab's context menu and the ⋯ menu.
    func portalCloseConfirmation(title: String, isPresented: Binding<Bool>, onClose: @escaping () -> Void) -> some View {
        self.confirmationDialog(L("Close \"\(title)\"?"), isPresented: isPresented, titleVisibility: .visible) {
            Button(L("Close Portal"), role: .destructive, action: onClose)
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("The link stops working for everyone. The agent can open a new portal if needed.", bundle: .module)
        }
    }
}

/// The web view with its progress bar, and the failed state. Reads only the session's state.
private struct PortalWebArea: View {
    let portal: PortalSummary
    let session: PortalWebSession
    let canLoad: Bool

    var body: some View {
        let state = self.session.state
        ZStack(alignment: .top) {
            if state.isReady, let webView = self.session.webView {
                PortalWebViewHost(webView: webView)
                    .opacity(state.failure == nil ? 1 : 0)
                    .accessibilityLabel(L("\(self.portal.title) portal"))
            }
            if let failure = state.failure {
                ContentUnavailableView {
                    Label(L("Can't load this portal"), systemImage: "exclamationmark.triangle")
                } description: {
                    switch failure {
                    case .expired: Text("This portal link has expired or closed.", bundle: .module)
                    case let .message(text): Text(text.isEmpty ? L("The page didn't respond.") : text)
                    }
                } actions: {
                    if failure != .expired { Button(L("Try Again")) { self.session.reload(force: true) } }
                }
            } else if state.isLoading {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: self.canLoad) { if self.canLoad { self.session.loadIfNeeded() } }
    }
}

enum PortalOpener {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
