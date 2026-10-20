import Foundation
import Observation

extension GatewayStore {
    public func start() {
        guard self.pumpTask == nil else { return }
        self.outboxLoadTask = Task { await self.loadOutbox() }
        self.startNetworkWatch()
        // A single ordered stream keeps chat deltas and state changes in wire order.
        let stream = CoalescingEventBuffer<Inbound> {
            if case let .event(event) = $0 { return event.coalescingKey }
            return nil
        }
        self.eventBuffer = stream
        self.pumpTask = Task { [weak self] in
            for await inbound in stream {
                guard let self else { return }
                switch inbound {
                case let .event(event): self.handle(event)
                case let .state(state, hello): self.update(state: state, hello: hello)
                }
            }
        }
        let connection = self.connection
        Task {
            await connection.setHandlers(
                onEvent: { stream.yield(.event($0)) },
                onState: { stream.yield(.state($0, $1)) })
            await connection.start()
        }
        self.deviceNode.setForeground(self.appIsActive)
        self.deviceNode.start()
    }

    public func stop() {
        self.deviceNode.stop()
        self.replySendLifecycle &+= 1
        for task in self.replyReservationPreparations.values { task.cancel() }
        self.wakeReplyAcceptanceWaiters()
        for chat in self.chats.values {
            chat.stopReplyPreviewPublication()
        }
        let connection = self.connection
        self.pumpTask?.cancel()
        self.pumpTask = nil
        self.eventBuffer?.finish()
        self.eventBuffer = nil
        self.prefetchTask?.cancel()
        for fill in self.headlessFills.values { fill.task.cancel() }
        self.reconcileTask?.cancel()
        self.bootstrapTask?.cancel()
        self.bootstrapTask = nil
        Task { await connection.stop() }
    }

    /// Returns once the background history prefetch has finished and its writes have landed, so a
    /// check can clear a cached chat without it being saved back.
    public func settlePrefetch() async {
        await self.prefetchTask?.value
        for fill in self.headlessFills.values { await fill.task.value }
        await TranscriptCache.flush(gatewayId: self.id, root: self.cacheRoot)
    }

    /// `stop()` for a store that won't be started again, returning once the connection is torn
    /// down and its chats' last cache writes and search indexing have landed.
    public func stopAndFlushCache() async {
        self.stop()
        await self.connection.stop()
        for chat in self.chats.values { await chat.finishCaching() }
        await TranscriptCache.flush(gatewayId: self.id, root: self.cacheRoot)
    }

    /// Whether this connection can see and answer agent questions (`operator.questions`).
    public var canAnswerQuestions: Bool { self.hello?.canAnswerQuestions ?? false }

    /// Reconnects asking for `operator.questions` again, once its upgrade was approved on the host.
    public func retryQuestionAccess() {
        let connection = self.connection
        Task { await connection.retryWithheldScopes() }
    }

    /// Demo only: asks the demo's attached device node for `command`, like an operator's `node.invoke`.
    /// Returns `{ok, nodeId, command, payload?, payloadJSON?, error?}`, nil off the demo.
    public func demoInvokeNode(command: String, paramsJSON: String? = nil) async -> JSONValue? {
        await self.connection.demoInvokeNode(command: command, paramsJSON: paramsJSON)
    }

    public func reconnectIfNeeded() {
        let connection = self.connection
        Task { await connection.reconnectNow() }
        self.deviceNode.reconnectNow()
    }

    // MARK: State

    static func gatewayHostKey(_ id: UUID) -> String { "pincer.gatewayHost.\(id.uuidString)" }

    /// Drops the saved host name, for a gateway being removed.
    func forgetGatewayHost() {
        self.gatewayHost = nil
        self.defaults.removeObject(forKey: Self.gatewayHostKey(self.id))
    }

    private func update(state: ConnectionState, hello: GatewayHello?) {
        if state == .connected {
            self.setSessionListReady(false)
            self.deviceNode.operatorConnected(scopes: hello?.scopes ?? [])
        }
        self.state = state
        self.routeCandidatesDidChange?()
        if case let .failed(message) = state { self.lastError = message }
        if !state.isConnected {
            self.pairingInbox.reset()
            self.outbox.connectionLost()
            self.channels.disconnected()
            self.devices.reset()
            self.resyncOutboxHolds()
        }
        guard state == .connected, let hello else {
            self.health.connectionChanged(state, hello: nil)
            return
        }
        self.hasConnected = true
        self.hello = hello
        self.resyncOutboxHolds()
        if !self.profile.isDemo { self.saveUploadPolicy(UploadPolicy(hello: hello)) }
        if !self.profile.isDemo, let host = hello.gatewayHost, host != self.gatewayHost {
            self.gatewayHost = host
            self.defaults.set(host, forKey: Self.gatewayHostKey(self.id))
            self.routeCandidatesDidChange?()
        }
        self.images.retryUnavailable()
        self.health.connectionChanged(state, hello: hello)
        self.connectionEpoch += 1
        #if DEBUG
        self.lastObservedBackground = nil
        #endif
        self.expectedPrefEchoes = [:]
        self.messageSubscriptionIdUnsupported = false
        self.replyToUnsupported = false
        self.locationContextUnsupported = false
        self.reactionForwardingOff = []
        self.reactionNoticeShown = []
        self.sessionReactionsOff = false
        self.selfProfile = nil
        self.lastError = nil
        self.bootstrapTask?.cancel()
        let epoch = self.connectionEpoch
        self.bootstrapTask = Task { await self.bootstrap(epoch: epoch) }
        self.execPolicy.handleReconnect()
        self.agentManagement.handleReconnect()
        self.browserPanel.handleReconnect()
        self.portals.handleReconnect()
        self.resetFilesModels()
        self.devices.handleReconnect()
        self.skills.handleReconnect()
        self.sessionManager.handleReconnect()
        self.voice.handleReconnect()
    }
}
