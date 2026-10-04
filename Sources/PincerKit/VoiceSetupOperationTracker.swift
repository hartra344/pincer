import Observation

@MainActor @Observable
package final class VoiceSetupOperationTracker {
    package private(set) var activeCount = 0
    private var latest: UInt64 = 0
    package init() {}
    package var busy: Bool { self.activeCount > 0 }
    package func begin() -> UInt64 {
        self.latest &+= 1
        self.activeCount += 1
        return self.latest
    }
    package func finish(_ token: UInt64) -> Bool {
        self.activeCount = max(0, self.activeCount - 1)
        return token == self.latest
    }
}
