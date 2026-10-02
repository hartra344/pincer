import PincerKit
import SwiftUI

/// The one-time tips presentation. Waits for the setup wizard, never covers it.
struct TipsOverlay: ViewModifier {
    @Environment(AppModel.self) private var app
    private var tips: TipsModel { TipsModel.shared }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { self.sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    func body(content: Content) -> some View {
        let gateway = self.app.selectedGateway
        let connected = gateway?.hasConnected == true && gateway?.state.isConnected == true
        let setupBlocking = (gateway?.setup.isShowingOrPending ?? true) || self.app.firstRun.presentation != nil
        let prompting = NotificationPrompt.shared.isShowing
        content
            .modifier(TipsPresentation(tips: self.tips, isCompact: self.isCompact))
            .onChange(of: TipsTrigger(gatewayId: gateway?.id, connected: connected, setupBlocking: setupBlocking,
                                      prompting: prompting, seen: self.tips.hasSeen), initial: true) { _, trigger in
                self.tips.evaluate(connected: trigger.connected, setupShowingOrPending: trigger.setupBlocking,
                                   isDemo: gateway?.profile.isDemo == true, permissionPromptShowing: trigger.prompting)
            }
    }
}

/// Presents the noncompact card; iPhone keeps its card in the sidebar.
struct TipsPresentation: ViewModifier {
    let tips: TipsModel
    let isCompact: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { self.tips.isPresented && !self.isCompact },
                set: { presented in
                    if !presented, !self.isCompact, self.tips.isPresented { self.tips.dismiss() }
                }
            )) {
                TipsCard { self.tips.dismiss() }
                    .presentationSizing(.fitted)
            }
    }
}

private struct TipsTrigger: Equatable {
    let gatewayId: UUID?
    let connected: Bool
    let setupBlocking: Bool
    let prompting: Bool
    let seen: Bool
}

private struct TipsCard: View {
    let dismiss: () -> Void

    private var tips: [(tip: SetupTips.Tip, text: String)] {
        #if os(iOS)
        SetupTips.tips(iOS: true, iPhone: UIDevice.current.userInterfaceIdiom == .phone,
                       shortcuts: .shared)
        #else
        SetupTips.tips(iOS: false, shortcuts: .shared)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Label(L("Tips"), systemImage: "lightbulb").font(.headline)
            ForEach(self.tips, id: \.tip.id) { entry in
                Label {
                    Text(entry.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: entry.tip.symbol).foregroundStyle(.tint)
                }
                .font(.callout)
            }
            HStack {
                // A second key equivalent for the same action; native sheets route Escape here.
                Button(L("Got It"), action: self.dismiss)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                Spacer()
                Button(L("Got It"), action: self.dismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

#if os(iOS)
/// iPhone: the tips card in the chat list, above its bottom search bar, one tip at a time (#333).
/// `TipsOverlay` still decides when it shows; in a chat it steps aside so the composer stays clear.
struct CompactTipsHost: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var tips: TipsModel { TipsModel.shared }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if self.sizeClass == .compact, self.tips.isPresented {
                    CompactTipsCard { self.tips.dismiss() }
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.bottom, Theme.Spacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: self.tips.isPresented)
    }
}
#endif

/// iPhone: one tip at a time in a short full-width card, so the chat list stays visible (#333).
private struct CompactTipsCard: View {
    let dismiss: () -> Void
    @State private var index = 0

    private var tips: [(tip: SetupTips.Tip, text: String)] {
        SetupTips.tips(iOS: true, iPhone: true, shortcuts: .shared)
    }

    var body: some View {
        let entry = self.tips[min(self.index, self.tips.count - 1)]
        let isLast = self.index >= self.tips.count - 1
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Label(L("Tips"), systemImage: "lightbulb").font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("\(self.index + 1) of \(self.tips.count)"))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel(L("Tip \(self.index + 1) of \(self.tips.count)"))
            }
            Label {
                Text(entry.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: entry.tip.symbol).foregroundStyle(.tint)
            }
            .font(.callout)
            .id(entry.tip.id)
            .transition(.opacity)
            HStack {
                if isLast {
                    Spacer()
                    Button(L("Got It"), action: self.dismiss).buttonStyle(.borderedProminent)
                } else {
                    Button(L("Got It"), action: self.dismiss)
                    Spacer()
                    Button(L("Next Tip")) { withAnimation(.snappy) { self.index += 1 } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }
}

/// App Settings → General: "Show Tips Again".
struct TipsSettingsSection: View {
    var body: some View {
        Section {
            Button(L("Show Tips Again")) { TipsModel.shared.showAgain() }
                .disabled(!TipsModel.shared.hasSeen)
        } header: {
            Text("Tips", bundle: .module)
        } footer: {
            Text("Shows the tips card again the next time the main window is open.", bundle: .module)
        }
    }
}
