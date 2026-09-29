import PincerKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings → Notifications. On iOS, "While Pincer is closed" chooses between a push relay,
/// background refresh (no server, delayed) and nothing.
struct NotificationSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var notifications = true
    @State private var delivery = ClosedAppDelivery.current()
    @State private var refreshTick = 0
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PushRegistrar.relayKey) private var pushRelay = ""

    var body: some View {
        SwiftUI.Section {
            Toggle("Notify about replies and approvals", isOn: self.$notifications)
                .onChange(of: self.notifications) { _, value in
                    self.app.notifier.enabled = value
                    self.app.syncPush()
                }
            #if os(iOS)
            Group {
                Picker("While Pincer is closed", selection: self.$delivery) {
                    ForEach(ClosedAppDelivery.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: self.delivery) { _, value in
                    ClosedAppDelivery.set(value)
                    self.app.syncPush()
                }
                if self.delivery == .pushRelay {
                    TextField("Push relay", text: self.$pushRelay, prompt: Text("https://relay.example.com"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { self.app.syncPush() }
                    ForEach(self.app.gateways.filter { !$0.profile.isDemo }) { gateway in
                        LabeledContent(gateway.profile.name, value: self.pushStatus(gateway))
                    }
                }
                if self.delivery == .backgroundRefresh {
                    let _ = self.refreshTick
                let lastRun = UserDefaults.standard.object(forKey: "pincer.refresh.lastRun") as? Date
                    let lastResult = UserDefaults.standard.string(forKey: "pincer.refresh.lastResult") ?? ""
                    LabeledContent("Last checked") {
                        if let lastRun {
                            let when = lastRun.formatted(.relative(presentation: .named))
                            Text(lastResult.isEmpty ? when : "\(when) · \(lastResult)")
                        } else {
                            Text("Not yet")
                        }
                    }
                    switch UIApplication.shared.backgroundRefreshStatus {
                case .denied:
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Background App Refresh is off for Pincer", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                case .restricted:
                    Label("Background App Refresh is restricted on this device", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            }
            }
            .disabled(!self.notifications)
            #endif
        } header: {
            Text("Notifications")
        } footer: {
            #if os(iOS)
            Text(self.footer)
            #endif
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase == .active { self.refreshTick += 1 }
        }
        .onAppear {
            self.notifications = self.app.notifier.enabled
            self.delivery = ClosedAppDelivery.current()
        }
    }

    #if os(iOS)
    private var footer: String {
        switch self.delivery {
        case .pushRelay:
            "To get notified while Pincer is closed, enter a Pincer push relay. Your Gateway encrypts each notification to this device, so the relay can't read it. The Gateway needs Web Push (push.web.subscribe)."
        case .backgroundRefresh:
            "Pincer checks your Gateways in the background, with no server needed. iOS decides when, usually 15 minutes to a few hours apart, depending on how often you use Pincer and your battery. It pauses in Low Power Mode, and stops after you swipe Pincer away in the app switcher until you open it again."
        case .off:
            "You're notified only while Pincer is open."
        }
    }

    private func pushStatus(_ gateway: GatewayStore) -> String {
        if !self.pushRelay.isEmpty, PushRegistrar.validRelay(self.pushRelay) == nil { return "Relay must be https://" }
        if self.app.push.deviceToken == nil, !self.pushRelay.isEmpty { return "Waiting for APNs" }
        switch self.app.push.status[gateway.id] {
        case .active: return "Push on"
        case .unsupported: return "Gateway has no Web Push"
        case let .failed(message): return message
        case .off, nil: return gateway.state.isConnected ? "Push off" : "Not connected"
        }
    }
    #endif
}
