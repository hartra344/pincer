import Foundation
import Observation

/// Fixed-size scalar draft. Only released settings snapshots enter the two-slot write queue.
@MainActor @Observable
package final class VoiceSettingsDraft {
    package struct Submission: Sendable {
        package let value: TTSVoiceSettings
        package let revision: UInt64
        fileprivate let token = UUID()
    }
    package private(set) var value: TTSVoiceSettings
    package private(set) var baseline: TTSVoiceSettings
    package private(set) var revision: UInt64 = 0
    private var cleanRevision: UInt64 = 0
    private var active: Submission?
    private var pending: Submission?
    package init(initial: TTSVoiceSettings = .elevenLabsDefault) {
        self.value = initial
        self.baseline = initial
    }
    package var activeCount: Int { self.active == nil ? 0 : 1 }
    package var pendingCount: Int { self.pending == nil ? 0 : 1 }
    package var pendingRevision: UInt64? { self.pending?.revision }
    package func edit(_ value: TTSVoiceSettings) { self.revision &+= 1; self.value = value }
    package func updateSnapshot(_ saved: TTSVoiceSettings) {
        self.baseline = saved
        if self.revision == self.cleanRevision { self.value = saved }
    }
    package func commit() -> Submission? {
        let submission = Submission(value: self.value, revision: self.revision)
        if self.active != nil { self.pending = submission; return nil }
        guard submission.value != self.baseline else { self.cleanRevision = self.revision; return nil }
        self.active = submission
        return submission
    }
    package func complete(_ submission: Submission, acknowledged: TTSVoiceSettings?) -> Submission? {
        guard self.active?.token == submission.token else { return nil }
        if let acknowledged {
            self.baseline = acknowledged
            if self.revision == submission.revision {
                self.value = acknowledged
                self.cleanRevision = self.revision
            }
        }
        self.active = nil
        guard let pending = self.pending else { return nil }
        self.pending = nil
        // A failed write may already have persisted. Only an authoritative successful
        // acknowledgement proves that the released pending value is a no-op.
        guard acknowledged == nil || pending.value != self.baseline else {
            if self.revision == pending.revision { self.cleanRevision = self.revision }
            return nil
        }
        self.active = pending
        return pending
    }
}
