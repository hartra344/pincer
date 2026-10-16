import CoreGraphics
import Foundation
import ImageIO

/// One decoded screencast frame. `CGImage` is immutable, so sharing it across actors is safe.
public struct BrowserFrame: @unchecked Sendable {
    public let image: CGImage
    public let pageURL: URL?
    /// The page's CSS size; used only for the aspect ratio.
    public let cssSize: CGSize
    public let sequence: Int

    public init(image: CGImage, pageURL: URL? = nil, cssSize: CGSize, sequence: Int) {
        self.image = image
        self.pageURL = pageURL
        self.cssSize = cssSize
        self.sequence = sequence
    }
}

public enum BrowserStreamEvent: Sendable {
    case frame(BrowserFrame)
    case meta(url: URL?, title: String?)
    /// The stream ended. `code` is the WebSocket close code when there was one (4003 blocked, 4004 replaced).
    case closed(code: Int?)
}

/// Where frames come from: the screencast socket, or the demo's renderer. Ends by yielding `.closed`.
public protocol BrowserFrameSource: Sendable {
    func frames() -> AsyncThrowingStream<BrowserStreamEvent, Error>
}

public enum BrowserFrameDecoder {
    public static let pixelCap = 2048

    /// Decodes a JPEG into a thumbnail whose longest side is at most `min(maxPixelSize, 2048)`. Never upscales.
    public static func decode(_ jpeg: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let limit = min(max(maxPixelSize, 1), self.pixelCap)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Parses and decodes raw screencast messages off the caller, latest-wins: while one decode is in
/// flight a newer message replaces the pending one, and the older frame is dropped.
/// A message that fails to parse or decode is dropped.
public final class BrowserFramePump: Sendable {
    private struct State {
        var pending: Data?
        var finished = false
    }

    private let state = LockedBox(State())
    private let signal: AsyncStream<Void>.Continuation
    private let output: AsyncStream<BrowserFrame>.Continuation
    private let worker: Task<Void, Never>
    public let frames: AsyncStream<BrowserFrame>

    public init(maxPixelSize: Int) {
        let (signals, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (frames, output) = AsyncStream<BrowserFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signal = signal
        self.output = output
        self.frames = frames
        let state = self.state
        self.worker = Task.detached(priority: .userInitiated) {
            var sequence = 0
            for await _ in signals {
                while let message = state.withLock({ value -> Data? in
                    defer { value.pending = nil }
                    return value.pending
                }) {
                    guard let parsed = try? BrowserScreencastWire.parse(message),
                          let image = BrowserFrameDecoder.decode(parsed.jpeg, maxPixelSize: maxPixelSize)
                    else { continue }
                    sequence += 1
                    let width = parsed.header.cssWidth ?? 0
                    let height = parsed.header.cssHeight ?? 0
                    let css = width > 0 && height > 0
                        ? CGSize(width: width, height: height) : CGSize(width: image.width, height: image.height)
                    output.yield(BrowserFrame(
                        image: image, pageURL: parsed.header.url.flatMap { BrowserTabRef.webURL($0) },
                        cssSize: css, sequence: sequence))
                }
            }
            output.finish()
        }
    }

    deinit { self.finish() }

    /// Hands over one raw socket message. Cheap: the work happens on the pump's own task.
    public func push(_ message: Data) {
        let accepted = self.state.withLock { value -> Bool in
            guard !value.finished else { return false }
            value.pending = message
            return true
        }
        if accepted { self.signal.yield() }
    }

    /// Stops the pump. Frames already decoded are still delivered.
    public func finish() {
        self.state.withLock { $0.finished = true; $0.pending = nil }
        self.signal.finish()
    }
}

/// A tiny lock-protected value.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body(&self.value)
    }
}
