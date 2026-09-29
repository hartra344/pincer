import os

/// Instruments transcript layout work for Instruments' os_signpost track.
enum TranscriptSignposts {
    static let signposter = OSSignposter(subsystem: "app.pincer", category: "Transcript")

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = self.signposter.beginInterval(name)
        defer { self.signposter.endInterval(name, state) }
        return body()
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        self.signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        self.signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        self.signposter.emitEvent(name)
    }
}
