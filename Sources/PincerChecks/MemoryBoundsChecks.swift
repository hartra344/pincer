import CoreGraphics
import Foundation
import ImageIO
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// Memory bounds (#198): the image cache is budgeted by decoded bytes, purges under memory pressure and
/// reloads what it evicted. Inline base64 images, so no network, and nothing depends on layout.
@MainActor
func runMemoryBoundsChecks() async {
    #if DEBUG
    func bitmap(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    func png(_ width: Int, _ height: Int) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap(width, height), nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
    func ref(_ data: Data, _ tag: Int) -> ImageRef {
        ImageRef(artifactId: nil, base64: "data:image/png;n=\(tag);base64,\(data.base64EncodedString())", url: nil,
                 mimeType: "image/png", alt: nil, width: nil, height: nil)
    }
    func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    // The cache itself: bytesPerRow × height, LRU, newest kept.
    var cache = DecodedImageCache(byteLimit: 300)
    for key in ["a", "b", "c"] { cache.insert(cost: 100, for: key) }
    _ = cache.value(for: "a")
    check(cache.insert(cost: 100, for: "d") == ["b"], "byte cache evicts the least recently used entry")
    check(cache.totalBytes == 300, "byte cache total stays at the limit")
    check(Set(cache.insert(cost: 1000, for: "huge")) == ["a", "c", "d"] && cache.contains("huge"),
          "byte cache keeps the newest entry even when it alone exceeds the limit")
    let sample = bitmap(50, 20)
    var sized = DecodedImageCache(byteLimit: 1 << 20)
    sized.insert(sample, for: "s")
    check(sized.totalBytes == sample.bytesPerRow * sample.height, "cost is bytesPerRow × height")

    // Many inline images stay inside the byte budget, and the accounting matches what's retained.
    let data = png(400, 300)
    let cost = bitmap(400, 300).bytesPerRow * 300
    let budget = cost * 4 + cost / 2
    let loader = ArtifactImageLoader(byteBudget: budget)
    let refs = (0..<24).map { ref(data, $0) }
    for r in refs { loader.load(r, sessionKey: "agent:mem:main") }
    let loaded = await settle { refs.allSatisfy { loader.hasFailed($0) } || loader.imageCount >= 4 }
    try? await Task.sleep(for: .milliseconds(300))
    check(loaded && loader.failures.isEmpty, "inline images decode")
    check(loader.decodedBytes <= budget, "24 images stay within the decoded byte budget (\(loader.decodedBytes / 1024) KiB of \(budget / 1024) KiB)")
    check(loader.imageCount > 0 && loader.imageCount <= 4, "only as many images as fit the budget are retained (\(loader.imageCount))")
    check(loader.images.count == loader.imageCount
          && loader.decodedBytes == loader.images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height },
          "observable images match the cache accounting")

    // Downsampled to the transcript size.
    let big = ArtifactImageLoader(byteBudget: 1 << 30)
    let bigRef = ref(png(3000, 1800), 0)
    big.load(bigRef, sessionKey: "agent:mem:main")
    _ = await settle { big.cached(bigRef) != nil }
    check(big.cached(bigRef).map { max($0.width, $0.height) <= ArtifactImageLoader.transcriptMaxPixel } == true,
          "large images are decoded no bigger than the transcript max pixel")

    // Memory pressure.
    let pressured = ArtifactImageLoader(byteBudget: cost * 8)
    for i in 0..<8 { pressured.store(bitmap(400, 300), key: "k\(i)") }
    pressured.handleMemoryPressure(critical: false)
    check(pressured.decodedBytes <= cost * 2 && pressured.imageCount == 2, "memory warning trims to a quarter of the budget")
    check(pressured.images["k7"] != nil && pressured.images["k0"] == nil, "warning keeps the most recent images")
    pressured.handleMemoryPressure(critical: true)
    check(pressured.decodedBytes == 0 && pressured.images.isEmpty, "critical memory pressure purges every decoded image")

    // What was purged loads again on demand.
    let again = ref(data, 999)
    let reloader = ArtifactImageLoader(byteBudget: cost * 8)
    reloader.load(again, sessionKey: "agent:mem:main")
    _ = await settle { reloader.cached(again) != nil }
    reloader.handleMemoryPressure(critical: true)
    check(reloader.cached(again) == nil, "purged image is gone from the cache")
    reloader.load(again, sessionKey: "agent:mem:main")
    let reloaded = await settle { reloader.cached(again) != nil }
    check(reloaded, "purged image reloads when its row is shown again")

    // 25 MiB cap on base64 payloads, and the at-most-4 download limiter.
    check(ArtifactImageLoader.decodeBase64(String(repeating: "A", count: (25 * 1024 * 1024 / 3 + 8) * 4)) == nil,
          "base64 payload over 25 MiB is rejected before decoding")
    let limiter = DownloadLimiter(limit: 4)
    var running = 0, most = 0
    let tasks = (0..<16).map { _ in
        Task { @MainActor in
            try? await limiter.acquire()
            running += 1; most = max(most, running)
            try? await Task.sleep(for: .milliseconds(3))
            running -= 1
            limiter.release()
        }
    }
    for task in tasks { await task.value }
    check(most == 4 && limiter.peak == 4 && limiter.active == 0, "at most 4 downloads run at once (peak \(limiter.peak))")
    #else
    print("  (memory-bounds checks need a debug build)")
    #endif
}
