import Foundation

/// Two layers of "recent" stack here, warm ⊆ resident:
/// - **Warm** (`warmKeys`, `recentKeys`, `warmChatLimit`): the selected chat, the most recent selections and running
///   chats keep their message subscription. Others release it and reload when opened.
/// - **Resident** (`residency`): hydrated chats, ranked by any use (`chat(for:)`, selection, runs). Beyond
///   `residency.limit` chats or `residency.budget` items (pinned chats included), the least recently used
///   unpinned ones are dehydrated in place (#563: recent chats stay resident, so switching back is instant).
/// Every warm chat is pinned here, and the limit is never below `warmChatLimit`, so a chat that is subscribed
/// is never dehydrated; a chat can be resident without being warm, but not the other way around.
extension GatewayStore {
    /// Chats that must stay hydrated: warm ones, the selected one, running or busy ones, and any with unsent messages.
    func pinnedChatKeys() -> Set<String> {
        self.chats.values.filter { $0.residencySnapshot.isPinned }.reduce(into: self.warmKeys(includingLive: true)) {
            $0.insert($1.sessionKey)
        }
    }

    func isChatPinned(_ key: String) -> Bool {
        self.pinnedChatKeys().contains(key)
    }

    /// Dehydrates the least recently used unpinned chats until at most `limit` chats (pinned included) are
    /// hydrated, one at a time. A request that arrives mid-pass is kept (strictest limit wins) and runs afterwards.
    func enforceChatBudget(limit: Int? = nil) {
        let requested = limit ?? self.residency.limit
        guard !self.enforcingChatBudget else {
            self.pendingChatBudgetLimit = min(self.pendingChatBudgetLimit ?? requested, requested)
            return
        }
        let hydratedChats = self.chats.values.filter(\.isHydrated)
        let hydrated = Set(hydratedChats.map(\.sessionKey))
        let costs = Dictionary(hydratedChats.map { ($0.sessionKey, $0.items.count) }, uniquingKeysWith: max)
        let victims = self.residency.victims(hydrated: hydrated, pinned: self.pinnedChatKeys(), limit: requested,
                                             costs: costs)
        let trims = Set(self.chats.values.filter { $0.isHydrated && !$0.residencySnapshot.isPinned }.map(\.sessionKey))
            .subtracting(victims)
        guard !victims.isEmpty || !trims.isEmpty else { return }
        self.enforcingChatBudget = true
        Task { [weak self] in
            for key in victims {
                guard let self, let chat = self.chats[key], !self.isChatPinned(key) else { continue }
                await chat.dehydrate()
            }
            // Idle chats that stay resident keep only their newest window in memory.
            for key in trims {
                await self?.chats[key]?.trimToWindow()
            }
            guard let self else { return }
            self.enforcingChatBudget = false
            if let pending = self.pendingChatBudgetLimit {
                self.pendingChatBudgetLimit = nil
                self.enforceChatBudget(limit: pending)
            }
        }
    }

    /// A chat's run started or ended: it counts as recently used, and once idle it may be trimmed.
    func chatRunStateChanged(_ key: String, running: Bool) {
        self.residency.touch(key)
        if !running { Task { @MainActor [weak self] in self?.enforceChatBudget() } }
    }

    func handleMemoryPressure(critical: Bool) {
        self.enforceChatBudget(limit: ChatResidency.pressureLimit(critical: critical, base: self.residency.limit))
    }

    func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) == true
            MainActor.assumeIsolated { self?.handleMemoryPressure(critical: critical) }
        }
        source.resume()
        self.memoryPressureSource = source
    }
}
