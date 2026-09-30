import PincerKit
import SwiftUI

/// Sections 6 and 7: Test voice with its result line, and the read-only effective configuration.
struct VoiceSetupTestSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    @State private var result: TTSTestResult?
    @State private var testing = false

    var body: some View {
        Section {
            Button {
                self.testing = true
                Task {
                    let outcome = await self.model.test(sample: L("This is how your Gateway voice sounds."))
                    self.result = outcome
                    self.testing = false
                    if let clip = outcome.clip { self.setup.play(clip) }
                }
            } label: {
                if self.testing {
                    HStack { ProgressView().controlSize(.small); Text("Testing…", bundle: .module) }
                } else {
                    Text("Test Voice", bundle: .module)
                }
            }
            .disabled(self.testing || !self.model.canWrite)
            if let result { self.line(result) }
        } header: {
            Text("Test", bundle: .module)
        } footer: {
            Text("Speaks a short sentence through the Gateway and plays it here. If the chosen voice fails, the Gateway may use another provider; the result says so.", bundle: .module)
        }
        let rows = self.model.effectiveConfig
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    LabeledContent(row.label) {
                        VStack(alignment: .trailing) {
                            Text(row.value)
                            Text(row.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Effective Configuration", bundle: .module)
            } footer: {
                Text("What the Gateway will use right now, and where each value comes from.", bundle: .module)
            }
        }
    }

    @ViewBuilder private func line(_ result: TTSTestResult) -> some View {
        switch result.outcome {
        case .success:
            Label(result.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel(String(format: L("Success: %@"), result.summary))
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .accessibilityLabel(String(format: L("Failed: %@"), message))
        case let .fellBack(to, reason):
            Label(String(format: L("Fell back to %@: %@"), to, reason.message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
