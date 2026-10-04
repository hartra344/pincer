import Foundation
import Observation

/// Local editor intent is independent of acknowledgement of the last submitted file.
@MainActor @Observable
package final class RawConfigEditorDraft {
    package private(set) var text = ""
    package private(set) var baseline: String?
    package private(set) var revision: UInt64 = 0
    package private(set) var validationError: String?
    package private(set) var validationPending = false
    package private(set) var isEdited = false
    package private(set) var savePending = false
    @ObservationIgnored private var baselineRevision: UInt64 = 0
    // A clean revision is authority only for the baseline its worker compared against.
    @ObservationIgnored private var cleanBaselineVersion: UInt64 = 0
    @ObservationIgnored private var baselineVersion: UInt64 = 0
    @ObservationIgnored private var admittedRevision: UInt64?
    @ObservationIgnored private var active: Task<Void, Never>?
    private struct ValidationInput: Sendable {
        let revision: UInt64
        let baselineVersion: UInt64
        let text: String
        let baseline: String?
    }
    @ObservationIgnored private var pending: ValidationInput?
    @ObservationIgnored package var validationObserver: (@Sendable () -> Void)?
    package init() {}

    package func edit(_ text: String) {
        self.revision &+= 1
        self.text = text
        self.isEdited = true
        self.validateLatest()
    }
    package func revert() {
        guard let baseline else { return }
        self.edit(baseline)
        if !self.savePending {
            self.isEdited = false
            self.baselineRevision = self.revision
            self.cleanBaselineVersion = self.baselineVersion
            self.validationPending = false
            self.pending = nil
        }
    }
    package func updateSnapshot(_ raw: String) {
        let mayInstall = (self.baseline == nil && self.revision == 0)
            || (self.baseline != nil && (self.revision == self.admittedRevision
                || (self.admittedRevision == nil && self.revision == self.baselineRevision
                    && self.cleanBaselineVersion == self.baselineVersion)))
        self.baseline = raw
        self.baselineVersion &+= 1
        if mayInstall { self.install(raw) }
        else { self.validateLatest() }
    }
    package func beginSave() -> UInt64? {
        guard self.isEdited, !self.validationPending, self.validationError == nil, !self.savePending else { return nil }
        self.savePending = true
        self.admittedRevision = self.revision
        return self.revision
    }
    package func finishSave(admission: UInt64, acknowledgedRaw: String?) {
        guard self.admittedRevision == admission else { return }
        if let acknowledgedRaw {
            self.baseline = acknowledgedRaw
            self.baselineVersion &+= 1
            if self.revision == admission { self.install(acknowledgedRaw) }
            else { self.validateLatest() }
        }
        self.admittedRevision = nil
        self.savePending = false
    }
    private func validateLatest() {
        self.validationPending = true
        self.validationError = nil
        self.pending = ValidationInput(revision: self.revision, baselineVersion: self.baselineVersion,
                                       text: self.text, baseline: self.baseline)
        self.startValidation()
    }
    private func install(_ raw: String) {
        self.text = raw
        self.baselineRevision = self.revision
        self.cleanBaselineVersion = self.baselineVersion
        self.isEdited = false
        self.validationPending = false
        self.validationError = nil
        self.pending = nil
    }
    private func startValidation() {
        guard self.active == nil, let input = self.pending else { return }
        self.pending = nil
        let observer = self.validationObserver
        self.active = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                (Self.parseError(input.text, observer: observer), input.baseline.map { input.text == $0 } ?? false)
            }.value
            guard let self else { return }
            self.active = nil
            if self.revision == input.revision && self.baselineVersion == input.baselineVersion && self.validationPending {
                self.validationError = result.0
                self.isEdited = !result.1
                if result.1 {
                    self.baselineRevision = self.revision
                    self.cleanBaselineVersion = input.baselineVersion
                }
                self.validationPending = false
            }
            self.startValidation()
        }
    }
    package func waitForValidation() async {
        while let active = self.active { await active.value }
    }
    package nonisolated static func parseError(_ text: String, observer: (@Sendable () -> Void)? = nil) -> String? {
        observer?()
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed, .fragmentsAllowed])
            return nil
        } catch {
            let description = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return "Not valid JSON5\(description.map { ": \($0)" } ?? ".")"
        }
    }
}
