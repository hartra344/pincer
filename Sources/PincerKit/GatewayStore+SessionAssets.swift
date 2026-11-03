import Foundation

extension GatewayStore {
    /// Most Assets models kept; the oldest is reset (its list dropped) past this.
    static let assetsModelLimit = 16

    /// The Assets model for a chat session, created on first use. Bounded LRU like `filesModel(for:)`.
    public func assetsModel(for sessionKey: String) -> SessionAssetsModel {
        if let model = self.assetsModelCache[sessionKey] {
            self.assetsModelOrder.removeAll { $0 == sessionKey }
            self.assetsModelOrder.append(sessionKey)
            return model
        }
        let connection = self.connection
        let gatewayId = self.id
        let root = self.cacheRoot
        let model = SessionAssetsModel(
            sessionKey: sessionKey, agentId: self.sessions[sessionKey]?.agentId,
            request: { try await connection.request($0, $1) },
            advertises: { [weak self] method in self?.advertises(method) ?? false },
            liveItems: { [weak self] in self?.chats[sessionKey]?.items ?? [] },
            cachedItems: { await TranscriptCache.load(gatewayId: gatewayId, sessionKey: sessionKey, root: root)?.items },
            settled: { [weak self] in await self?.chats[sessionKey]?.reloadTask?.value })
        self.assetsModelCache[sessionKey] = model
        self.assetsModelOrder.append(sessionKey)
        while self.assetsModelOrder.count > Self.assetsModelLimit {
            let oldest = self.assetsModelOrder.removeFirst()
            self.assetsModelCache.removeValue(forKey: oldest)?.reset()
        }
        return model
    }

    func resetAssetsModels() {
        for model in self.assetsModelCache.values { model.handleReconnect() }
    }
}
