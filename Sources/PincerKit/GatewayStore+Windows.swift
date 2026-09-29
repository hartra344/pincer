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

// MARK: Split view

extension GatewayStore {
    /// The split view's second chat, when it shows one: set, still listed once sessions have
    /// loaded, and not the chat already selected beside it.
    public var visibleSplitKey: String? {
        guard let key = self.splitKey, key != self.selectedKey else { return nil }
        if self.state.isConnected, !self.sessions.isEmpty, self.sessions[key] == nil { return nil }
        return key
    }

    /// Puts `key` beside the selected chat. Picking the selected chat itself swaps nothing in.
    public func openInSplit(_ key: String) {
        guard key != self.selectedKey else { return }
        self.splitKey = key
    }

    /// Swaps the two chats of the split view. Focus stays with the chat, so it moves sides too.
    public func swapSplit() {
        guard let split = self.visibleSplitKey, let selected = self.selectedKey else { return }
        let rightFocused = self.splitPaneFocused
        self.splitKey = selected
        self.selectedKey = split
        self.splitPaneFocused = !rightFocused
    }

    public func closeSplit() {
        self.splitKey = nil
        self.splitPaneFocused = false
    }

    /// The chat that menu commands and the window's chat controls act on (#404): the split view's
    /// right-hand chat while it has focus, else the selected chat.
    public var focusedKey: String? {
        if self.splitPaneFocused, let split = self.visibleSplitKey { return split }
        return self.selectedKey
    }

    /// A chat's title as last seen, for headers shown before the sessions list arrives (#407).
    public func cachedTitle(for key: String) -> String? {
        (self.defaults.dictionary(forKey: self.titleCacheKey) as? [String: String])?[key]
    }

    /// Remembers the titles of the chats on screen in the main window; only those are kept.
    public func rememberTitle(_ title: String, for key: String) {
        var titles = (self.defaults.dictionary(forKey: self.titleCacheKey) as? [String: String]) ?? [:]
        guard titles[key] != title else { return }
        let keep: Set<String> = [key, self.selectedKey, self.splitKey].reduce(into: []) { if let k = $1 { $0.insert(k) } }
        titles = titles.filter { keep.contains($0.key) }
        titles[key] = title
        self.defaults.set(titles, forKey: self.titleCacheKey)
    }

    private var titleCacheKey: String { "pincer.paneTitles.\(self.id.uuidString)" }
}

extension AppModel {
    /// The chat Split Right opens beside the selected one: the most recently visited other chat on
    /// the same Gateway, else the first other chat in the sidebar.
    public func splitCandidate(for gateway: GatewayStore) -> String? {
        let recent = self.history.recent.first { $0.gatewayId == gateway.id && $0.sessionKey != gateway.selectedKey
            && gateway.sessions[$0.sessionKey].map { !$0.isArchived && !$0.isSubagent } == true }
        if let recent { return recent.sessionKey }
        return gateway.sortedRows.first { $0.key != gateway.selectedKey && !$0.isArchived && !$0.isSubagent }?.key
    }
}
