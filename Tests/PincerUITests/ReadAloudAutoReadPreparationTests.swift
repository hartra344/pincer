import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class HeldAutoReadSpeaker: ReadAloudLocalSpeaking {
    private(set) var spokenTexts: [String] = []
    private var completion: CheckedContinuation<Bool, Never>?

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        self.spokenTexts.append(text)
        return await withCheckedContinuation { self.completion = $0 }
    }

    func stop() {
        self.completion?.resume(returning: false)
        self.completion = nil
    }
}

@MainActor
private final class SilentAutoReadPlayer: ReadAloudClipPlaying {
    func play(_: TTSClip) async -> Bool { false }
    func stop() {}
}

private actor HeldAutoReadPreparation {
    struct Snapshot: Sendable {
        let startedIDs: [String]
        let finishedIDs: [String]
        let activeWorkers: Int
        let maximumActiveWorkers: Int
    }

    private struct HeldReply {
        let continuation: CheckedContinuation<SpeechText.PreparedReply?, Never>
        let reply: SpeechText.PreparedReply?
    }

    private let heldIDs: Set<String>
    private let observation: AutoReadPreparationObservation
    private var releasedIDs: Set<String> = []
    private var heldReplies: [String: HeldReply] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var startedIDs: [String] = []
    private var finishedIDs: [String] = []
    private var activeWorkers = 0
    private var maximumActiveWorkers = 0

    init(heldIDs: Set<String>, observation: AutoReadPreparationObservation) {
        self.heldIDs = heldIDs
        self.observation = observation
    }

    func prepare(_ items: [ChatItem]) async -> SpeechText.PreparedReply? {
        let id = items.first.map { $0.transcriptId ?? $0.id } ?? "empty"
        let reply = SpeechText.latestSpeakableReply(in: items)
        self.activeWorkers += 1
        self.maximumActiveWorkers = max(self.maximumActiveWorkers, self.activeWorkers)
        self.startedIDs.append(id)
        self.startWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        await self.observation.didStart(id)

        let result: SpeechText.PreparedReply?
        if self.heldIDs.contains(id), !self.releasedIDs.contains(id) {
            result = await withCheckedContinuation { continuation in
                self.heldReplies[id] = HeldReply(continuation: continuation, reply: reply)
            }
        } else {
            result = reply
        }

        self.activeWorkers -= 1
        self.finishedIDs.append(id)
        self.finishWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        await self.observation.didFinish(id)
        return result
    }

    func waitUntilStarted(_ id: String) async {
        if self.startedIDs.contains(id) { return }
        await withCheckedContinuation { self.startWaiters[id, default: []].append($0) }
    }

    func waitUntilFinished(_ id: String) async {
        if self.finishedIDs.contains(id) { return }
        await withCheckedContinuation { self.finishWaiters[id, default: []].append($0) }
    }

    func release(_ id: String) {
        self.releasedIDs.insert(id)
        guard let held = self.heldReplies.removeValue(forKey: id) else { return }
        held.continuation.resume(returning: held.reply)
    }

    func releaseAll() {
        for id in self.heldIDs { self.release(id) }
    }

    var snapshot: Snapshot {
        Snapshot(startedIDs: self.startedIDs, finishedIDs: self.finishedIDs,
                 activeWorkers: self.activeWorkers, maximumActiveWorkers: self.maximumActiveWorkers)
    }
}

@MainActor
private final class AutoReadPreparationObservation {
    private(set) var startedIDs: [String] = []
    private(set) var finishedIDs: [String] = []

    func didStart(_ id: String) { self.startedIDs.append(id) }
    func didFinish(_ id: String) { self.finishedIDs.append(id) }
}

@MainActor
private final class AutoReadTestBlocker {
    var isBlocked = false
    private(set) var checkCount = 0

    func check() -> Bool {
        self.checkCount += 1
        return self.isBlocked
    }
}

@MainActor
private final class AutoReadFixture {
    let scratch: ScratchDefaults
    let gateway: GatewayStore
    let chat: ChatStore
    let preparation: HeldAutoReadPreparation
    let preparationObservation: AutoReadPreparationObservation
    let blocker: AutoReadTestBlocker
    let speaker: HeldAutoReadSpeaker
    let controller: ReadAloudController
    let state: ReadAloudChatState

