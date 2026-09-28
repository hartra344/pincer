import PincerKit
import SwiftUI

/// The one-time tips card over the main window. Waits for the setup wizard, never covers it.
struct TipsOverlay: ViewModifier {
    @Environment(AppModel.self) private var app
    private var tips: TipsModel { TipsModel.shared }

    func body(content: Content) -> some View {
        let gateway = self.app.selectedGateway
        let connected = gateway?.hasConnected == true && gateway?.state.isConnected == true
        let setupBlocking = (gateway?.setup.isShowingOrPending ?? true) || self.app.firstRun.presentation != nil
        content
            .overlay(alignment: .bottomTrailing) {
                if self.tips.isPresented {
                    TipsCard { self.tips.dismiss() }
                        .padding(20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: self.tips.isPresented)
            .onChange(of: TipsTrigger(gatewayId: gateway?.id, connected: connected, setupBlocking: setupBlocking,
                                      seen: self.tips.hasSeen), initial: true) { _, trigger in
                self.tips.evaluate(connected: trigger.connected, setupShowingOrPending: trigger.setupBlocking,
                                   isDemo: gateway?.profile.isDemo == true)
            }
    }
}

private struct TipsTrigger: Equatable {
    let gatewayId: UUID?
    let connected: Bool
    let setupBlocking: Bool
    let seen: Bool
}

private struct TipsCard: View {
    let dismiss: () -> Void

    private var tips: [(tip: SetupTips.Tip, text: String)] {
        #if os(iOS)
        SetupTips.tips(iOS: true, iPhone: UIDevice.current.userInterfaceIdiom == .phone)
        #else
        SetupTips.tips(iOS: false)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Spacer()
                // No default-action shortcut: Return belongs to the composer underneath.
                Button(L("Got It"), action: self.dismiss)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
