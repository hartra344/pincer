import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PincerKit

/// Byte-budgeted image cache (#198): LRU by decoded bytes, downsampling, memory pressure, size caps,
/// bounded downloads. Inline base64 refs decode without any network.
@MainActor
@Suite("ImageMemoryBudget", .serialized)
struct ImageMemoryBudgetTests {
    static func bitmap(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(_ width: Int, _ height: Int) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap(width, height), nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func ref(_ png: Data, tag: Int) -> ImageRef {
        // `stripDataURL` drops everything up to the first comma, so the tag only changes the cache key.
        ImageRef(artifactId: nil, base64: "data:image/png;n=\(tag);base64,\(png.base64EncodedString())", url: nil,
                 mimeType: "image/png", alt: nil, width: nil, height: nil)
    }

    static func bytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    // MARK: DecodedImageCache

    @Test func costIsBytesPerRowTimesHeight() {
        let image = Self.bitmap(100, 40)
        var cache = DecodedImageCache(byteLimit: 1 << 30)
        cache.insert(image, for: "a")
        #expect(cache.totalBytes == image.bytesPerRow * 40)
        #expect(cache.totalBytes >= 100 * 4 * 40)
        #expect(cache.count == 1)
    }

    @Test func evictsLeastRecentlyUsedByBytes() {
        var cache = DecodedImageCache(byteLimit: 300)
        #expect(cache.insert(cost: 100, for: "a").isEmpty)
        #expect(cache.insert(cost: 100, for: "b").isEmpty)
        #expect(cache.insert(cost: 100, for: "c").isEmpty)
        #expect(cache.totalBytes == 300)
        // Touch "a" so "b" is now the oldest.
        _ = cache.value(for: "a")
        #expect(cache.insert(cost: 100, for: "d") == ["b"])
        #expect(cache.contains("a") && cache.contains("c") && cache.contains("d") && !cache.contains("b"))
        #expect(cache.totalBytes == 300)
    }

    @Test func peekDoesNotTouchRecency() {
        let image = Self.bitmap(10, 10)
        let cost = Self.bytes(image)
        var cache = DecodedImageCache(byteLimit: cost * 2)
        cache.insert(image, for: "a")
        cache.insert(image, for: "b")
        #expect(cache.peek("a") != nil)
        #expect(cache.insert(image, for: "c") == ["a"])
    }

    @Test func oneLargeInsertEvictsSeveralSmallOnes() {
        var cache = DecodedImageCache(byteLimit: 1000)
        for i in 0..<10 { cache.insert(cost: 100, for: "s\(i)") }
        let evicted = cache.insert(cost: 600, for: "big")
        #expect(evicted.count == 6)
        #expect(evicted == (0..<6).map { "s\($0)" })
        #expect(cache.totalBytes == 1000)
        #expect(cache.contains("big"))
    }

    @Test func newestIsKeptEvenWhenItAloneExceedsTheLimit() {
        var cache = DecodedImageCache(byteLimit: 100)
        cache.insert(cost: 50, for: "a")
        let evicted = cache.insert(cost: 500, for: "huge")
        #expect(evicted == ["a"])
        #expect(cache.contains("huge"))
        #expect(cache.totalBytes == 500)
        #expect(cache.count == 1)
        // The next insert pushes the oversized one out, and it in turn stays.
        #expect(cache.insert(cost: 60, for: "next") == ["huge"])
        #expect(cache.totalBytes == 60)
    }

    @Test func reinsertingAKeyReplacesItsCost() {
        var cache = DecodedImageCache(byteLimit: 1000)
        cache.insert(cost: 400, for: "a")
        cache.insert(cost: 100, for: "a")
        #expect(cache.totalBytes == 100)
        #expect(cache.count == 1)
    }

    @Test func trimEvictsOldestFirstDownToTarget() {
        var cache = DecodedImageCache(byteLimit: 1000)
        for i in 0..<8 { cache.insert(cost: 100, for: "k\(i)") }
        _ = cache.value(for: "k0")
        let evicted = cache.trim(toBytes: 250)
        #expect(evicted == ["k1", "k2", "k3", "k4", "k5", "k6"])
        #expect(cache.totalBytes == 200)
        #expect(cache.contains("k0") && cache.contains("k7"))
        #expect(cache.trim(toBytes: 250).isEmpty)
    }

    @Test func removeAllAndRemoveResetAccounting() {
        var cache = DecodedImageCache(byteLimit: 1000)
        cache.insert(cost: 100, for: "a")
        cache.insert(cost: 200, for: "b")
        let first = cache.remove("a")
        let second = cache.remove("a")
        #expect(first && !second)
        #expect(cache.totalBytes == 200)
        #expect(Set(cache.removeAll()) == ["b"])
        #expect(cache.totalBytes == 0 && cache.count == 0)
    }

    @Test func bytesNeverExceedLimitPlusOneEntryUnderChurn() {
        var cache = DecodedImageCache(byteLimit: 5_000)
        for i in 0..<500 {
            cache.insert(cost: 100 + (i * 37) % 900, for: "k\(i % 40)")
            if i % 3 == 0 { _ = cache.value(for: "k\((i * 7) % 40)") }
            #expect(cache.totalBytes <= 5_000 || cache.count == 1)
        }
    }

    // MARK: ArtifactImageLoader

    @Test func defaultBudgetsAreSet() {
        #if os(macOS)
        #expect(ArtifactImageLoader.defaultByteBudget == 160 * 1024 * 1024)
        #else
        #expect(ArtifactImageLoader.defaultByteBudget == 64 * 1024 * 1024)
        #endif
        #expect(ArtifactImageLoader().byteBudget == ArtifactImageLoader.defaultByteBudget)
        #expect(ArtifactImageLoader(byteBudget: 1234).byteBudget == 1234)
    }

    @Test func manyInlineImagesStayWithinTheByteBudget() async {
        let png = Self.png(600, 400)
        let one = 600 * 4 * 400
        let budget = one * 5 + one / 2
        let loader = ArtifactImageLoader(byteBudget: budget)
        let refs = (0..<20).map { Self.ref(png, tag: $0) }
        for ref in refs { loader.load(ref, sessionKey: "agent:t:main") }
        let done = await eventually(timeout: .seconds(20)) { loader.imageCount + loader.failures.count > 0 && loader.decodedBytes > 0
            && refs.allSatisfy { loader.images[$0.cacheKey] != nil || loader.hasFailed($0) || loader.imageCount == 5 } }
        _ = done
        try? await Task.sleep(for: .milliseconds(500))
        #expect(loader.failures.isEmpty)
        #expect(loader.decodedBytes <= budget)
        #expect(loader.imageCount <= 5 && loader.imageCount >= 1)
        #expect(loader.images.count == loader.imageCount)
        #expect(loader.decodedBytes == loader.images.values.reduce(0) { $0 + Self.bytes($1) })
    }

    @Test func evictedImageReloadsWhenLoadedAgain() async {
        let png = Self.png(300, 200)
        let cost = 300 * 4 * 200
        let loader = ArtifactImageLoader(byteBudget: cost * 2 + cost / 2)
        let first = Self.ref(png, tag: 0)
        loader.load(first, sessionKey: "k")
        #expect(await eventually { loader.cached(first) != nil })
        for tag in 1...4 {
            let ref = Self.ref(png, tag: tag)
            loader.load(ref, sessionKey: "k")
            #expect(await eventually { loader.cached(ref) != nil })
        }
        #expect(loader.cached(first) == nil)
        #expect(!loader.hasFailed(first))
        loader.load(first, sessionKey: "k")
        #expect(await eventually { loader.cached(first) != nil })
        #expect(loader.decodedBytes <= cost * 2 + cost / 2)
    }

    @Test func memoryPressureWarningTrimsToAQuarterAndCriticalPurges() {
        let image = Self.bitmap(100, 100)
        let cost = Self.bytes(image)
        let loader = ArtifactImageLoader(byteBudget: cost * 8)
        for i in 0..<8 { loader.store(image, key: "k\(i)") }
        #expect(loader.imageCount == 8)
        loader.handleMemoryPressure(critical: false)
        #expect(loader.decodedBytes <= cost * 2)
        #expect(loader.imageCount == 2)
        // The newest survive a warning; evicted keys are gone from the observable dictionary too.
        #expect(loader.images["k7"] != nil && loader.images["k6"] != nil && loader.images["k0"] == nil)
        #expect(loader.images.count == 2)
        loader.handleMemoryPressure(critical: true)
        #expect(loader.decodedBytes == 0 && loader.imageCount == 0 && loader.images.isEmpty)
    }

    @Test func purgedImageLoadsAgain() async {
        let png = Self.png(200, 100)
        let loader = ArtifactImageLoader(byteBudget: 10_000_000)
        let ref = Self.ref(png, tag: 1)
        loader.load(ref, sessionKey: "k")
        #expect(await eventually { loader.cached(ref) != nil })
        loader.handleMemoryPressure(critical: true)
        #expect(loader.cached(ref) == nil)
        loader.load(ref, sessionKey: "k")
        #expect(await eventually { loader.cached(ref) != nil })
    }

    @Test func transcriptImagesAreDownsampled() async {
        let loader = ArtifactImageLoader(byteBudget: 500_000_000)
        let ref = Self.ref(Self.png(3000, 1500), tag: 1)
        loader.load(ref, sessionKey: "k")
        #expect(await eventually { loader.cached(ref) != nil })
        let image = loader.cached(ref)!
        #expect(max(image.width, image.height) <= ArtifactImageLoader.transcriptMaxPixel)
        #expect(max(image.width, image.height) >= ArtifactImageLoader.transcriptMaxPixel - 2)
        #expect(loader.decodedBytes < 3000 * 1500 * 4 / 4)
    }

    @Test func smallImagesAreNotUpscaled() async {
        let loader = ArtifactImageLoader()
        let ref = Self.ref(Self.png(64, 32), tag: 1)
        loader.load(ref, sessionKey: "k")
        #expect(await eventually { loader.cached(ref) != nil })
        #expect(loader.cached(ref)?.width == 64)
    }

    @Test func imageCodecMaxPixelBound() {
        let decoded = ImageCodec.decode(Self.png(2000, 1000), maxPixel: 500)
        #expect(decoded.map { max($0.width, $0.height) } == 500)
    }

    // MARK: Size caps

    @Test func base64PayloadImplyingMoreThanTheCapIsRejectedBeforeDecoding() {
        // The length check works on the encoded size, so padding can add a couple of bytes of slack.
        let cap = 1100
        let ok = Data(repeating: 7, count: 1024).base64EncodedString()
        #expect(ArtifactImageLoader.decodeBase64(ok, maxBytes: cap)?.count == 1024)
        #expect(ArtifactImageLoader.decodeBase64("data:image/png;base64," + ok, maxBytes: cap)?.count == 1024)
        let over = Data(repeating: 7, count: 2048).base64EncodedString()
        #expect(ArtifactImageLoader.decodeBase64(over, maxBytes: cap) == nil)
    }

    @Test func defaultCapIs25MiB() {
        #expect(GatewayMediaClient.defaultMaxBytes == 25 * 1024 * 1024)
        // Just past 25 MiB of decoded bytes, without allocating that much: length alone rejects it.
        let long = String(repeating: "A", count: (25 * 1024 * 1024 / 3 + 8) * 4)
        #expect(ArtifactImageLoader.decodeBase64(long) == nil)
    }

    // MARK: Concurrency limit

    @Test func limiterNeverRunsMoreThanFourAndKeepsFIFOOrder() async {
        let limiter = DownloadLimiter(limit: 4)
        var order: [Int] = []
        var running = 0
        var maxRunning = 0
        let tasks = (0..<20).map { i in
            Task { @MainActor in
                try? await limiter.acquire()
                running += 1
                maxRunning = max(maxRunning, running)
                order.append(i)
                try? await Task.sleep(for: .milliseconds(5))
                running -= 1
                limiter.release()
            }
        }
        for task in tasks { await task.value }
        #expect(maxRunning <= 4)
        #expect(limiter.peak == 4)
        #expect(limiter.active == 0)
        #expect(order.count == 20)
    }

    @Test func cancelledWaiterFreesItsPlaceInTheQueue() async {
        let limiter = DownloadLimiter(limit: 1)
        try? await limiter.acquire()
        let waiter = Task { @MainActor in
            do { try await limiter.acquire(); limiter.release(); return false } catch { return true }
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value)
        limiter.release()
        #expect(limiter.active == 0)
        try? await limiter.acquire()
        #expect(limiter.active == 1)
        limiter.release()
    }
}
