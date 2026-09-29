import PincerKit
import SwiftUI

// MARK: Entry points

/// Routes `pincer://` links and Handoff into `AppModel.open(_:)`, and shows the passing note left
/// when a link can't be followed. Applied once, on the main window's root.
struct DeepLinkRouting: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in self.app.open(url: url) }
            .onContinueUserActivity(PincerRoute.activityType) { activity in
                guard let route = PincerRoute(handoffUserInfo: activity.userInfo) else {
                    self.app.routeNotice = RouteNotice(PincerRoute.Notice.invalidLink)
                    return
                }
                self.app.open(route)
            }
            #if os(macOS)
            // Links and Handoff land in the open main window rather than a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            #endif
            .overlay(alignment: .top) { RouteNoticeBar() }
    }
}

extension View {
    func deepLinkRouting() -> some View { self.modifier(DeepLinkRouting()) }
}

private struct RouteNoticeBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let notice = self.app.routeNotice {
                HStack(spacing: Theme.Spacing.lg) {
                    Label(notice.message, systemImage: "info.circle.fill")
                        .font(.callout)
                    Button {
                        self.app.routeNotice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, Theme.Spacing.row)
                .padding(.trailing, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .glassSurface(in: Capsule())
                .padding(.horizontal, Theme.Spacing.row)
                .padding(.top, Theme.Spacing.lg)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(5))
                    if self.app.routeNotice?.id == notice.id { self.app.routeNotice = nil }
                }
            }
        }
        .animation(.snappy, value: self.app.routeNotice)
    }
}

// MARK: Handoff

/// Advertises the visible chat for Handoff while its Gateway is connected.
struct ChatHandoff: ViewModifier {
    let sessionKey: String
    @Environment(AppModel.self) private var app
    @Environment(GatewayStore.self) private var gateway

    func body(content: Content) -> some View {
        content.userActivity(PincerRoute.activityType, isActive: self.gateway.state.isConnected) { activity in
            let route = self.app.route(for: Notifier.Target(gatewayId: self.gateway.id, sessionKey: self.sessionKey))
            activity.title = self.gateway.sessions[self.sessionKey]?.title ?? "Chat"
            let userInfo = route.handoffUserInfo
            activity.userInfo = userInfo
            activity.requiredUserInfoKeys = Set(userInfo.keys)
            activity.targetContentIdentifier = route.url.absoluteString
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
            activity.needsSave = true
        }
    }
}

// MARK: Copy Link

/// "Copy Link to Chat": a `pincer://` link that opens this chat on any device with the Gateway.
struct CopyChatLinkButton: View {
    let sessionKey: String
    @Environment(AppModel.self) private var app
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        Button("Copy Link to Chat", systemImage: "link") {
            Self.copyLink(app: self.app, gateway: self.gateway, sessionKey: self.sessionKey)
        }
    }

    /// Copies a link to the chat, or to one of its messages (#136), and says so in the chat.
    @MainActor
    static func copyLink(app: AppModel, gateway: GatewayStore, sessionKey: String, messageId: String? = nil) {
        Clipboard.copy(url: self.link(app: app, gateway: gateway, sessionKey: sessionKey, messageId: messageId))
        gateway.chat(for: sessionKey).notice = PincerRoute.Notice.linkCopied
    }

    @MainActor
    static func link(app: AppModel, gateway: GatewayStore, sessionKey: String, messageId: String? = nil) -> URL {
        app.route(for: Notifier.Target(gatewayId: gateway.id, sessionKey: sessionKey), messageId: messageId).url
    }
}

extension Clipboard {
    @MainActor
    static func copy(url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
        AccessibilityAnnouncer.announceCopied()
    }
}

// MARK: Message jump

/// A request for the transcript to scroll to (and flash) a message, e.g. from a link.
struct TranscriptJump: Equatable {
    let id: UUID
    let messageId: String
}
