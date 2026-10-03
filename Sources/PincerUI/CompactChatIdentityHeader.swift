import PincerKit
import SwiftUI

#if os(iOS)
/// Compact identity chrome stays outside the selected chat's identity boundary.
/// Only the existing avatar subtree owns an animation clock; transcript chrome does not tick.
struct CompactChatIdentityHeader: View {
    let gateway: GatewayStore
    let key: String
    let row: SessionRow?
    #if DEBUG
    @Environment(\.compactChatHeaderGeometryProbe) private var geometryProbe
    #endif
    static let avatarSize: CGFloat = 64
    static let reservedHeight: CGFloat = 60
    static let navigationOverlap: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var titleLineAllowance: CGFloat = 22
    @State private var measuredTitleHeight: CGFloat = 0

    private var reservedHeight: CGFloat {
        max(Self.reservedHeight, Self.avatarSize + 4 + max(self.measuredTitleHeight, self.titleLineAllowance + 12) - Self.navigationOverlap)
    }

    private var agent: AgentSummary {
        self.gateway.agent(self.row?.agentId ?? SessionKey.agentId(from: self.key) ?? "main")
    }

    var body: some View {
        Color.clear
            .frame(height: self.reservedHeight)
            // The native style fills the actual reserved region and extends through the
            // navigation/status safe area without changing the header's measured height.
            .background(.regularMaterial, ignoresSafeAreaEdges: .top)
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    ChatAgentAvatar(chat: self.gateway.chat(for: self.key), agent: self.agent,
                                    size: Self.avatarSize, announces: true)
                        .id(self.key)
                        .frame(width: Self.avatarSize, height: Self.avatarSize)
                        .accessibilityIdentifier("compact-chat-header-avatar")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            self.geometryProbe?.report(.avatar, $0)
                        }
                        #endif
                    Text(chatTitle(self.gateway, key: self.key, row: self.row))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .glassSurface(in: Capsule())
                        .frame(maxWidth: 240)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("compact-chat-header-title")
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if self.measuredTitleHeight != height { self.measuredTitleHeight = height }
                        }
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            self.geometryProbe?.report(.title, $0)
                        }
                        #endif
                }
                .frame(maxWidth: .infinity)
                .offset(y: -Self.navigationOverlap)
                .allowsHitTesting(false)
            }
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                self.geometryProbe?.report(.reservation, $0)
            }
            #endif
    }
}

struct CompactChatIdentityChrome: ViewModifier {
    let active: Bool
    let gateway: GatewayStore
    let key: String?
    let row: SessionRow?

    @ViewBuilder func body(content: Content) -> some View {
        if self.active, let key {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    CompactChatIdentityHeader(gateway: self.gateway, key: key, row: self.row)
                }
        } else { content }
    }
}
#if DEBUG
struct CompactChatHeaderGeometryProbe {
    enum Part: Hashable, Sendable { case avatar, title, reservation }
    let report: @MainActor @Sendable (Part, CGRect) -> Void
    init(report: @escaping @MainActor @Sendable (Part, CGRect) -> Void) { self.report = report }
}
extension EnvironmentValues {
    @Entry var compactChatHeaderGeometryProbe: CompactChatHeaderGeometryProbe? = nil
}
#endif
#if DEBUG
struct ChatTopChromeGeometryProbe {
    enum Part: Hashable, Sendable { case approvals, find }
    let report: @MainActor @Sendable (Part, CGRect) -> Void
    init(report: @escaping @MainActor @Sendable (Part, CGRect) -> Void) { self.report = report }
}
extension EnvironmentValues {
    @Entry var chatTopChromeGeometryProbe: ChatTopChromeGeometryProbe? = nil
}
#endif
#endif
