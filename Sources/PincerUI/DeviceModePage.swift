import PincerKit
import SwiftUI

/// Gateway Settings → This Device: opt-in device mode. Off by default; turning it on opens a second
/// connection in the `node` role that declares only the data the user checks here.
struct DeviceModePage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var denied: Set<DeviceCapability> = []
    @State private var requesting: Set<DeviceCapability> = []

    private var controller: DeviceNodeController { self.gateway.deviceNode }

    var body: some View {
        let controller = self.controller
        let settings = controller.settings
        List {
            Section {
                Text("Pincer is a client by default. Turn on device mode to let this Gateway's agents ask this device for the data you choose. It can never run commands, take photos, record the screen, or read files.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { controller.settings.enabled },
                    set: { value in self.update { $0.enabled = value } })) {
                    Text("Share data from this device", bundle: .module)
                }
            }
            if settings.enabled {
                Section {
                    ForEach(Self.supported) { cap in self.row(cap, settings: settings) }
                } header: {
                    Text("Data to share", bundle: .module)
                }
                Section {
                    LabeledContent(L("Status")) {
                        Label(Self.statusText(controller.status), systemImage: Self.statusSymbol(controller.status))
                            .foregroundStyle(Self.statusTint(controller.status))
                    }
                    if let last = controller.lastInvoke {
                        LabeledContent(L("Last request")) {
                            Text(verbatim: [last.command, last.ok ? L("answered") : L("failed"),
                                           last.at.formatted(.relative(presentation: .named))].joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let hint = controller.removalHint {
                Section {
                    Label(hint, systemImage: "info.circle").font(.callout)
                }
            }
            Section {} footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requests are answered only while Pincer is connected. Pincer never declares camera, screen, shell, files or notification commands.", bundle: .module)
                    Text("A remote Gateway may ask you to approve twice: once to pair this device, and again when the data list changes. Granting an OS permission later also triggers a new approval.", bundle: .module)
                }
            }
        }
        .navigationTitle(L("This Device"))
    }

    private func row(_ cap: DeviceCapability, settings: DeviceModeSettings) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { settings.capabilities.contains(cap) },
                set: { value in self.toggle(cap, on: value) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(cap))
                    Text(Self.detail(cap)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(self.requesting.contains(cap))
            if self.denied.contains(cap) {
                Text("Allow access in System Settings", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func update(_ change: (inout DeviceModeSettings) -> Void) {
        var next = self.controller.settings
        change(&next)
        let controller = self.controller
        Task { await controller.update(next) }
    }

    private func toggle(_ cap: DeviceCapability, on: Bool) {
        guard on else {
            self.denied.remove(cap)
            self.update { $0.capabilities.remove(cap) }
            return
        }
        guard let handler = DeviceNodeController.platformHandler else {
            self.update { $0.capabilities.insert(cap) }
            return
        }
        self.requesting.insert(cap)
        Task {
            let granted = await handler.requestAccess(for: cap)
            self.requesting.remove(cap)
            if granted {
                self.denied.remove(cap)
                self.update { $0.capabilities.insert(cap) }
            } else {
                self.denied.insert(cap)
            }
        }
    }

    /// Only what this platform can answer (Motion & fitness is iOS-only).
    static var supported: [DeviceCapability] { DeviceCapability.allCases.filter(\.isSupported) }

    static func title(_ cap: DeviceCapability) -> String {
        switch cap {
        case .location: L("Location")
        case .device: L("Device info")
        case .calendar: L("Calendar")
        case .contacts: L("Contacts")
        case .reminders: L("Reminders")
        case .motion: L("Motion & fitness")
        }
    }

    static func detail(_ cap: DeviceCapability) -> String {
        switch cap {
        case .location: L("Current location, only while Pincer is open")
        case .device: L("Model, OS version, battery, thermal and network state")
        case .calendar: L("Read upcoming events")
        case .contacts: L("Search contacts by name")
        case .reminders: L("Read your reminders")
        case .motion: L("Activity and step counts")
        }
    }

    static func statusText(_ status: DeviceNodeController.Status) -> String {
        switch status {
        case .off: L("Off")
        case .connecting: L("Connecting")
        case let .awaitingPairing(requestId):
            requestId.map { L("Approve this device on the Gateway (pairing) (\($0))") } ?? L("Approve this device on the Gateway (pairing)")
        case let .awaitingApproval(requestId):
            requestId.map { L("Approve the new data list on the Gateway (\($0))") } ?? L("Approve the new data list on the Gateway")
        case .paused: L("Paused while Pincer is in the background")
        case .active: L("Active — answering requests while Pincer is open")
        case let .failed(message): L("Failed: \(message)")
        }
    }

    static func statusSymbol(_ status: DeviceNodeController.Status) -> String {
        switch status {
        case .off: "poweroff"
        case .paused: "pause.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .awaitingPairing, .awaitingApproval: "hourglass"
        case .active: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func statusTint(_ status: DeviceNodeController.Status) -> Color {
        switch status {
        case .active: .green
        case .failed: .red
        case .awaitingPairing, .awaitingApproval: .orange
        default: .secondary
        }
    }
}
