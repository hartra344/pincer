import PincerKit
import SwiftUI

#if os(iOS)
/// Compact identity chrome stays outside the selected chat's identity boundary.
/// Only the existing avatar subtree owns an animation clock; transcript chrome does not tick.
struct CompactChatIdentityHeader: View {
    let gateway: GatewayStore
    let key: String
    let row: SessionRow?
    @AppStorage(ChatHeaderAvatarSize.defaultsKey) private var avatarSizePreference = ChatHeaderAvatarSize.small.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    #if DEBUG
    @Environment(\.compactChatHeaderGeometryProbe) private var geometryProbe
    #endif
    static let avatarSize: CGFloat = CGFloat(CompactChatHeaderLayout.avatarSize)
    static let reservedHeight: CGFloat = CGFloat(CompactChatHeaderLayout.minimumReservation)
    static let navigationOverlap: CGFloat = CGFloat(CompactChatHeaderLayout.navigationOverlap)
    @ScaledMetric(relativeTo: .headline) private var titleLineAllowance: CGFloat = 22
    @State private var measuredTitleHeight: CGFloat = 0
    private var selectedSize: ChatHeaderAvatarSize { ChatHeaderAvatarSize(normalizing: self.avatarSizePreference) }
    private var selectedAvatarSize: CGFloat { CGFloat(self.selectedSize.avatarSize) }

    private var reservedHeight: CGFloat {
        CGFloat(CompactChatHeaderLayout.reservation(measuredTitleHeight: Double(self.measuredTitleHeight),
                                                   scaledTitleAllowance: Double(self.titleLineAllowance), size: self.selectedSize))
    }

    private var agent: AgentSummary {
        self.gateway.agent(self.row?.agentId ?? SessionKey.agentId(from: self.key) ?? "main")
    }

    var body: some View {
        Color.clear
            .frame(height: self.reservedHeight)
            .background {
                switch CompactChatHeaderLayout.backdrop(reduceTransparency: self.reduceTransparency) {
                case .opaque:
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea(.container, edges: .top)
                case .graduatedMaterial:
                    CompactChatGraduatedBackdrop(wash: self.theme.color(.chatBackground), dark: self.colorScheme == .dark,
                                                 reservation: Double(self.reservedHeight), size: self.selectedSize)
                        .padding(.bottom, -CGFloat(CompactChatHeaderLayout.fadeExtension))
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    ChatAgentAvatar(chat: self.gateway.chat(for: self.key), agent: self.agent,
                                    size: self.selectedAvatarSize, announces: true)
                        .id(self.key)
                        .frame(width: self.selectedAvatarSize, height: self.selectedAvatarSize)
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

/// Static layers only (see `CompactChatHeaderLayout`): two backdrop materials and a chat-background
/// wash, each under its own eased ramp. Nothing depends on scroll offset, so scrolling costs the two
/// materials' backdrop passes and nothing is recomputed per frame (#1097).
private struct CompactChatGraduatedBackdrop: View {
    typealias Layout = CompactChatHeaderLayout
    let wash: Color
    let dark: Bool
    let reservation: Double
    let size: ChatHeaderAvatarSize
    private static let stops = Layout.defaultFadeStops

    private static func material(_ kind: Layout.FadeMaterial) -> Material {
        switch kind {
        case .ultraThin: .ultraThinMaterial
        case .regular: .regularMaterial
        }
    }

    /// Full above the ramp, eased across it, clear below it down to the backdrop's bottom edge.
    private func ramp(_ ramp: Layout.FadeRamp, color: Color) -> some View {
        let depth = Layout.backdropDepth(reservation: self.reservation)
        return VStack(spacing: 0) {
            color
            LinearGradient(stops: Self.stops.map { .init(color: color.opacity($0.opacity), location: $0.location) },
                           startPoint: .top, endPoint: .bottom)
                .frame(height: CGFloat(max(0, ramp.length)))
            Color.clear.frame(height: CGFloat(max(0, depth - ramp.end)))
        }
    }

    var body: some View {
        ZStack {
            ZStack {
                Rectangle().fill(Self.material(Layout.fadeMaterial))
                self.wash.opacity(Layout.fadeMaterialWashOpacity)
            }
            .mask { self.ramp(Layout.blurRamp(reservation: self.reservation), color: .black) }
            ZStack {
                Rectangle().fill(Self.material(Layout.progressiveMaterial))
                self.wash.opacity(Layout.progressiveWashOpacity)
            }
            .mask { self.ramp(Layout.progressiveRamp, color: .black) }
            self.ramp(Layout.washRamp(size: self.size), color: self.wash.opacity(Layout.washOpacity(dark: self.dark)))
        }
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