    init(sessionKey: String, heldIDs: Set<String> = []) {
        let scratch = ScratchDefaults()
        let speaker = HeldAutoReadSpeaker()
        let blocker = AutoReadTestBlocker()
        let profile = GatewayProfile(name: "Auto-read probe", url: "ws://127.0.0.1:1", authMode: .none)
        self.scratch = scratch
        self.speaker = speaker
        self.blocker = blocker
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        self.gateway = gateway
        self.chat = gateway.chat(for: sessionKey)
        let preparationObservation = AutoReadPreparationObservation()
        self.preparationObservation = preparationObservation
        let preparation = HeldAutoReadPreparation(heldIDs: heldIDs, observation: preparationObservation)
        self.preparation = preparation
        scratch.defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
        let controller = ReadAloudController(
            clipPlayer: SilentAutoReadPlayer(), localSpeaker: speaker, defaults: scratch.defaults)
        self.controller = controller
        let state = ReadAloudChatState(
            controller: controller,
            autoReadPreparer: { items in await preparation.prepare(items) },
            autoReadBlocked: { blocker.check() })
        self.state = state
    }

    func install(on chat: ChatStore? = nil, gateway: GatewayStore? = nil) {
        self.state.bind(chat: chat ?? self.chat, gateway: gateway ?? self.gateway)
        self.state.installAutoReadCallback()
    }

    func deliver(id: String, text: String, runID: String = UUID().uuidString, to chat: ChatStore? = nil) {
        let chat = chat ?? self.chat
        chat.handleChat([
            "runId": .string(runID),
            "sessionKey": .string(chat.sessionKey),
            "state": .string("final"),
        ])
        chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string(text)]],
                "__openclaw": ["id": .string(id)],
            ],
        ])
    }

    func cleanup() {
        self.state.unbind()
        self.controller.stop()
        Task { await self.preparation.releaseAll() }
        self.scratch.remove()
    }
}

@MainActor
@Suite("Read Aloud enabled callback preparation", .serialized)
struct ReadAloudAutoReadPreparationTests {
    private func waitForStart(_ id: String, fixture: AutoReadFixture) async -> Bool {
        let observed = await eventually { fixture.preparationObservation.startedIDs.contains(id) }
        guard observed else { return false }
        await fixture.preparation.waitUntilStarted(id)
        return true
    }

    private func waitForFinish(_ id: String, fixture: AutoReadFixture) async -> Bool {
        let observed = await eventually { fixture.preparationObservation.finishedIDs.contains(id) }
        guard observed else { return false }
        await fixture.preparation.waitUntilFinished(id)
        return true
    }

    private func waitForAutoReadIdle(_ fixture: AutoReadFixture) async -> Bool {
        await eventually { fixture.state.autoReadPreparationIsIdle }
    }

