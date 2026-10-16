import Foundation

extension GatewayStore {
    /// Most session Files models kept; the oldest is reset (its data dropped) past this.
    static let filesModelLimit = 16

    /// The Files model for a chat session, created on first use. Bounded LRU: evicted models drop their listing data.
    public func filesModel(for sessionKey: String) -> SessionFilesModel {
        if let model = self.filesModelCache[sessionKey] {
            self.filesModelOrder.removeAll { $0 == sessionKey }
            self.filesModelOrder.append(sessionKey)
            return model
        }
        let connection = self.connection
        let model = SessionFilesModel(
            sessionKey: sessionKey, agentId: self.sessions[sessionKey]?.agentId,
            request: { try await connection.request($0, $1) },
            hasAdmin: { [weak self] in
                guard let self else { return false }
                return self.profile.isDemo || (self.hello?.scopes.contains(GatewayConnection.adminScope) ?? false)
            },
            advertises: { [weak self] method in self?.advertises(method) ?? false })
        self.filesModelCache[sessionKey] = model
        self.filesModelOrder.append(sessionKey)
        while self.filesModelOrder.count > Self.filesModelLimit {
            let oldest = self.filesModelOrder.removeFirst()
            self.filesModelCache.removeValue(forKey: oldest)?.reset()
        }
        return model
    }

    func resetFilesModels() {
        for model in self.filesModelCache.values { model.handleReconnect() }
    }
}
