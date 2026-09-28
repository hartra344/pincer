import Foundation
import Testing
@testable import PincerKit

/// The pure outbox state machine (#46): per-session order, exactly-once keys, failure handling.
@Suite("Outbox state machine")
struct OutboxTests {
    let main = "agent:main:main"
    let other = "agent:research:main"
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ id: String, _ session: String? = nil, text: String? = nil, offset: TimeInterval = 0,
               state: OutboxState = .queued, attachments: Bool = false) -> OutboxEntry
    {
        OutboxEntry(id: id, sessionKey: session ?? self.main, text: text ?? "message \(id)",
                    createdAt: self.start.addingTimeInterval(offset), state: state, hasAttachments: attachments)
    }

    func outbox(_ entries: OutboxEntry...) -> Outbox {
        var box = Outbox()
        for entry in entries { box.enqueue(entry) }
        return box
    }

    /// Drains `box` the way the store does: send the next eligible entry, mark it sent.
    func drain(_ box: inout Outbox, sessionKey: String? = nil) -> [String] {
        var sent: [String] = []
        while let next = box.nextToSend(sessionKey: sessionKey) {
            box.markSending(id: next.id)
            sent.append(next.id)
            box.markSent(id: next.id)
        }
        return sent
    }

    func failure(_ box: Outbox, _ id: String) -> OutboxFailure? {
        if case let .failed(failure)? = box.entry(id: id)?.state { return failure }
        return nil
    }

    // MARK: Ordering

    @Test func sendsInEnqueueOrderPerSession() {
        var box = self.outbox(self.entry("a"), self.entry("b"), self.entry("c"))
        #expect(self.drain(&box) == ["a", "b", "c"])
        #expect(box.isEmpty)
    }

    @Test func sessionsAreIndependentAndFiltered() {
        var box = self.outbox(self.entry("a"), self.entry("x", self.other), self.entry("b"), self.entry("y", self.other))
        #expect(box.entries(for: self.other).map(\.id) == ["x", "y"])
        #expect(box.sessionKeys == [self.main, self.other])
        #expect(self.drain(&box, sessionKey: self.other) == ["x", "y"])
        #expect(box.entries.map(\.id) == ["a", "b"])
        #expect(box.nextToSend(sessionKey: self.other) == nil)
    }

    @Test func sendingEntryBlocksItsSessionOnly() {
        var box = self.outbox(self.entry("a"), self.entry("b"), self.entry("x", self.other))
        box.markSending(id: "a")
        #expect(box.nextToSend(sessionKey: self.main) == nil, "b waits for a")
        #expect(box.nextToSend()?.id == "x", "other sessions keep going")
    }

    @Test func failedHeadBlocksLaterEntries() {
        var box = self.outbox(self.entry("a"), self.entry("b"), self.entry("x", self.other))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .rejected("bad"))
        #expect(box.nextToSend(sessionKey: self.main) == nil)
        #expect(box.entry(id: "b")?.state == .queued)
        #expect(self.drain(&box) == ["x"])
        box.delete(id: "a")
        #expect(self.drain(&box) == ["b"])
    }

    @Test func retriedHeadGoesBeforeLaterEntries() {
        var box = self.outbox(self.entry("a"), self.entry("b"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .transient, isConnected: true)
        box.retry(id: "a")
        #expect(self.drain(&box) == ["a", "b"])
    }

    @Test func attachmentEntriesAreNeverAutoSentAndBlockTheirSession() {
        var box = self.outbox(self.entry("pic", attachments: true), self.entry("b"), self.entry("x", self.other))
        #expect(self.drain(&box) == ["x"])
        #expect(box.entries.map(\.id) == ["pic", "b"])
    }

    // MARK: Exactly once

    @Test func reEnqueueReplacesInPlace() {
        var box = self.outbox(self.entry("a"), self.entry("b"))
        box.enqueue(self.entry("a", text: "edited"))
        #expect(box.entries.map(\.id) == ["a", "b"])
        #expect(box.entry(id: "a")?.text == "edited")
        #expect(box.count == 2)
    }

    @Test func retryReusesTheIdempotencyKey() {
        var box = self.outbox(self.entry("key-1"))
        box.markSending(id: "key-1")
        box.markFailed(id: "key-1", kind: .transient, isConnected: true)
        box.retry(id: "key-1")
        let resend = box.nextToSend()
        #expect(resend?.id == "key-1" && resend?.idempotencyKey == "key-1")
        box.markSending(id: "key-1")
        #expect(box.entry(id: "key-1")?.attempts == 2)
    }

    @Test func markSentRemovesOnceAndIsIdempotent() {
        var box = self.outbox(self.entry("a"), self.entry("b"))
        box.markSending(id: "a")
        box.markSent(id: "a")
        box.markSent(id: "a")
        #expect(box.entries.map(\.id) == ["b"])
        box.markFailed(id: "a", kind: .transient)
        box.retry(id: "a")
        box.markSending(id: "a")
        #expect(box.entries.map(\.id) == ["b"], "late callbacks for a sent entry don't resurrect it")
    }

    @Test func markSendingCountsAttempts() {
        var box = self.outbox(self.entry("a"))
        #expect(box.entry(id: "a")?.attempts == 0)
        box.markSending(id: "a")
        #expect(box.entry(id: "a")?.state == .sending && box.entry(id: "a")?.attempts == 1)
    }

    @Test func retryWhileSendingIsIgnored() {
        var box = self.outbox(self.entry("a"))
        box.markSending(id: "a")
        box.retry(id: "a")
        #expect(box.entry(id: "a")?.state == .sending, "no double send while one is in flight")
        #expect(box.nextToSend() == nil)
    }

    // MARK: Failures

    @Test func transientWhileDisconnectedRequeues() {
        var box = self.outbox(self.entry("a"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .transient, isConnected: false)
        #expect(box.entry(id: "a")?.state == .queued)
        #expect(box.nextToSend()?.id == "a")
    }

    @Test func transientWhileConnectedFailsRetryably() {
        var box = self.outbox(self.entry("a"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .transient, isConnected: true, message: "Timed out")
        #expect(self.failure(box, "a") == OutboxFailure(message: "Timed out", retryable: true))
        #expect(box.nextToSend() == nil, "an ambiguous timeout waits for the user")
    }

    @Test func rejectedIsNotAutoRetried() {
        var box = self.outbox(self.entry("a"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .rejected("invalid chat.send params"))
        #expect(self.failure(box, "a") == OutboxFailure(message: "invalid chat.send params", retryable: false))
        box.connectionLost()
        box.recoverAfterLaunch()
        #expect(box.nextToSend() == nil, "neither reconnect nor relaunch resends a rejection")
        #expect(box.entry(id: "a")?.attempts == 1)
        #expect(box.entry(id: "a")?.isFailed == true)
    }

    @Test func authRevokedWaitsForTheUser() {
        var box = self.outbox(self.entry("a"), self.entry("b"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .authRevoked)
        let failure = self.failure(box, "a")
        #expect(failure?.retryable == true && failure?.message.isEmpty == false)
        box.connectionLost()
        #expect(box.nextToSend() == nil, "reconnecting alone doesn't resend after auth was revoked")
        box.retry(id: "a")
        #expect(self.drain(&box) == ["a", "b"])
    }

    @Test func failedEntriesCanBeDeleted() {
        var box = self.outbox(self.entry("a"))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: .rejected("no"))
        box.delete(id: "a")
        #expect(box.isEmpty)
        box.delete(id: "missing")
        #expect(box.isEmpty)
    }

    // MARK: Connection and launch

    @Test func connectionLostRequeuesInFlightButKeepsFailures() {
        var box = self.outbox(self.entry("a"), self.entry("x", self.other))
        box.markSending(id: "a")
        box.markSending(id: "x")
        box.markFailed(id: "x", kind: .rejected("no"))
        box.connectionLost()
        #expect(box.entry(id: "a")?.state == .queued)
        #expect(box.entry(id: "x")?.isFailed == true)
        #expect(box.nextToSend()?.id == "a")
        #expect(box.entry(id: "a")?.attempts == 1, "requeueing isn't an attempt")
    }

    @Test func recoverAfterLaunchRequeuesSendingAndDropsAttachments() {
        var box = self.outbox(
            self.entry("a", state: .sending), self.entry("pic", attachments: true),
            self.entry("f", self.other, state: .failed(OutboxFailure(message: "no", retryable: false))))
        box.recoverAfterLaunch()
        #expect(box.entries.map(\.id) == ["a", "f"])
        #expect(box.entry(id: "a")?.state == .queued)
        #expect(box.entry(id: "f")?.isFailed == true)
    }

    @Test func reconcileDropsEntriesAlreadyInTheTranscript() {
        var box = self.outbox(self.entry("a", state: .sending), self.entry("b"), self.entry("x", self.other))
        box.reconcile(committedKeys: ["a", "x", "unrelated"])
        #expect(box.entries.map(\.id) == ["b"])
        box.reconcile(committedKeys: [])
        #expect(box.entries.map(\.id) == ["b"])
    }

    @Test func ambiguousDropThenReconcileSendsOnce() {
        // The socket drops after the Gateway accepted "a": reconcile against history before resending.
        var box = self.outbox(self.entry("a"), self.entry("b"))
        box.markSending(id: "a")
        box.connectionLost()
        box.reconcile(committedKeys: ["a"])
        #expect(self.drain(&box) == ["b"])
    }

    @Test func removeSessionDropsOnlyThatSession() {
        var box = self.outbox(self.entry("a"), self.entry("x", self.other), self.entry("b"))
        box.removeSession(self.main)
        #expect(box.entries.map(\.id) == ["x"])
    }

    @Test func persistableLeavesAttachmentsOut() {
        let box = self.outbox(self.entry("a"), self.entry("pic", attachments: true))
        #expect(box.persistable.entries.map(\.id) == ["a"])
    }

    // MARK: Codable

    @Test func entryRoundTripsEveryState() throws {
        let states: [OutboxState] = [.queued, .sending, .failed(OutboxFailure(message: "nope", retryable: false))]
        for state in states {
            var entry = self.entry("a", state: state)
            entry.agentId = "main"
            entry.replyToId = "msg-1"
            entry.replyPreview = ReplyPreview(text: "earlier", senderLabel: "Claw")
            entry.attempts = 3
            let decoded = try JSONDecoder().decode(OutboxEntry.self, from: JSONEncoder().encode(entry))
            #expect(decoded == entry)
        }
    }

    @Test func entryDecodesWithoutOptionalFields() throws {
        let json = #"{"id":"k","sessionKey":"agent:main:main","text":"hi","createdAt":0,"state":{"queued":{}}}"#
        let decoded = try JSONDecoder().decode(OutboxEntry.self, from: Data(json.utf8))
        #expect(decoded.attempts == 0 && decoded.hasAttachments == false && decoded.agentId == nil)
    }
}

@Suite("Send failure classification")
struct SendFailureClassificationTests {
    func rpc(_ code: String, _ message: String = "nope", details: JSONValue? = nil) -> GatewayError {
        .rpc(code: code, message: message, details: details)
    }

    @Test func retryableErrorShapeIsTransient() {
        // Upstream's busy error: `{code: UNAVAILABLE, retryable: true, retryAfterMs: 250}`.
        let frame = Data(#"""
        {"type":"res","id":"1","ok":false,"error":{"code":"UNAVAILABLE","message":"Previous run is still shutting down. Please try again in a moment.","retryable":true,"retryAfterMs":250}}
        """#.utf8)
        guard case let .response(_, .failure(error))? = GatewayConnection.inboundFrame(frame) else {
            Issue.record("not an error response")
            return
        }
        #expect(error.isRetryable)
        #expect(SendFailure.classify(error) == .transient)
    }

    @Test func retryableFlagSurvivesExistingDetails() {
        let frame = Data(#"{"type":"res","id":"1","ok":false,"error":{"code":"UNAVAILABLE","message":"busy","retryable":true,"details":{"reason":"goal-session-busy"}}}"#.utf8)
        guard case let .response(_, .failure(error))? = GatewayConnection.inboundFrame(frame) else {
            Issue.record("not an error response")
            return
        }
        #expect(error.isRetryable)
        guard case let .rpc(_, _, details) = error else { Issue.record("not rpc"); return }
        #expect(details?["reason"]?.string == "goal-session-busy")
    }

    @Test func nonRetryableErrorsAreRejected() {
        #expect(SendFailure.classify(self.rpc("INVALID_REQUEST", "invalid chat.send params")) == .rejected("invalid chat.send params"))
        // UNAVAILABLE flagged `retryable: false` means resending won't help.
        #expect(SendFailure.classify(self.rpc("UNAVAILABLE", "x", details: .object(["retryable": .bool(false)]))) == .rejected("x"))
    }

    @Test func unavailableWithoutAFlagIsTransient() {
        // The Gateway busy or briefly down, not saying either way: while connected it fails with Retry.
        #expect(SendFailure.classify(self.rpc("UNAVAILABLE", "mock send failure")) == .transient)
        var box = Outbox()
        box.enqueue(OutboxEntry(id: "a", sessionKey: "agent:main:main", text: "hi", createdAt: Date(timeIntervalSince1970: 0)))
        box.markSending(id: "a")
        box.markFailed(id: "a", kind: SendFailure.classify(self.rpc("UNAVAILABLE", "busy")), isConnected: true)
        #expect(box.entry(id: "a")?.state == .failed(OutboxFailure(message: "Couldn't send.", retryable: true)))
    }

    @Test func authFailuresAreAuthRevoked() {
        #expect(SendFailure.classify(self.rpc("NOT_PAIRED")) == .authRevoked)
        #expect(SendFailure.classify(self.rpc("FORBIDDEN")) == .authRevoked)
        #expect(SendFailure.classify(self.rpc("INVALID_REQUEST", details: .object(["code": .string("MISSING_SCOPE")]))) == .authRevoked)
    }

    @Test func connectionFailuresAreTransient() {
        #expect(SendFailure.classify(GatewayError.notConnected) == .transient)
        #expect(SendFailure.classify(GatewayError.timeout("chat.send")) == .transient)
        #expect(SendFailure.classify(GatewayError.closed("mock drop")) == .transient)
        #expect(SendFailure.classify(URLError(.networkConnectionLost)) == .transient)
        #expect(SendFailure.classify(CancellationError()) == .transient)
    }

    @Test func failureMessagesShowTheGatewayReasonOrAPlainLabel() {
        #expect(SendFailure.message(for: self.rpc("INVALID_REQUEST", "invalid chat.send params: mock rejection"))
            == "invalid chat.send params: mock rejection")
        #expect(SendFailure.message(for: self.rpc("NOT_PAIRED", "device not paired")) == SendFailure.signInRequired)
        #expect(SendFailure.message(for: self.rpc("INVALID_REQUEST", "session agent:main:dashboard:x was not found"))
            == SendFailure.sessionMissing)
        #expect(SendFailure.message(for: self.rpc("INVALID_REQUEST", "That chat no longer exists")) == SendFailure.sessionMissing)
        #expect(SendFailure.message(for: self.rpc("INVALID_REQUEST", "message was not found")) == "message was not found")
    }

    @Test func clientConfigurationErrorsAreRejected() {
        if case .rejected = SendFailure.classify(GatewayError.protocolViolation("bad frame")) {} else { Issue.record("protocolViolation") }
        if case .rejected = SendFailure.classify(GatewayError.invalidURL("x")) {} else { Issue.record("invalidURL") }
    }
}
