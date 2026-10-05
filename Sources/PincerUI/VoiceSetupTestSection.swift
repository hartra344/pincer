import PincerKit
import SwiftUI

/// Sections 6 and 7: Test Voice with its result line, and the read-only "What the Gateway Will Use" view.
struct VoiceSetupTestSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    @State private var result: TTSTestResult?
    @State private var testing = false

    private var playing: Bool { self.setup.playingId == VoiceSetupController.testId }

    var body: some View {
        Section {
            Button(action: self.tap) {
                if self.testing {
                    HStack { ProgressView().controlSize(.small); Text("Testing…", bundle: .module) }
                } else if self.playing {
                    Text("Stop", bundle: .module)
                } else {
                    Text("Test Voice", bundle: .module).fontWeight(.semibold)
                }
            }
            .disabled(self.testing || !self.model.canWrite)
            if !self.model.canWrite {
                Text("Testing needs write access.", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
            if let result { self.line(result) }
        } header: {
            Text("Test Voice", bundle: .module)
        } footer: {
            Text("Speaks a short sentence through the Gateway and plays it here. If the chosen voice fails, the Gateway may use another provider; the result says so.", bundle: .module)
        }
        .onChange(of: self.model.status?.provider) { _, _ in self.result = nil }
        .onChange(of: self.model.setups) { _, _ in self.result = nil }
        VoiceSetupEffectiveSection(model: self.model)
    }

    private func tap() {
        if self.playing { self.setup.stop(); return }
        self.testing = true
        self.setup.startTestVoice(model: self.model, sample: L("Hi, this is your Gateway voice."), finished: { self.testing = false }) { outcome in
            self.result = outcome
            AccessibilityNotification.Announcement(self.announcement(outcome)).post()
        }
    }

    private func announcement(_ result: TTSTestResult) -> String {
        switch result.outcome {
        case .success: String(format: L("Success: %@"), result.summary)
        case let .failed(message): String(format: L("Failed: %@"), message)
        case let .fellBack(to, reason): String(format: L("Spoke with %@ instead: %@"), to, reason.message)
        }
    }

    @ViewBuilder private func line(_ result: TTSTestResult) -> some View {
        switch result.outcome {
        case .success:
            Label(result.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            let name = result.provider ?? self.model.displayName(for: self.model.status?.provider ?? "")
            Label(String(format: L("%@ couldn't speak: %@"), name, message), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).lineLimit(2).help(message)
        case let .fellBack(to, reason):
            let selected = self.model.displayName(for: self.model.status?.provider ?? "")
            Label(String(format: L("Spoke with %@ instead of %@: %@"), to, selected, reason.message(provider: selected)), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// "What the Gateway Will Use": the effective values, where each comes from, and the raw config key.
struct VoiceSetupEffectiveSection: View {
    let model: GatewayVoiceModel

    static var detailAlignment: HorizontalAlignment {
        #if os(iOS)
        .leading
        #else
        .trailing
        #endif
    }

    var body: some View {
        let rows = self.model.effectiveConfig
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    VoiceStackedRow(title: row.label) {
                        VStack(alignment: Self.detailAlignment, spacing: 2) {
                            Text(row.value)
                            if let note = row.overrideNote {
                                Label(note, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Text(self.caption(row)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("What the Gateway Will Use", bundle: .module)
            }
        }
    }

    private func caption(_ row: TTSEffectiveRow) -> String {
        row.keyPath.map { "\(row.source) · \($0)" } ?? row.source
    }
}
