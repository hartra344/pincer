import Foundation
import PincerKit

// Transcript cache versioning and corruption recovery (issue #57): unit checks against the cache
// folder, an offline chat over a broken cache, and a live chat whose cache file was corrupted.

private func cacheData(version: Int = TranscriptCache.Snapshot.currentVersion, ids: [String]) -> Data {
    let items = ids.enumerated().map { messageItem($0.element, .user, "cached \($0.element)", at: Double($0.offset)) }
    return (try? JSONEncoder().encode(TranscriptCache.Snapshot(version: version, items: items, complete: true, activityMs: 5))) ?? Data()
}

/// Writes raw bytes as the chat's transcript plus a valid `.meta`, under the current cache root.
@discardableResult
private func writeRawCache(_ data: Data, gatewayId: UUID, sessionKey: String, root: URL?) -> URL? {
    guard let url = TranscriptCache.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root),
          (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
          (try? data.write(to: url)) != nil,
          (try? Data(#"{"complete":true,"activityMs":5}"#.utf8).write(to: url.appendingPathExtension("meta"))) != nil
    else { return nil }
    return url
}

private func quarantineCount(_ gatewayId: UUID, root: URL?) -> Int {
    guard let directory = TranscriptCache.quarantineDirectory(gatewayId: gatewayId, root: root) else { return 0 }
    return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).count
}

private func isCorrupt(_ outcome: TranscriptCache.LoadOutcome) -> Bool {
    if case .corrupt = outcome { true } else { false }
}

/// A literal v5 transcript saved before #154 recorded `toolDetails`: `write` overwrote README.md
/// and its result has no details (#168).
private let legacyV5FileEdit = #"""
{"version":5,"complete":true,"activityMs":5,"items":[
 {"id":"lu1","transcriptId":"lu1","role":"user","blocks":[{"text":{"_0":"Tighten the README intro"}}],
  "timestamp":780000000,"isError":false,"isPending":false,"isCapped":false},
 {"id":"la1","transcriptId":"la1","role":"assistant",
  "blocks":[{"toolCall":{"id":"call_w1","name":"write","arguments":"{\"path\":\"README.md\",\"content\":\"# Pincer\\nNative client.\\n\"}"}}],
  "timestamp":780000001,"isError":false,"isPending":false,"isCapped":false},
 {"id":"lr1","transcriptId":"lr1","role":"toolResult","toolCallId":"call_w1","toolName":"write",
  "blocks":[{"text":{"_0":"Successfully wrote 25 bytes to README.md"}}],"timestamp":780000002,
  "isError":false,"isPending":false,"isCapped":false}
]}
"""#

/// An offline chat over that legacy cache: its edit card says "Written", never "New file", and the
/// file is saved back at the current version.
@MainActor
private func checkLegacyV5FileEditChat(_ store: GatewayStore, root: URL?) async {
    let key = "agent:main:legacy-edit"
    let url = writeRawCache(Data(legacyV5FileEdit.utf8), gatewayId: store.id, sessionKey: key, root: root)
    let chat = store.chat(for: key)
    await chat.load()
    let edits = chat.entries.flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools }
        return []
    }.compactMap(\.fileEdit)
    let edit = edits.first
    check(chat.items.map(\.id) == ["lu1", "la1", "lr1"] && edits.count == 1, "legacy v5 chat with a write restores (\(chat.items.count) items)")
    check(edit?.statusLabel == "Written" && edit?.files.first?.operation == .update && edit?.deletionsLabel == nil,
          "legacy v5 overwrite isn't \"New file\" (\(edit?.statusLabel ?? "nil"), \(edit?.accessibilitySummary ?? ""))")
    let saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(saved?["version"] as? Int == TranscriptCache.Snapshot.currentVersion, "legacy v5 file saved back at v\(TranscriptCache.Snapshot.currentVersion)")
}

/// Removing one chat (a deleted or rewound session, #38) drops its transcript, sidecar and search
/// hits, and leaves the Gateway's other chats cached and searchable.
@MainActor
private func checkRemoveOneChat(root: URL?) async {
    let gatewayId = UUID()
    let gone = "agent:main:rewound", kept = "agent:main:kept"
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("g1", .user, "narwhal rewound", at: 1)], complete: true),
                               gatewayId: gatewayId, sessionKey: gone, root: root)
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("k1", .user, "narwhal kept", at: 1)], complete: true),
                               gatewayId: gatewayId, sessionKey: kept, root: root)
    let before = Set(await indexHits(gatewayId, "narwhal", root: root).map(\.sessionKey))
    check(before == [gone, kept], "both chats indexed before removing one (\(before.sorted()))")
    let url = TranscriptCache.file(gatewayId: gatewayId, sessionKey: gone, root: root)
    await TranscriptCache.remove(gatewayId: gatewayId, sessionKey: gone, root: root)
    check(!fileExists(url) && !fileExists(url?.appendingPathExtension("meta")), "remove deletes the chat's transcript and .meta")
    let (_, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: gone, root: root)
    let indexed = await MessageIndex.shared(gatewayId: gatewayId, root: root).isIndexed(sessionKey: gone)
    let after = Set(await indexHits(gatewayId, "narwhal", root: root).map(\.sessionKey))
    check(outcome == .missing && !indexed && after == [kept], "removed chat is gone from cache and search, the other stays (\(after.sorted()))")
    let (other, otherOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: kept, root: root)
    check(otherOutcome == .loaded && other?.items.map(\.id) == ["k1"], "other chat still cached after removing one")
    await TranscriptCache.remove(gatewayId: gatewayId, sessionKey: "agent:main:never", root: root)
    let stillKept = Set(await indexHits(gatewayId, "narwhal", root: root).map(\.sessionKey))
    check(stillKept == [kept], "removing an uncached chat is a no-op")
    TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
}

/// The search index heals when its file is deleted from under it (system cache purge), and
/// saves racing Clear Cache don't leave it dead (#153).
@MainActor
private func checkIndexSurvivesDeletedFiles(root: URL?) async {
    let gatewayId = UUID(), key = "agent:main:purged"
    let snapshot = TranscriptCache.Snapshot(items: [messageItem("p1", .user, "quokka survives", at: 1)], complete: true)
    await TranscriptCache.save(snapshot, gatewayId: gatewayId, sessionKey: key, root: root)
    let indexed = await indexHits(gatewayId, "quokka", root: root).count
    check(indexed == 1, "indexed before its file is purged (\(indexed))")
    if let url = MessageIndex.url(gatewayId: gatewayId, root: root) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path(percentEncoded: false) + suffix) }
    }
    // The open connection now fails (SQLITE_IOERR_VNODE); that resets the index, and the next save
    // or reconcile rebuilds it instead of every search failing until relaunch.
    for _ in 0..<3 { _ = try? await MessageIndex.shared(gatewayId: gatewayId, root: root).search("quokka") }
    await MessageIndex.shared(gatewayId: gatewayId, root: root).reconcile(sessionKeys: [key])
    let healed = await indexHits(gatewayId, "quokka", root: root).count
    check(healed == 1, "index rebuilt after its file was deleted while open (\(healed))")

    // Saves racing Clear Cache: afterwards a save is indexed and found.
    for round in 0..<5 {
        let saves = Task {
            for n in 0..<20 {
                await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("r\(n)", .user, "racing \(round)", at: 1)],
                                                                    complete: true), gatewayId: gatewayId, sessionKey: "agent:main:race", root: root)
            }
        }
        // Deliberate: lets some saves start so Clear Cache lands mid-stream (the race under test).
        try? await Task.sleep(for: .milliseconds(2))
        TranscriptCache.removeEverything(root: root)
        await saves.value
    }
    await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("after", .user, "platypus after racing", at: 1)],
                                                        complete: true), gatewayId: gatewayId, sessionKey: key, root: root)
    let afterRace = await indexHits(gatewayId, "platypus", root: root).count
    check(afterRace == 1, "saves racing Clear Cache leave a working index (\(afterRace) hits)")
    TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
}

@MainActor
func checkTranscriptCacheVersioning() async {
    print("Transcript cache versioning")
    await withScratchCache { root in
        let gatewayId = UUID()
        let current = TranscriptCache.Snapshot.currentVersion

        let (none, missing) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "missing", root: root)
        check(none == nil && missing == .missing && !missing.discarded, "no file → missing")

        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("a", .user, "hello", at: 1)], complete: true),
                                   gatewayId: gatewayId, sessionKey: "ok", root: root)
        let (loaded, loadedOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "ok", root: root)
        check(loadedOutcome == .loaded && loaded?.items.map(\.id) == ["a"], "current version round-trips")

        let old = writeRawCache(cacheData(version: current - 1, ids: ["o"]), gatewayId: gatewayId, sessionKey: "old", root: root)
        let (_, oldOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "old", root: root)
        let oldExpected: Bool = if case .migrated(from: current - 1) = oldOutcome { true } else { oldOutcome == .outdated(version: current - 1) }
        check(oldExpected, "v\(current - 1) file → migrated or outdated (\(oldOutcome))")
        if case .outdated = oldOutcome {
            check(!fileExists(old) && !fileExists(old?.appendingPathExtension("meta")), "outdated file and .meta deleted")
        }
        let ancient = writeRawCache(cacheData(version: 1, ids: ["x"]), gatewayId: gatewayId, sessionKey: "ancient", root: root)
        let (_, ancientOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "ancient", root: root)
        check(ancientOutcome == .outdated(version: 1) && !fileExists(ancient), "v1 file → outdated, deleted")

        let future = writeRawCache(cacheData(version: current + 1, ids: ["f"]), gatewayId: gatewayId, sessionKey: "future", root: root)
        let (futureSnapshot, futureOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "future", root: root)
        check(futureSnapshot == nil && futureOutcome == .future(version: current + 1) && futureOutcome.discarded,
              "newer file → future (\(futureOutcome))")
        check(!fileExists(future) && !fileExists(future?.appendingPathExtension("meta")), "future file and .meta discarded")
        check(quarantineCount(gatewayId, root: root) == 0, "outdated and future files deleted, not quarantined")

        let corruptCases: [(String, Data)] = [
            ("garbage", Data("🦞 not json".utf8)),
            ("zero-byte", Data()),
            ("truncated", cacheData(ids: (0..<10).map { "t\($0)" }).prefix(60)),
            ("wrong shape", Data(#"{"version":\#(current),"items":42,"complete":true}"#.utf8)),
        ]
        for (index, (label, data)) in corruptCases.enumerated() {
            let key = "corrupt-\(index)"
            let url = writeRawCache(data, gatewayId: gatewayId, sessionKey: key, root: root)
            let (snapshot, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: key, root: root)
            check(snapshot == nil && isCorrupt(outcome) && outcome.discarded, "\(label) → corrupt (\(outcome))")
            check(!fileExists(url) && !fileExists(url?.appendingPathExtension("meta")), "\(label) moved out, .meta removed")
            check(quarantineCount(gatewayId, root: root) == index + 1, "\(label) quarantined (\(quarantineCount(gatewayId, root: root)))")
        }
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("n", .user, "new", at: 1)], complete: true),
                                   gatewayId: gatewayId, sessionKey: "corrupt-0", root: root)
        let (again, againOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "corrupt-0", root: root)
        check(againOutcome == .loaded && again?.items.map(\.id) == ["n"], "save + load work after corruption")

        for index in 0..<10 {
            writeRawCache(Data("junk \(index)".utf8), gatewayId: gatewayId, sessionKey: "bulk-\(index)", root: root)
            _ = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "bulk-\(index)", root: root)
        }
        check(quarantineCount(gatewayId, root: root) <= 5 && quarantineCount(gatewayId, root: root) > 0, "quarantine is bounded (\(quarantineCount(gatewayId, root: root)))")

        // The message index skips a corrupt transcript and still indexes the healthy ones.
        let indexed = UUID()
        writeRawCache(Data("junk".utf8), gatewayId: indexed, sessionKey: "bad", root: root)
        _ = writeCacheFile(TranscriptCache.Snapshot(items: [messageItem("w1", .user, "wombat survives", at: 1)], complete: true),
                           gatewayId: indexed, sessionKey: "good", root: root)
        await MessageIndex.shared(gatewayId: indexed, root: root).reconcile(sessionKeys: ["bad", "good"])
        await checkAsync({ await indexHits(indexed, "wombat", root: root).count == 1 }, "index reconcile skips a corrupt transcript")
        // A decodable transcript sitting in Quarantine is never read back or indexed.
        if let quarantine = TranscriptCache.quarantineDirectory(gatewayId: indexed, root: root) {
            try? cacheData(ids: ["q"]).write(to: quarantine.appending(path: "stray-1.json"))
        }
        await MessageIndex.shared(gatewayId: indexed, root: root).reconcile(sessionKeys: ["good"])
        let strayHits = await indexHits(indexed, "cached", root: root)
        check(strayHits.isEmpty, "Quarantine is never indexed (\(strayHits.count) hits)")
        TranscriptCache.removeAll(gatewayId: indexed, root: root)

        // A chat over a corrupt cache, offline: nothing shown, and it isn't marked loaded. (Not
        // agent:main:main: an offline store's chat on that key upsets the later live checks.)
        // GatewayStore reads TranscriptCache.root itself and takes no root, so this part points
        // PINCER_CACHE_DIR at the scratch root.
        await withCacheEnvironment(root.path(percentEncoded: false)) {
            let profile = GatewayProfile(name: "Offline cache", url: "ws://127.0.0.1:1", authMode: .none)
            let store = GatewayStore(profile: profile)
            writeRawCache(Data("{\"version\":\(current),\"items\":[".utf8), gatewayId: store.id, sessionKey: "agent:main:broken", root: root)
            let broken = store.chat(for: "agent:main:broken")
            await broken.load()
            check(broken.items.isEmpty && !broken.hasLoaded, "offline chat over a corrupt cache shows nothing, not loaded")
            check(quarantineCount(store.id, root: root) == 1, "offline chat quarantined its corrupt cache")
            _ = writeCacheFile(TranscriptCache.Snapshot(items: [messageItem("c1", .user, "cached hi", at: 1)], complete: true),
                               gatewayId: store.id, sessionKey: "agent:main:other", root: root)
            let healthy = store.chat(for: "agent:main:other")
            await healthy.load()
            check(healthy.items.map(\.id) == ["c1"], "offline chat over a healthy cache restores it")
            await checkLegacyV5FileEditChat(store, root: root)
            TranscriptCache.removeAll(gatewayId: store.id, root: root)
        }

        // Clear cache.
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("u", .user, String(repeating: "x", count: 4096), at: 1)],
                                                            complete: true), gatewayId: gatewayId, sessionKey: "usage", root: root)
        let usage = await TranscriptCache.diskUsage(root: root)
        check(usage >= 4096, "diskUsage counts the cache (\(usage) bytes)")
        TranscriptCache.removeEverything(root: root)
        let cleared = await TranscriptCache.diskUsage(root: root)
        let gone = await TranscriptCache.load(gatewayId: gatewayId, sessionKey: "usage", root: root)
        check(cleared == 0 && gone == nil, "removeEverything empties the cache (\(cleared) bytes left)")
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [messageItem("z", .user, "zebra after clear", at: 1)], complete: true),
                                   gatewayId: gatewayId, sessionKey: "after", root: root)
        let (_, afterOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: "after", root: root)
        check(afterOutcome == .loaded, "cache usable after removeEverything")
        // Awaited flush: every write and index update queued so far has landed, so no polling.
        await TranscriptCache.flush(gatewayId: gatewayId, root: root)
        let zebraHits = await indexHits(gatewayId, "zebra", root: root).count
        check(zebraHits == 1, "search index rebuilt after removeEverything (\(zebraHits) hits, \(await MessageIndex.shared(gatewayId: gatewayId, root: root).status))")
        await checkRemoveOneChat(root: root)
        await checkIndexSurvivesDeletedFiles(root: root)
        TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
    }

    // Cache off (a nil root): nothing to measure, clear, load or quarantine.
    let offUsage = await TranscriptCache.diskUsage(root: nil)
    TranscriptCache.removeEverything(root: nil)
    let (offSnapshot, offOutcome) = await TranscriptCache.loadWithOutcome(gatewayId: UUID(), sessionKey: "k", root: nil)
    check(offUsage == 0 && offSnapshot == nil && offOutcome == .missing
          && TranscriptCache.quarantineDirectory(gatewayId: UUID(), root: nil) == nil, "cache off: usage 0, clear no-op, no quarantine")

    await withScratchCache { root in await checkSegmentedCache(root: root) }
}

/// v8 (#199): a v7 single file migrates to manifest + segments, an unchanged save writes nothing,
/// an unreadable file is kept (never quarantined), a missing segment is corrupt.
@MainActor
private func checkSegmentedCache(root: URL?) async {
    let gatewayId = UUID()
    let key = "agent:main:segmented"
    let ids = (0..<600).map { "s\($0)" }
    guard let url = TranscriptCache.file(gatewayId: gatewayId, sessionKey: key, root: root) else { return check(false, "cache root for v8 checks") }
    let segments = url.deletingPathExtension().appendingPathExtension("segments")
    let legacy = cacheData(version: 7, ids: ids)
    writeRawCache(legacy, gatewayId: gatewayId, sessionKey: key, root: root)

    let (migrated, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: key, root: root)
    check(outcome == .migrated(from: 7) && migrated?.items.map(\.id) == ids, "v7 single file migrates to the current version (\(outcome))")
    let saved = await waitFor("v7 saved back as v8", timeout: 5) { (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["version"] as? Int == TranscriptCache.Snapshot.currentVersion }
    check(saved && fileExists(segments), "migrated v7 saved back as a manifest with segments")

    let snapshot = TranscriptCache.Snapshot(items: migrated?.items ?? [], complete: true, activityMs: 5)
    let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    let again = await TranscriptCache.saveReturningStats(snapshot, gatewayId: gatewayId, sessionKey: key, root: root)
    let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    check(again.unchanged && again.bytesWritten == 0 && mtime == mtimeAfter, "identical save writes nothing (\(again.bytesWritten) bytes)")

    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    let (_, locked) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: key, root: root)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let deniedReads = !FileManager.default.isReadableFile(atPath: url.path) || { if case .unavailable = locked { true } else { false } }()
    check(deniedReads && !locked.discarded && quarantineCount(gatewayId, root: root) == 0, "unreadable manifest is unavailable, not quarantined (\(locked))")

    if let first = (try? FileManager.default.contentsOfDirectory(atPath: segments.path))?.first {
        try? FileManager.default.removeItem(at: segments.appendingPathComponent(first))
        let (_, missing) = await TranscriptCache.loadWithOutcome(gatewayId: gatewayId, sessionKey: key, root: root)
        check(isCorrupt(missing) && quarantineCount(gatewayId, root: root) == 1, "missing segment → corrupt, quarantined (\(missing))")
    }
    TranscriptCache.removeAll(gatewayId: gatewayId, root: root)
}

/// Live: a chat whose cache file was corrupted between launches still loads its history.
@MainActor
func runLiveCacheRecovery(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock cache", url: url, authMode: .token)
    profile.secret = token
    let key = "agent:main:main"

    let first = GatewayStore(profile: profile)
    first.start()
    guard await waitFor("cache connect", timeout: 25, { first.state.isConnected && !first.sessions.isEmpty }) else {
        return check(false, "connected for the cache check")
    }
    let chat = first.chat(for: key)
    await chat.load()
    _ = await waitFor("history") { chat.hasLoaded }
    let expected = chat.items.map(\.id)
    check(!expected.isEmpty, "history loaded (\(expected.count) items)")
    let saved = await waitFor("cache written", timeout: 10) { fileExists(TranscriptCache.file(gatewayId: profile.id, sessionKey: key)) }
    check(saved, "transcript cached")
    await first.stopAndFlushCache()

    // Between launches: the file is torn in half.
    guard let file = TranscriptCache.file(gatewayId: profile.id, sessionKey: key),
          let data = try? Data(contentsOf: file), (try? data.prefix(data.count / 2).write(to: file)) != nil
    else { return check(false, "corrupted the cache file") }
    let before = quarantineCount(profile.id, root: TranscriptCache.root)

    let second = GatewayStore(profile: profile)
    second.start()
    defer {
        second.stop()
        TranscriptCache.removeAll(gatewayId: profile.id)
    }
    guard await waitFor("cache reconnect", timeout: 25, { second.state.isConnected && !second.sessions.isEmpty }) else {
        return check(false, "reconnected for the cache check")
    }
    let reopened = second.chat(for: key)
    await reopened.load()
    let recovered = await waitFor("history after corruption") { reopened.hasLoaded && !reopened.items.isEmpty }
    check(recovered, "corrupt cache → history still loads from the Gateway (\(reopened.items.count) items)")
    check(Set(expected).isSubset(of: Set(reopened.items.map(\.id))), "same transcript as before the corruption")
    check(quarantineCount(profile.id, root: TranscriptCache.root) == before + 1, "corrupt cache file quarantined")
    let rewritten = await waitFor("cache rewritten", timeout: 10) {
        (try? Data(contentsOf: file)).map { !$0.isEmpty && $0.count >= data.count / 2 + 1 } ?? false
    }
    let (_, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: profile.id, sessionKey: key)
    check(rewritten && outcome == .loaded, "cache rewritten after recovery (\(outcome))")
}

/// Live: Clear Cache empties the disk, keeps open chats on screen, and the cache refills (open
/// chats saved again at once, the rest by the background prefetch) without a relaunch.
@MainActor
func runLiveCacheRefill(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let model = AppModel(defaults: defaults)
    model.appIsActive = true
    let profile = GatewayProfile(name: "Mock refill", url: url, authMode: .token)
    let gateway = model.add(profile, secret: token)
    defer {
        model.remove(gateway.id)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    guard await waitFor("refill connect", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }) else {
        return check(false, "connected for the refill check")
    }
    let key = "agent:main:main"
    let chat = gateway.chat(for: key)
    await chat.load()
    _ = await waitFor("history") { chat.hasLoaded }
    let shown = chat.items.map(\.id)
    let others = gateway.sessions.values.filter { !$0.isSubagent && $0.key != key }.map(\.key)
    func cachedOthers() -> Int { others.filter { fileExists(TranscriptCache.file(gatewayId: gateway.id, sessionKey: $0)) }.count }
    let filled = await waitFor("prefetch fills the cache", timeout: 30) {
        fileExists(TranscriptCache.file(gatewayId: gateway.id, sessionKey: key)) && cachedOthers() > 0
    }
    check(filled && !shown.isEmpty, "cache filled before clearing (\(cachedOthers()) other chats)")
    let before = await TranscriptCache.diskUsage()

    await model.clearTranscriptCache()
    check(chat.items.map(\.id) == shown, "open chat keeps its transcript after Clear Cache")
    let (reSaved, outcome) = await TranscriptCache.loadWithOutcome(gatewayId: gateway.id, sessionKey: key)
    check(outcome == .loaded && reSaved?.items.map(\.id) == shown, "open chat saved again right after clearing (\(outcome))")
    // Clearing returns once the open chat is saved again and indexed (#153).
    let reIndexed = await gateway.messageIndex.isIndexed(sessionKey: key)
    check(reIndexed, "open chat indexed again right after clearing")
    let usageAfter = await TranscriptCache.diskUsage()
    check(usageAfter < before, "Clear Cache freed space (\(before) → \(usageAfter) bytes)")
    let quarantine = TranscriptCache.quarantineDirectory(gatewayId: gateway.id)
    check(!fileExists(quarantine), "no Quarantine left after clearing")
    let refilled = await waitFor("prefetch refills", timeout: 30) { cachedOthers() > 0 }
    check(refilled, "background prefetch refills other chats after clearing (\(cachedOthers()))")
    let term = chat.items.last { !$0.plainText.isEmpty && $0.plainText.count > 8 }?.plainText
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first { $0.count >= 5 }.map(String.init)
    if let term {
        let found = await waitForSearch(gateway, term, timeout: 15) { $0.chats.contains { $0.sessionKey == key } }
        check(found != nil, "search finds the open chat again after clearing (“\(term)”)")
    }
}
