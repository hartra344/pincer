import Foundation

extension GatewayStore {
    /// Chats that must stay hydrated: the selected one, running or busy ones, and any with unsent messages.
    func pinnedChatKeys() -> Set<String> {
        Set(self.chats.values.filter { $0.residencySnapshot.isPinned }.map(\.sessionKey))
    }

    func isChatPinned(_ key: String) -> Bool {
        self.chats[key]?.residencySnapshot.isPinned ?? false
    }

    /// Dehydrates the least recently used unpinned chats beyond the limit, one at a time.
    func enforceChatBudget(limit: Int? = nil) {
        guard !self.enforcingChatBudget else { return }
        let hydrated = Set(self.chats.values.filter(\.isHydrated).map(\.sessionKey))
        let victims = self.residency.victims(hydrated: hydrated, pinned: self.pinnedChatKeys(), limit: limit)
        guard !victims.isEmpty else { return }
        self.enforcingChatBudget = true
        Task { [weak self] in
            for key in victims {
                guard let self, let chat = self.chats[key], !self.isChatPinned(key) else { continue }
                await chat.dehydrate()
            }
            self?.enforcingChatBudget = false
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
