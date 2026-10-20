import Foundation
import Observation

extension ChatStore {
    /// Brings the on-disk cache up to date with the full history, without touching the UI.
    /// `generation` is the cache generation this fill started under; a rewind or delete since
    /// then makes it discard what it fetched instead of saving it.
    func fillCache(generation: Int? = nil, connectionEpoch expectedConnectionEpoch: Int? = nil) async {
        guard let gateway else {
#if DEBUG
            if self.forwardedSenderRefreshPending {
                self.recordForwardedRefreshAbort(.gatewayChanged, offset: 0, scanned: 0)
            }
#endif
            return
        }
        let connectionEpoch = expectedConnectionEpoch ?? gateway.connectionEpoch
        await self.restoreFromCache()
#if DEBUG
        let expectedGeneration = generation ?? gateway.cacheGeneration(of: self.sessionKey)
        let refreshForwardedSenders = self.forwardedSenderRefreshPending
        if refreshForwardedSenders {
            ForwardedSenderRefreshDiagnostics.record(
                gatewayID: self.gatewayId, sessionKey: self.sessionKey,
                phase: .fillStarted(epoch: connectionEpoch, generation: expectedGeneration, cachedRows: self.items.count))
            if self.cacheUnreadable {
                self.recordForwardedRefreshAbort(.cacheUnreadable, offset: 0, scanned: 0)
                return
            }
            if !gateway.state.isConnected {
                self.recordForwardedRefreshAbort(.disconnected, offset: 0, scanned: 0)
                return
            }
            if gateway.connectionEpoch != connectionEpoch {
                self.recordForwardedRefreshAbort(.connectionEpochChanged, offset: 0, scanned: 0)
                return
            }
        } else {
            guard !self.cacheUnreadable, gateway.state.isConnected,
                  gateway.connectionEpoch == connectionEpoch
            else { return }
        }
#else
        guard !self.cacheUnreadable, gateway.state.isConnected,
              gateway.connectionEpoch == connectionEpoch
        else { return }
        let expectedGeneration = generation ?? gateway.cacheGeneration(of: self.sessionKey)
        let refreshForwardedSenders = self.forwardedSenderRefreshPending
#endif
        // `apply(history:)` can discard cached history when the newest page has no overlap. Keep
        // the complete restored snapshot for reconciliation until the authoritative scan finishes.
        let restoredCacheItems = refreshForwardedSenders ? self.items : []
        var params = self.params(keyName: "sessionKey")
        params["limit"] = .number(Double(self.historyLimit))
        if refreshForwardedSenders { self.recordForwardedRefresh(.request(offset: 0, limit: self.historyLimit, scanned: 0)) }
        let result: JSONValue
        do {
            result = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
        } catch {
            if refreshForwardedSenders { self.recordForwardedRefreshAbort(.requestFailed, offset: 0, scanned: 0) }
            return
        }
        let receivedFirstPage = result["messages"]?.array
        let firstPageDisposition = Self.forwardedRefreshPageDisposition(
            messageCount: receivedFirstPage?.count, reportedHasMore: result["hasMore"]?.bool,
            requestedOffset: 0, returnedOffset: result["nextOffset"]?.int,
            fallbackLimit: self.historyLimit)
        if refreshForwardedSenders {
            self.recordForwardedRefresh(.page(offset: 0, limit: self.historyLimit,
                                              messageCount: receivedFirstPage?.count,
                                              hasMore: result["hasMore"]?.bool,
                                              nextOffset: result["nextOffset"]?.int,
                                              disposition: Self.diagnosticDisposition(firstPageDisposition)))
        }
        if refreshForwardedSenders, firstPageDisposition == .abort {
            self.recordForwardedRefreshAbort(receivedFirstPage == nil ? .missingMessages : .malformedPage,
                                             offset: 0, scanned: 0)
            return
        }
        let firstPage = receivedFirstPage ?? []
        let parsed = await Self.parseDetached(firstPage, fallbackBase: 0)
        if refreshForwardedSenders {
            if Task.isCancelled { self.recordForwardedRefreshAbort(.cancelled, offset: 0, scanned: firstPage.count); return }
            if self.gateway !== gateway { self.recordForwardedRefreshAbort(.gatewayChanged, offset: 0, scanned: firstPage.count); return }
            if !gateway.state.isConnected { self.recordForwardedRefreshAbort(.disconnected, offset: 0, scanned: firstPage.count); return }
            if gateway.connectionEpoch != connectionEpoch { self.recordForwardedRefreshAbort(.connectionEpochChanged, offset: 0, scanned: firstPage.count); return }
            if gateway.cacheGeneration(of: self.sessionKey) != expectedGeneration {
                self.recordForwardedRefreshAbort(.cacheGenerationChanged, offset: 0, scanned: firstPage.count); return
            }
        } else {
            guard !Task.isCancelled, self.gateway === gateway, gateway.state.isConnected,
                  gateway.connectionEpoch == connectionEpoch,
                  gateway.cacheGeneration(of: self.sessionKey) == expectedGeneration
            else { return }
        }
        self.apply(history: result, parsed: parsed)
        self.live = nil
        self.hasLoaded = true
        if refreshForwardedSenders {
            var pagesNewestFirst = [parsed]
            var scanned = firstPage.count
            var offset: Int
            var hasMore: Bool
            switch firstPageDisposition {
            case let .more(nextOffset): offset = nextOffset; hasMore = true
            case let .complete(nextOffset): offset = nextOffset; hasMore = false
            case .abort:
                self.recordForwardedRefreshAbort(.malformedPage, offset: 0, scanned: scanned)
                return
            }
            while hasMore, scanned < TranscriptCache.maxItems {
                if Task.isCancelled { self.recordForwardedRefreshAbort(.cancelled, offset: offset, scanned: scanned); return }
                if self.gateway !== gateway { self.recordForwardedRefreshAbort(.gatewayChanged, offset: offset, scanned: scanned); return }
                if !gateway.state.isConnected { self.recordForwardedRefreshAbort(.disconnected, offset: offset, scanned: scanned); return }
                if gateway.connectionEpoch != connectionEpoch { self.recordForwardedRefreshAbort(.connectionEpochChanged, offset: offset, scanned: scanned); return }
                if gateway.cacheGeneration(of: self.sessionKey) != expectedGeneration {
                    self.recordForwardedRefreshAbort(.cacheGenerationChanged, offset: offset, scanned: scanned); return
                }
                if !gateway.appIsActive { self.recordForwardedRefreshAbort(.applicationInactive, offset: offset, scanned: scanned); return }
                params["limit"] = .number(Double(min(self.historyLimit, TranscriptCache.maxItems - scanned)))
                params["offset"] = .number(Double(offset))
                let requestedLimit = min(self.historyLimit, TranscriptCache.maxItems - scanned)
                self.recordForwardedRefresh(.request(offset: offset, limit: requestedLimit, scanned: scanned))
                let page: JSONValue
                do {
                    page = try await gateway.connection.request("chat.history", .object(params), timeout: 30)
                } catch {
                    self.recordForwardedRefreshAbort(.requestFailed, offset: offset, scanned: scanned)
                    return
                }
                let receivedPage = page["messages"]?.array
                if Task.isCancelled { self.recordForwardedRefreshAbort(.cancelled, offset: offset, scanned: scanned); return }
                let disposition = Self.forwardedRefreshPageDisposition(
                    messageCount: receivedPage?.count, reportedHasMore: page["hasMore"]?.bool,
                    requestedOffset: offset, returnedOffset: page["nextOffset"]?.int,
                    fallbackLimit: requestedLimit)
                self.recordForwardedRefresh(.page(offset: offset, limit: requestedLimit,
                                                  messageCount: receivedPage?.count,
                                                  hasMore: page["hasMore"]?.bool,
                                                  nextOffset: page["nextOffset"]?.int,
                                                  disposition: Self.diagnosticDisposition(disposition)))
                if disposition == .abort {
                    self.recordForwardedRefreshAbort(receivedPage == nil ? .missingMessages : .malformedPage,
                                                     offset: offset, scanned: scanned)
                    return
                }
                guard let raw = receivedPage else {
                    self.recordForwardedRefreshAbort(.missingMessages, offset: offset, scanned: scanned)
                    return
                }
                let older = await Self.parseDetached(raw, fallbackBase: -(offset + raw.count))
                pagesNewestFirst.append(older)
                scanned += raw.count
                switch disposition {
                case let .more(nextOffset): offset = nextOffset; hasMore = true
                case let .complete(nextOffset): offset = nextOffset; hasMore = false
                case .abort:
                    self.recordForwardedRefreshAbort(.malformedPage, offset: offset, scanned: scanned)
                    return
                }
            }
            if Task.isCancelled { self.recordForwardedRefreshAbort(.cancelled, offset: offset, scanned: scanned); return }
            if self.gateway !== gateway { self.recordForwardedRefreshAbort(.gatewayChanged, offset: offset, scanned: scanned); return }
            if !gateway.state.isConnected { self.recordForwardedRefreshAbort(.disconnected, offset: offset, scanned: scanned); return }
            if gateway.connectionEpoch != connectionEpoch { self.recordForwardedRefreshAbort(.connectionEpochChanged, offset: offset, scanned: scanned); return }
            if gateway.cacheGeneration(of: self.sessionKey) != expectedGeneration {
                self.recordForwardedRefreshAbort(.cacheGenerationChanged, offset: offset, scanned: scanned); return
            }
            if !gateway.appIsActive { self.recordForwardedRefreshAbort(.applicationInactive, offset: offset, scanned: scanned); return }
            if hasMore, scanned < TranscriptCache.maxItems {
                self.recordForwardedRefreshAbort(.malformedPage, offset: offset, scanned: scanned)
                return
            }
            var reconciled: [ChatItem]?
            for attempt in 0...1 {
                let revision = self.contentRevision
                let currentItems = self.items
                self.recordForwardedRefresh(.reconcileStarted(scanned: scanned, revision: revision))
                let result = await Self.reconcileForwardedRefresh(
                    restoredCache: restoredCacheItems, pagesNewestFirst: pagesNewestFirst, current: currentItems)
                if Task.isCancelled { self.recordForwardedRefreshAbort(.cancelled, offset: offset, scanned: scanned); return }
                if self.gateway !== gateway { self.recordForwardedRefreshAbort(.gatewayChanged, offset: offset, scanned: scanned); return }
                if !gateway.state.isConnected { self.recordForwardedRefreshAbort(.disconnected, offset: offset, scanned: scanned); return }
                if gateway.connectionEpoch != connectionEpoch { self.recordForwardedRefreshAbort(.connectionEpochChanged, offset: offset, scanned: scanned); return }
                if gateway.cacheGeneration(of: self.sessionKey) != expectedGeneration {
                    self.recordForwardedRefreshAbort(.cacheGenerationChanged, offset: offset, scanned: scanned); return
                }
                if !gateway.appIsActive { self.recordForwardedRefreshAbort(.applicationInactive, offset: offset, scanned: scanned); return }
                self.recordForwardedRefresh(.reconciled(scanned: scanned, rowCount: result.count, revision: revision))
                if self.contentRevision == revision {
                    reconciled = result
                    break
                }
                if attempt == 1 {
                    self.recordForwardedRefreshAbort(.changedTwiceDuringReconcile, offset: offset, scanned: scanned)
                    return
                }
            }
            guard let reconciled else { return }
            self.replaceRecoveryItems(reconciled)
            self.hasMoreHistory = hasMore
            self.olderInCache = false
            self.olderOffset = offset
            self.hasPagedOlder = true
            self.forwardedSenderRefreshPending = false
            self.forwardedSenderRefreshCompleted = true
            await self.saveSnapshot()
            return
        }
        await self.loadAllCached()
        // Older items past the retention limit would be dropped anyway.
        while self.hasOlderItems, !Task.isCancelled, self.committedCount < TranscriptCache.maxItems {
            guard self.gateway?.appIsActive ?? false else { return }
            guard await self.loadOlder() else { return }
        }
        guard !Task.isCancelled, generation.map({ gateway.cacheGeneration(of: self.sessionKey) == $0 }) ?? true else { return }
        await self.saveSnapshot()
    }

