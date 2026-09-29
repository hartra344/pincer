import Foundation

/// A chat opened in a window of its own (#48). Codable so macOS restores the window on relaunch.
public struct ChatWindowRef: Codable, Hashable, Sendable {
    public let gatewayId: UUID
    public let sessionKey: String

    public init(gatewayId: UUID, sessionKey: String) {
        self.gatewayId = gatewayId
        self.sessionKey = sessionKey
    }

    var target: Notifier.Target { Notifier.Target(gatewayId: self.gatewayId, sessionKey: self.sessionKey) }
}

extension AppModel {
    /// A chat window appeared: its chat stays loaded and live, and isn't notified while the app is active.
    public func chatWindowOpened(_ ref: ChatWindowRef) {
        guard let gateway = self.gateways.first(where: { $0.id == ref.gatewayId }) else { return }
        self.windowRefCounts[ref, default: 0] += 1
        self.notifier.windowVisible.insert(ref.target)
        self.notifier.clear(target: ref.target)
        gateway.chatWindowOpened(ref.sessionKey)
    }

    public func chatWindowClosed(_ ref: ChatWindowRef) {
        guard let count = self.windowRefCounts[ref] else { return }
        if count > 1 {
            self.windowRefCounts[ref] = count - 1
        } else {
            self.windowRefCounts[ref] = nil
            self.notifier.windowVisible.remove(ref.target)
        }
        self.gateways.first { $0.id == ref.gatewayId }?.chatWindowClosed(ref.sessionKey)
    }
}