    @Test func acceptedFinalReplyIsNormalizedOnceOnMainAndPlayedOnce() async {
        let scratch = ScratchDefaults()
        let sessionKey = "agent:probe:auto-read-preparation-\(UUID().uuidString)"
        let itemID = "auto-read-preparation-\(UUID().uuidString)"
        let reply = "The accepted reply has the selected content."
        let profile = GatewayProfile(name: "Auto-read probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: sessionKey)
        let speaker = HeldAutoReadSpeaker()
        scratch.defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
        let controller = ReadAloudController(
            clipPlayer: SilentAutoReadPlayer(), localSpeaker: speaker, defaults: scratch.defaults)
        let autoReadObservation = AutoReadPreparationObservation()
        let autoReadPreparation = HeldAutoReadPreparation(heldIDs: [], observation: autoReadObservation)
        let state = ReadAloudChatState(
            controller: controller,
            autoReadPreparer: { items in await autoReadPreparation.prepare(items) })
        SpeechText.resetSpeakabilityDebugStats(tracking: itemID)
        defer {
            state.unbind()
            controller.stop()
            SpeechText.unregisterSpeakabilityDebugStats(tracking: itemID)
            scratch.remove()
        }

        state.bind(chat: chat, gateway: gateway)
        state.installAutoReadCallback()
        chat.handleChat([
            "runId": .string("run-\(UUID().uuidString)"),
            "sessionKey": .string(sessionKey),
            "state": .string("final"),
        ])
        chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string(reply)]],
                "__openclaw": ["id": .string(itemID)],
            ],
        ])

        let speakerStarted = await eventually {
            speaker.spokenTexts.count == 1
                && chat.items.contains { $0.id == itemID && $0.plainText == reply }
                && controller.activeMessageId == itemID
        }
        #expect(speakerStarted, "the production callback reaches the injected device speaker")
        #expect(chat.items.contains { $0.id == itemID && $0.plainText == reply })
        #expect(controller.activeMessageId == itemID,
                "the accepted final event still starts playback for its message")
        #expect(speaker.spokenTexts == [reply], "playback receives the normalized reply exactly once")
        let autoReadCalls = await autoReadPreparation.snapshot
        #expect(autoReadCalls.startedIDs == [itemID],
                "the UI callback prepares exactly its selected message on the worker")

        let stats = SpeechText.speakabilityDebugStats(for: itemID)
        #expect(stats.mainThreadNormalizations == 1,
                "Kit keeps its synchronous eligibility check while the UI callback uses prepared text")
        #expect(stats.offMainNormalizations >= 1,
                "the callback's selected reply is normalized away from the main thread")
    }

    @Test func hiddenThenShownBeforePreparationReturnsStillDropsThatReply() async {
        let id = "visibility-held-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-visibility", heldIDs: [id])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: id, text: "This reply crossed a hidden interval.")
        guard await self.waitForStart(id, fixture: fixture) else {
            #expect(Bool(false), "the accepted reply entered the worker before hiding")
            return
        }

        fixture.state.isVisible = false
        fixture.state.isVisible = true
        await fixture.preparation.release(id)
        let finished = await self.waitForFinish(id, fixture: fixture)
        #expect(finished)
        let idle = await self.waitForAutoReadIdle(fixture)
        #expect(idle)
        #expect(fixture.speaker.spokenTexts.isEmpty,
                "becoming visible again cannot revive work invalidated by the hidden transition")
    }

    @Test func uninstallThenReinstallDoesNotPlayTheOldCallbackResult() async {
        let oldID = "uninstalled-held-\(UUID().uuidString)"
        let newID = "reinstalled-current-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-install", heldIDs: [oldID])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: oldID, text: "Stale before reinstall.")
        guard await self.waitForStart(oldID, fixture: fixture) else {
            #expect(Bool(false), "the accepted reply entered the worker before uninstall")
            return
        }

        fixture.state.uninstallAutoReadCallback()
        fixture.state.installAutoReadCallback()
        await fixture.preparation.release(oldID)
        let oldFinished = await self.waitForFinish(oldID, fixture: fixture)
        #expect(oldFinished)
        let oldIdle = await self.waitForAutoReadIdle(fixture)
        #expect(oldIdle)
        #expect(fixture.speaker.spokenTexts.isEmpty, "a newly installed callback cannot adopt old work")

        fixture.deliver(id: newID, text: "Only the newly accepted reply should play.")
        let newStarted = await eventually { fixture.speaker.spokenTexts.count == 1 }
        #expect(newStarted)
        #expect(fixture.speaker.spokenTexts == ["Only the newly accepted reply should play."])
        #expect(fixture.controller.activeMessageId == newID)
    }

    @Test func foreignCallbackOwnerIsPreservedAndInvalidatesPriorWork() async {
        let id = "foreign-owner-held-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-owner", heldIDs: [id])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: id, text: "Must not outlive its owner.")
        guard await self.waitForStart(id, fixture: fixture) else {
            #expect(Bool(false), "the accepted reply entered the worker before owner replacement")
            return
        }

        let foreignOwner = NSObject()
        var foreignCalls = 0
        fixture.chat.onFinalAssistantReplyOwner = foreignOwner
        fixture.chat.onFinalAssistantReply = { _ in foreignCalls += 1 }
        fixture.state.uninstallAutoReadCallback()
        #expect(fixture.chat.onFinalAssistantReplyOwner === foreignOwner)
        #expect(fixture.chat.onFinalAssistantReply != nil,
                "uninstalling this state leaves another window's callback in place")

        await fixture.preparation.release(id)
        let finished = await self.waitForFinish(id, fixture: fixture)
        #expect(finished)
        let idle = await self.waitForAutoReadIdle(fixture)
        #expect(idle)
        #expect(fixture.speaker.spokenTexts.isEmpty, "replaced callback ownership invalidates old work")
        fixture.deliver(id: "foreign-owner-next", text: "The other owner still receives events.")
        #expect(foreignCalls == 1)
    }

    @Test func chatSwitchDropsOldReplyAndAllowsNewContext() async {
        let oldID = "old-context-held-\(UUID().uuidString)"
        let newID = "new-context-latest-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-old-context", heldIDs: [oldID])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: oldID, text: "Old chat content.")
        guard await self.waitForStart(oldID, fixture: fixture) else {
            #expect(Bool(false), "the old chat reply entered the worker")
            return
        }

        let newProfile = GatewayProfile(name: "Switched auto-read probe", url: "ws://127.0.0.1:1", authMode: .none)
        let newGateway = GatewayStore(profile: newProfile, defaults: fixture.scratch.defaults,
                                      identity: UIFixtures.identity())
        let newChat = newGateway.chat(for: "agent:probe:auto-read-new-context")
        fixture.install(on: newChat, gateway: newGateway)
        fixture.deliver(id: newID, text: "New chat content.", to: newChat)
        await fixture.preparation.release(oldID)
        let oldFinished = await self.waitForFinish(oldID, fixture: fixture)
        #expect(oldFinished)
        let newStarted = await self.waitForStart(newID, fixture: fixture)
        #expect(newStarted, "the replacement chat's latest callback waits for the old worker to retire")
        let summary = await fixture.preparation.snapshot
        #expect(summary.maximumActiveWorkers == 1, "chat switching never overlaps auto-read workers")
        await fixture.preparation.release(newID)
        let newFinished = await self.waitForFinish(newID, fixture: fixture)
        #expect(newFinished)
        let spokeNewReply = await eventually { fixture.speaker.spokenTexts == ["New chat content."] }
        #expect(spokeNewReply)
        #expect(fixture.controller.activeMessageId == newID)
    }

    @Test func unbindDropsTheInFlightReplyAndClearsItsCallback() async {
        let id = "unbound-held-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-unbind", heldIDs: [id])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: id, text: "This chat is leaving its window.")
        guard await self.waitForStart(id, fixture: fixture) else {
            #expect(Bool(false), "the accepted reply entered the worker before unbind")
            return
        }

        fixture.state.unbind()
        #expect(fixture.chat.onFinalAssistantReply == nil && fixture.chat.onFinalAssistantReplyOwner == nil)
        await fixture.preparation.release(id)
        let finished = await self.waitForFinish(id, fixture: fixture)
        #expect(finished)
        let idle = await self.waitForAutoReadIdle(fixture)
        #expect(idle)
        #expect(fixture.speaker.spokenTexts.isEmpty)
    }

    @Test func sameTranscriptIDEditInvalidatesTheSelectedBody() async {
        let id = "same-id-held-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-same-id", heldIDs: [id])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: id, text: "First body for this transcript ID.")
        guard await self.waitForStart(id, fixture: fixture) else {
            #expect(Bool(false), "the selected reply entered the worker")
            return
        }

        fixture.deliver(id: id, text: "Updated body for this transcript ID.", runID: "run-updated-body")
        await fixture.preparation.release(id)
        let finished = await self.waitForFinish(id, fixture: fixture)
        #expect(finished)
        let idle = await self.waitForAutoReadIdle(fixture)
        #expect(idle)
        #expect(fixture.speaker.spokenTexts.isEmpty,
                "a completion for a stale body cannot speak after the same transcript row changes")
    }

    @Test func onlyOneWorkerRunsAndLatestPendingReplyReplacesIntermediateWork() async {
        let firstID = "first-held-\(UUID().uuidString)"
        let intermediateID = "intermediate-pending-\(UUID().uuidString)"
        let latestID = "latest-pending-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-coalesce",
                                      heldIDs: [firstID, latestID])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: firstID, text: "The first reply becomes stale.", runID: "run-first")
        guard await self.waitForStart(firstID, fixture: fixture) else {
            #expect(Bool(false), "the first accepted reply entered the worker")
            return
        }

        fixture.deliver(id: intermediateID, text: "This pending reply is replaced.", runID: "run-intermediate")
        fixture.deliver(id: latestID, text: "Only the latest reply should play.", runID: "run-latest")
        let whileHeld = await fixture.preparation.snapshot
        #expect(whileHeld.startedIDs == [firstID], "newer requests coalesce while the sole worker is held")
        #expect(whileHeld.activeWorkers == 1 && whileHeld.maximumActiveWorkers == 1)

        await fixture.preparation.release(firstID)
        let firstFinished = await self.waitForFinish(firstID, fixture: fixture)
        #expect(firstFinished)
        let latestStarted = await self.waitForStart(latestID, fixture: fixture)
        #expect(latestStarted)
        let afterDrain = await fixture.preparation.snapshot
        #expect(afterDrain.startedIDs == [firstID, latestID],
                "the intermediate pending reply is replaced before any second worker starts")
        #expect(afterDrain.maximumActiveWorkers == 1)

        await fixture.preparation.release(latestID)
        let latestFinished = await self.waitForFinish(latestID, fixture: fixture)
        #expect(latestFinished)
        let spokeLatest = await eventually { fixture.speaker.spokenTexts == ["Only the latest reply should play."] }
        #expect(spokeLatest)
        #expect(fixture.controller.activeMessageId == latestID)
    }

    @Test func injectedBlockerIsCheckedAfterPreparationWithoutGlobalAccessibilityMutation() async {
        let id = "blocked-after-await-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-blocked", heldIDs: [id])
        defer { fixture.cleanup() }
        fixture.install()
        fixture.deliver(id: id, text: "This reply becomes blocked while preparing.")
        guard await self.waitForStart(id, fixture: fixture) else {
            #expect(Bool(false), "the accepted reply entered the worker")
            return
        }
        fixture.blocker.isBlocked = true
        await fixture.preparation.release(id)
        let finished = await self.waitForFinish(id, fixture: fixture)
        #expect(finished)
        let idle = await self.waitForAutoReadIdle(fixture)
        #expect(idle)
        let completionCheckedBlocker = fixture.blocker.checkCount >= 2
        #expect(completionCheckedBlocker, "the same injected app-state guard runs after the worker await")
        #expect(fixture.speaker.spokenTexts.isEmpty,
                "VoiceOver or dictation becoming active during preparation prevents playback")
    }

    @Test func acceptedLegacyReplyWithoutTranscriptIDUsesItsFallbackID() async {
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-legacy")
        defer { fixture.cleanup() }
        fixture.install()
        let reply = "A legacy reply without a transcript identifier."
        fixture.chat.handleChat([
            "runId": .string("run-legacy-reply"),
            "sessionKey": .string(fixture.chat.sessionKey),
            "state": .string("final"),
        ])
        fixture.chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string(reply)]],
            ],
        ])
        let fallbackID = fixture.chat.items.last?.id
        let spoken = await eventually { fixture.speaker.spokenTexts == [reply] }
        #expect(spoken)
        #expect(fallbackID != nil && fixture.controller.activeMessageId == fallbackID,
                "legacy accepted replies keep the existing item-ID fallback")
    }

    @Test func aSameIDCallbackSnapshotEditedBeforePreparationIsRejectedOffMain() async {
        let id = "same-id-before-enqueue-\(UUID().uuidString)"
        let fixture = AutoReadFixture(sessionKey: "agent:probe:auto-read-source-check")
        defer { fixture.cleanup() }
        fixture.install()
        let productionCallback = fixture.chat.onFinalAssistantReply
        var deliveredItem: ChatItem?
        fixture.chat.onFinalAssistantReply = { deliveredItem = $0 }
        fixture.chat.handleChat([
            "runId": .string("run-held-callback-source"),
            "sessionKey": .string(fixture.chat.sessionKey),
            "state": .string("final"),
        ])
        fixture.chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string("Old callback body.")]],
                "__openclaw": ["id": .string(id)],
            ],
        ])
        guard let staleItem = deliveredItem else {
            #expect(Bool(false), "the accepted event delivered its source item")
            return
        }
        fixture.chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string("New current body.")]],
                "__openclaw": ["id": .string(id)],
            ],
        ])
        fixture.chat.onFinalAssistantReply = productionCallback
        productionCallback?(staleItem)

        #expect(!fixture.state.autoReadPreparationIsIdle,
                "source equality is checked by a queued background validation")
        let drained = await self.waitForAutoReadIdle(fixture)
        #expect(drained)
        #expect(fixture.preparationObservation.startedIDs.isEmpty,
                "a stale source never reaches the speech preparer")
        #expect(fixture.speaker.spokenTexts.isEmpty)
    }
}
