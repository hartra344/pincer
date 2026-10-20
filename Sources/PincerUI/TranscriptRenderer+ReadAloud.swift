import Observation
import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension TranscriptRenderer {
    func canReadAloud(_ messageId: String) -> Bool {
        guard let item = self.context.chat?.message(withId: messageId), item.role == .assistant,
              !item.isPending, !item.isError,
              let entry = self.speechCache.value(messageID: messageId) else { return false }
        return entry.isEligible
    }

    func canReadAloud(_ messageId: String, rowID: String) -> Bool {
        guard let chat = self.context.chat,
              let item = chat.message(withId: messageId),
              item.role == .assistant, !item.isPending, !item.isError,
              let entry = self.cache[rowID], !entry.invalidated else {
            self.invalidateSpeechReadiness(for: [messageId])
            return false
        }
        let row = entry.layout
        if let prepared = self.speechCache.value(messageID: messageId) {
            return prepared.isEligible
        }
        self.queueSpeechPreparation(item, chat: chat, messageID: messageId, rowID: rowID,
                                    layoutSerial: row.serial, startPlayback: false)
        return false
    }

    func isReadingAloud(_ messageId: String) -> Bool { ReadAloudController.shared.isActive(messageId) }

    func readAloud(_ messageId: String) {
        let controller = ReadAloudController.shared
        if controller.isActive(messageId) { return controller.stop() }
        guard let item = self.context.chat?.message(withId: messageId), item.role == .assistant,
              !item.isPending, !item.isError,
              let value = self.speechCache.value(messageID: messageId), value.isEligible,
              let text = value.speechText,
              value.sourceRevision == self.context.chat?.contentRevision else { return }
        controller.start(messageId: messageId, text: text, gateway: self.context.gateway.voice)
    }

    func readAloud(_ messageId: String, rowID: String) {
        let controller = ReadAloudController.shared
        if controller.isActive(messageId) { controller.stop(); return }
        guard let chat = self.context.chat,
              let item = chat.message(withId: messageId),
              item.role == .assistant, !item.isPending, !item.isError,
              let entry = self.cache[rowID], !entry.invalidated else { return }
        let row = entry.layout
        if let value = self.speechCache.value(messageID: messageId) {
            if !value.isEligible, value.sourceRevision == chat.contentRevision { return }
            if value.isEligible, value.sourceRevision == chat.contentRevision, let text = value.speechText {
                controller.start(messageId: messageId, text: text, gateway: self.context.gateway.voice)
                return
            }
        }
        self.queueSpeechPreparation(item, chat: chat, messageID: messageId, rowID: rowID,
                                    layoutSerial: row.serial, startPlayback: true)
    }

    private func queueSpeechPreparation(_ item: ChatItem, chat: ChatStore, messageID: String,
                                        rowID: String, layoutSerial: Int, startPlayback: Bool) {
        if var job = self.speechJobs[messageID] {
            job.rowID = rowID
            job.layoutSerial = layoutSerial
            job.shouldStartPlayback = job.shouldStartPlayback || startPlayback
            self.speechJobs[messageID] = job
            return
        }
        // A visible transcript can be long; bound both the number of retained item snapshots and
        // the number of actor waiters created by a single renderer.
        guard self.speechWorkerCount < 16 else {
            self.deferSpeechPreparation(messageID: messageID, rowID: rowID,
                                        layoutSerial: layoutSerial, startPlayback: startPlayback)
            return
        }
        let token = self.speechCache.begin(messageID: messageID)
        let revision = chat.contentRevision
        #if DEBUG
        let probe = self.speechPreparationProbe
        let gate = self.speechPreparationGate
        #endif
        self.speechWorkerCount += 1
        let task = Task { [weak self, weak chat] in
            #if DEBUG
            let prepared = await Self.speechPreparationWorker.prepare(item, probe: probe, gate: gate)
            #else
            let prepared = await Self.speechPreparationWorker.prepare(item, probe: nil)
            #endif
            guard let self else { return }
            self.speechWorkerCount = max(0, self.speechWorkerCount - 1)
            guard !Task.isCancelled, let prepared, let chat else {
                self.drainPendingSpeechPreparations()
                return
            }
            self.finishSpeechPreparation(prepared, token: token, messageID: messageID,
                                         chat: chat, sourceRevision: revision)
        }
        self.speechJobs[messageID] = SpeechJob(token: token, rowID: rowID, layoutSerial: layoutSerial,
                                               chat: chat, shouldStartPlayback: startPlayback, task: task)
    }

    private func deferSpeechPreparation(messageID: String, rowID: String, layoutSerial: Int,
                                        startPlayback: Bool) {
        if var pending = self.pendingSpeechPreparations[messageID] {
            pending.rowID = rowID
            pending.layoutSerial = layoutSerial
            pending.shouldStartPlayback = pending.shouldStartPlayback || startPlayback
            self.pendingSpeechPreparations[messageID] = pending
            return
        }
        guard self.pendingSpeechPreparations.count < Self.layoutCacheLimit else { return }
        self.nextPendingSpeechOrderToken &+= 1
        let token = self.nextPendingSpeechOrderToken
        self.pendingSpeechPreparations[messageID] = PendingSpeechPreparation(
            rowID: rowID, layoutSerial: layoutSerial, shouldStartPlayback: startPlayback,
            orderToken: token)
        self.pendingSpeechOrder.append(PendingSpeechOrderEntry(messageID: messageID, token: token))
        self.compactPendingSpeechOrderIfNeeded()
    }

    private func drainPendingSpeechPreparations() {
        guard let chat = self.context.chat else {
            self.pendingSpeechPreparations.removeAll()
            self.pendingSpeechOrder.removeAll()
            self.pendingSpeechHead = 0
            return
        }
        while self.speechWorkerCount < 16, self.pendingSpeechHead < self.pendingSpeechOrder.count {
            let pendingOrder = self.pendingSpeechOrder[self.pendingSpeechHead]
            self.pendingSpeechHead += 1
            let messageID = pendingOrder.messageID
            guard let pending = self.pendingSpeechPreparations[messageID],
                  pending.orderToken == pendingOrder.token else { continue }
            self.pendingSpeechPreparations[messageID] = nil
            guard
                  let entry = self.cache[pending.rowID], !entry.invalidated,
                  entry.layout.serial == pending.layoutSerial,
                  entry.layout.messages.contains(where: { $0.id == messageID }),
                  let item = chat.message(withId: messageID), item.role == .assistant,
                  !item.isPending, !item.isError else { continue }
            self.queueSpeechPreparation(item, chat: chat, messageID: messageID, rowID: pending.rowID,
                                        layoutSerial: pending.layoutSerial,
                                        startPlayback: pending.shouldStartPlayback)
        }
        self.compactPendingSpeechOrderIfNeeded()
    }

    func compactPendingSpeechOrderIfNeeded() {
        if self.pendingSpeechPreparations.isEmpty {
            self.pendingSpeechOrder.removeAll(keepingCapacity: true)
            self.pendingSpeechHead = 0
            return
        }
        if self.pendingSpeechHead > 64, self.pendingSpeechHead * 2 >= self.pendingSpeechOrder.count {
            self.pendingSpeechOrder.removeFirst(self.pendingSpeechHead)
            self.pendingSpeechHead = 0
        }
        if self.pendingSpeechOrder.count > Self.layoutCacheLimit * 2 {
            self.pendingSpeechOrder = self.pendingSpeechOrder.dropFirst(self.pendingSpeechHead).filter { entry in
                self.pendingSpeechPreparations[entry.messageID]?.orderToken == entry.token
            }
            self.pendingSpeechHead = 0
        }
    }

    private func finishSpeechPreparation(_ prepared: SpeechEligibilityCache.Prepared,
                                         token: SpeechEligibilityCache.Token, messageID: String,
                                         chat: ChatStore,
                                         sourceRevision: Int) {
        guard let job = self.speechJobs[messageID], job.token == token else { return }
        self.speechJobs[messageID] = nil
        defer { self.drainPendingSpeechPreparations() }
        guard job.chat === chat else { return }
        let rowID = job.rowID
        let layoutSerial = job.layoutSerial
        guard self.context.chat === chat, let current = chat.message(withId: messageID),
              let rowEntry = self.cache[rowID], !rowEntry.invalidated else {
            self.speechCache.invalidate(messageID: messageID)
            return
        }
        guard rowEntry.layout.serial == layoutSerial else {
            self.speechCache.invalidate(messageID: messageID)
            if rowEntry.layout.messages.contains(where: { $0.id == messageID }) {
                self.queueSpeechPreparation(current, chat: chat, messageID: messageID, rowID: rowID,
                                            layoutSerial: rowEntry.layout.serial,
                                            startPlayback: job.shouldStartPlayback)
            }
            return
        }
        guard chat.contentRevision == sourceRevision else {
            self.speechCache.invalidate(messageID: messageID)
            if let current = chat.message(withId: messageID),
               let currentRow = self.cache[rowID]?.layout,
               currentRow.messages.contains(where: { $0.id == messageID }) {
                self.queueSpeechPreparation(current, chat: chat, messageID: messageID, rowID: rowID,
                                            layoutSerial: currentRow.serial,
                                            startPlayback: job.shouldStartPlayback)
            }
            return
        }
        guard self.speechCache.complete(token, with: prepared, sourceRevision: sourceRevision) else { return }
        // Readiness changes a button's visibility, not packed geometry. Advance only the cached
        // layout token so native cells reconfigure without rebuilding or measuring the body.
        guard let readySerial = self.advanceReadinessLayoutSerial(rowID: rowID) else { return }
        // Other preparations in the same row should finish against the token the cell now expects.
        let jobIDs = self.speechJobs.compactMap { $0.value.rowID == rowID ? $0.key : nil }
        for id in jobIDs {
            self.speechJobs[id]?.layoutSerial = readySerial
        }
        let pendingIDs = self.pendingSpeechPreparations.compactMap { $0.value.rowID == rowID ? $0.key : nil }
        for id in pendingIDs {
            self.pendingSpeechPreparations[id]?.layoutSerial = readySerial
        }
        self.onInvalidate?(Set([rowID]), nil)
        guard job.shouldStartPlayback, prepared.isEligible, let text = prepared.speechText,
              chat.contentRevision == sourceRevision, self.context.chat === chat else { return }
        ReadAloudController.shared.start(messageId: messageID, text: text, gateway: self.context.gateway.voice)
    }

    private func advanceReadinessLayoutSerial(rowID: String) -> Int? {
        guard var entry = self.cache[rowID], !entry.invalidated else { return nil }
        self.serial += 1
        entry.layout.serial = self.serial
        self.cache[rowID] = entry
        return self.serial
    }
}