    /// Replaces stale versions by stable transcript id while retaining offline-only cache rows.
    nonisolated static func mergeForwardedRefresh(cached: [ChatItem], authoritative: [ChatItem]) async -> [ChatItem] {
        await Task.detached(priority: .utility) {
            Self.mergeForwardedRefreshSynchronously(cached: cached, authoritative: authoritative)
        }.value
    }

    /// Filters and flattens full retained transcripts off-main before reconciling stable ids.
    nonisolated static func reconcileForwardedRefresh(restoredCache: [ChatItem], pagesNewestFirst: [[ChatItem]],
                                                       current: [ChatItem]) async -> [ChatItem]
    {
        await Task.detached(priority: .utility) {
            var authoritative = pagesNewestFirst.reversed().flatMap { $0 }
            var currentById: [String: ChatItem] = [:]
            currentById.reserveCapacity(current.count)
            for item in current where !item.isPending {
                currentById[item.transcriptId ?? item.id] = item
            }
            for index in authoritative.indices {
                let key = authoritative[index].transcriptId ?? authoritative[index].id
                guard var currentItem = currentById[key] else { continue }
                if let sender = authoritative[index].sender { currentItem.sender = sender }
                authoritative[index] = currentItem
            }
            // For duplicate ids absent from the authoritative pages, the live row may contain a
            // newer edit than the restored cache. The merge keeps its first matching row.
            let cached = current.filter { !$0.isPending } + restoredCache.filter { !$0.isPending }
            let committed = Self.mergeForwardedRefreshSynchronously(cached: cached, authoritative: authoritative)
            return committed + current.filter(\.isPending)
        }.value
    }

