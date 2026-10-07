import Foundation
import PincerKit

/// Reading a current-version cached transcript parses its manifest exactly once.
@MainActor
func runTranscriptCacheDecodeChecks() async {
    #if DEBUG
    await withScratchCache { root in
        let gateway = UUID()
        let items = (0..<4).map { messageItem("d\($0)", .user, "decode \($0)", at: Double($0)) }
        await TranscriptCache.save(TranscriptCache.Snapshot(items: items, complete: true), gatewayId: gateway, sessionKey: "k", root: root)
        guard let url = TranscriptCache.file(gatewayId: gateway, sessionKey: "k", root: root) else {
            check(false, "decode: cache file located")
            return
        }
        let before = TranscriptCache.manifestDecodeCount(for: url)
        let loaded = await TranscriptCache.load(gatewayId: gateway, sessionKey: "k", root: root)
        check(loaded?.items.count == 4, "decode: transcript loads")
        check(TranscriptCache.manifestDecodeCount(for: url) - before == 1, "decode: one read parses the manifest once")
    }
    #endif
}
