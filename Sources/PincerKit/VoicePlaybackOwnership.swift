import Foundation

/// Playback identity is unique per start, including repeated starts of the same voice.
package struct VoicePlaybackOwnership: Sendable {
    private var current: UUID?
    package init() {}
    package mutating func begin() -> UUID {
        let token = UUID()
        self.current = token
        return token
    }
    package mutating func invalidate() { self.current = nil }
    package func owns(_ token: UUID) -> Bool { self.current == token }
}
