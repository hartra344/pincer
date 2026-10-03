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

struct OwnedChatWindow {
    let ref: ChatWindowRef
    var isVisible: Bool
}

extension AppModel {
    /// Registers residency before the native window's first visibility sample.
    public func chatWindowOpened(_ ref: ChatWindowRef, windowID: UUID) {
        if self.ownedChatWindows[windowID]?.ref == ref { return }
        if let previous = self.ownedChatWindows[windowID] {
            self.chatWindowClosed(previous.ref, windowID: windowID)
        }
        guard self.pinChatWindow(ref) else { return }
        self.ownedChatWindows[windowID] = OwnedChatWindow(ref: ref, isVisible: false)
    }

    public func chatWindowVisibilityChanged(_ ref: ChatWindowRef, windowID: UUID, isVisible: Bool) {
        guard var owner = self.ownedChatWindows[windowID], owner.ref == ref else { return }
        guard let gateway = self.gateways.first(where: { $0.id == ref.gatewayId }),
              !(gateway.state.isConnected && !gateway.sessions.isEmpty && gateway.sessions[ref.sessionKey] == nil) else {
            self.chatWindowClosed(ref, windowID: windowID)
            return
        }
        guard owner.isVisible != isVisible else { return }
        owner.isVisible = isVisible
        self.ownedChatWindows[windowID] = owner
        self.refreshChatWindowVisibility(ref)
        if isVisible { self.notifier.clear(target: ref.target) }
    }

    public func chatWindowClosed(_ ref: ChatWindowRef, windowID: UUID) {
        guard self.ownedChatWindows[windowID]?.ref == ref else { return }
        self.ownedChatWindows[windowID] = nil
        self.unpinChatWindow(ref)
        self.refreshChatWindowVisibility(ref)
    }

    /// Legacy callers report an open window as visible until their matching close.
    public func chatWindowOpened(_ ref: ChatWindowRef) {
        guard self.pinChatWindow(ref) else { return }
        self.legacyWindowRefCounts[ref, default: 0] += 1
        self.refreshChatWindowVisibility(ref)
        self.notifier.clear(target: ref.target)
    }

    public func chatWindowClosed(_ ref: ChatWindowRef) {
        guard let count = self.legacyWindowRefCounts[ref] else { return }
        self.legacyWindowRefCounts[ref] = count > 1 ? count - 1 : nil
        self.unpinChatWindow(ref)
        self.refreshChatWindowVisibility(ref)
    }

    private func pinChatWindow(_ ref: ChatWindowRef) -> Bool {
        guard let gateway = self.gateways.first(where: { $0.id == ref.gatewayId }),
              !(gateway.state.isConnected && !gateway.sessions.isEmpty && gateway.sessions[ref.sessionKey] == nil) else { return false }
        self.windowRefCounts[ref, default: 0] += 1
        gateway.chatWindowOpened(ref.sessionKey)
        return true
    }

    private func unpinChatWindow(_ ref: ChatWindowRef) {
        guard let count = self.windowRefCounts[ref] else { return }
        self.windowRefCounts[ref] = count > 1 ? count - 1 : nil
        self.gateways.first { $0.id == ref.gatewayId }?.chatWindowClosed(ref.sessionKey)
    }

    private func refreshChatWindowVisibility(_ ref: ChatWindowRef) {
        let shown = self.legacyWindowRefCounts[ref, default: 0] > 0
            || self.ownedChatWindows.values.contains { $0.ref == ref && $0.isVisible }
        if shown { self.notifier.windowVisible.insert(ref.target) }
        else { self.notifier.windowVisible.remove(ref.target) }
    }

    func removeChatWindows(gatewayID: UUID) {
        let owners = self.ownedChatWindows.filter { $0.value.ref.gatewayId == gatewayID }
        for (id, owner) in owners { self.chatWindowClosed(owner.ref, windowID: id) }
        let legacy = self.legacyWindowRefCounts.filter { $0.key.gatewayId == gatewayID }
        for (ref, count) in legacy {
            for _ in 0..<count { self.chatWindowClosed(ref) }
        }
    }
}