    /// Stable O(n log n) sort plus O(n) merge; preserves authoritative order, cached tie order,
    /// and the existing convention that cached rows without timestamps lead in reverse cache order.
    nonisolated private static func mergeForwardedRefreshSynchronously(cached: [ChatItem],
                                                                        authoritative: [ChatItem]) -> [ChatItem]
    {
        var authoritativeIds = Set<String>()
        authoritativeIds.reserveCapacity(authoritative.count)
        for item in authoritative { authoritativeIds.insert(item.transcriptId ?? item.id) }

        var seenIds = authoritativeIds
        var unmatched: [ChatItem] = []
        unmatched.reserveCapacity(cached.count)
        for item in cached {
            guard seenIds.insert(item.transcriptId ?? item.id).inserted else { continue }
            unmatched.append(item)
        }
        let undated = unmatched.filter { $0.timestamp == nil }.reversed()
        let dated = unmatched.enumerated().compactMap { ordinal, item -> (Int, ChatItem)? in
            item.timestamp == nil ? nil : (ordinal, item)
        }.sorted {
            let left = $0.1.timestamp!
            let right = $1.1.timestamp!
            return left == right ? $0.0 < $1.0 : left < right
        }

        var merged = Array(undated)
        merged.reserveCapacity(authoritative.count + unmatched.count)
        var cachedIndex = 0
        for item in authoritative {
            if let time = item.timestamp {
                while cachedIndex < dated.count, dated[cachedIndex].1.timestamp! < time {
                    merged.append(dated[cachedIndex].1)
                    cachedIndex += 1
                }
            }
            merged.append(item)
        }
        while cachedIndex < dated.count {
            merged.append(dated[cachedIndex].1)
            cachedIndex += 1
        }
        return Array(merged.suffix(TranscriptCache.maxItems))
    }
}
