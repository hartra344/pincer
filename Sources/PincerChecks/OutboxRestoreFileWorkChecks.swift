#if DEBUG
import Foundation
@testable import PincerKit

private actor OutboxRestoreDelivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
}


@MainActor private func checkOutboxRestoreFiles(profile: GatewayProfile, connect: Bool) async {
    let (defaults, suite) = scratchDefaults()
    let root = FileManager.default.temporaryDirectory.appending(path: "pincer-check-outbox-restore-" + UUID().uuidString, directoryHint: .isDirectory)
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    gateway.cacheRoot = nil; gateway.outboxRoot = root; gateway.notifier = nil
    defer { gateway.stop(); defaults.removePersistentDomain(forName: suite) }
    let key = "agent:main:main", date = Date(timeIntervalSince1970: 1_800_000_000)
    let present = OutboxAttachmentRef(id: UUID(), fileName: "note.txt", mimeType: "text/plain", byteCount: 4)
    let missing = OutboxAttachmentRef(id: UUID(), fileName: "missing.txt", mimeType: "text/plain", byteCount: 4)
    let queued = OutboxEntry(id: "restore-queued", sessionKey: key, text: "queued", createdAt: date, attachments: [present])
    let absent = OutboxEntry(id: "restore-missing", sessionKey: key, text: "missing", createdAt: date, attachments: [missing])
    let interrupted = OutboxEntry(id: "restore-sending", sessionKey: key, text: "interrupted", createdAt: date, state: .sending, attempts: 2)
    var saved = Outbox(); saved.enqueue(queued); saved.enqueue(absent); saved.enqueue(interrupted)
    let savedFixture = saved
    do {
    try await Task.detached {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(OutboxStore.Envelope(version: OutboxStore.currentVersion, outbox: savedFixture))
        try data.write(to: OutboxStore.file(gatewayId: profile.id, root: root)!, options: .atomic)
        let file = OutboxAttachmentStore.fileURL(gatewayId: profile.id, entryId: queued.id, attachmentId: present.id, root: root)!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("note".utf8).write(to: file, options: .atomic)
    }.value

    } catch {
        check(false, "real outbox disk fixture setup completes")
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
        return
    }
    let fixtureRead = await OutboxStore.load(gatewayId: profile.id, root: root)
    guard fixtureRead.outcome == .loaded && fixtureRead.outbox == savedFixture else {
        check(false, "actual fixture decodes to exact saved entries before restore admission")
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
        return
    }
    check(true, "actual fixture decodes to exact saved entries")
    let delivery = OutboxRestoreDelivery(), probe = OutboxRestoreFileScanProbe()
    gateway.outboxRestoreReadDelivery = { await delivery.hold() }
    gateway.outboxRestoreFileScan = { probe.record(onMain: $0) }
    let loading: Task<Void, Never>
    if connect {
        gateway.start(); gateway.reconnectIfNeeded()
        guard let task = gateway.outboxLoadTask else {
            check(false, "actual start owns its outbox restore task")
            await delivery.release(); await gateway.connection.stop()
            await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            return
        }
        loading = task
    } else { loading = Task { await gateway.loadOutbox() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var admitted = await delivery.entered
    while !admitted && !Task.isCancelled && ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        admitted = await delivery.entered
    }
    var ready = admitted
    if connect && ready {
        ready = await waitFor("actual fresh mock outbox connection", timeout: 25) { gateway.state.isConnected && gateway.hello != nil }
        check(ready, "actual fresh mock connection is ready while real read is held")
        // Restore while offline so queued messages remain available instead of auto-delivering.
        // This is an actual transport disconnect, not a fabricated connected flag.
        await gateway.connection.stop()
        let disconnected = await waitFor("actual transport disconnect before restored queue publication", timeout: 15) { !gateway.state.isConnected }
        ready = ready && disconnected
    }
    guard ready else {
        check(false, "actual decoded outbox delivery was admitted")
        loading.cancel(); await delivery.release(); await loading.value
        await gateway.connection.stop()
        await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
        return
    }
    check(gateway.outbox.isEmpty, "held actual read has not published saved entries")
    let newEntry = OutboxEntry(id: "composed-during-read", sessionKey: key, text: "new", createdAt: date.addingTimeInterval(1))
    gateway.injectOutboxEntry(newEntry)
    await delivery.release(); await loading.value
    check(gateway.outbox.entries.map(\.id) == [queued.id, absent.id, interrupted.id, newEntry.id], "saved entries and new composition retain exact order")
    check(gateway.outbox.entry(id: queued.id) == queued && gateway.outbox.entry(id: newEntry.id) == newEntry, "valid saved attachment and new entry retained exactly")
    var recovered = interrupted; recovered.state = .queued
    check(gateway.outbox.entry(id: interrupted.id) == recovered, "actual interrupted send recovers to exact queued entry")
    let expectedFailure = "Couldn’t send: the attachments are no longer available. Delete this message and attach them again."
    var rejected = absent; rejected.state = .failed(OutboxFailure(message: expectedFailure, retryable: false))
    check(gateway.outbox.entry(id: absent.id) == rejected, "missing attachment produces exact non-retryable failed entry")
    let counts = probe.counts()
    check(counts.main == 0 && counts.worker == 2, "actual restore filesystem validation runs off Main")
    gateway.outboxRestoreReadDelivery = nil; gateway.outboxRestoreFileScan = nil
    gateway.stop(); await gateway.connection.stop()
    await OutboxStore.flushWrites(gatewayId: profile.id, root: root)
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
@MainActor func runOutboxRestoreFileWorkChecks() async {
    await checkOutboxRestoreFiles(profile: GatewayProfile(name: "Offline disk restore", url: "ws://127.0.0.1:1", authMode: .none), connect: false)
}
@MainActor func runLiveOutboxRestoreFileWorkChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock disk restore", url: url, authMode: .token)
    profile.secret = token
    await checkOutboxRestoreFiles(profile: profile, connect: true)
}
#endif
