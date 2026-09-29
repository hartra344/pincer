import Foundation

/// Chats open in windows of their own (#48). Each one counts as warm, so it keeps its subscription and
/// is pinned against dehydration (see `GatewayStore+Residency`) for as long as a window shows it.
extension GatewayStore {
    public var openWindowKeys: Set<String> { Set(self.windowCounts.keys) }

    public func chatWindowOpened(_ key: String) {
        self.windowCounts[key, default: 0] += 1
        let chat = self.chat(for: key)
        Task {
            await chat.load()
            await self.markRead(key)
        }
    }

    public func chatWindowClosed(_ key: String) {
        guard let count = self.windowCounts[key] else { return }
        if count > 1 {
            self.windowCounts[key] = count - 1
            return
        }
        self.windowCounts[key] = nil
        if !self.warmKeys(includingLive: true).contains(key), let chat = self.chats[key], chat.isSubscribed {
            Task { await chat.releaseSubscription() }
        }
        self.enforceChatBudget()
    }
}
