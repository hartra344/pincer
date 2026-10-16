import Foundation

/// The live screencast socket (`wsPath` from `POST /screencast`). View-only: nothing is ever sent.
/// It goes through the same TLS trust as the main connection. The URL carries a one-time token,
/// so it is never logged and never put in an error.
public actor BrowserScreencastClient: BrowserFrameSource {
    private let url: URL
    private let fingerprint: String?
    private let maxPixelSize: Int

    public init(url: URL, fingerprint: String?, maxPixelSize: Int) {
        self.url = url
        self.fingerprint = fingerprint
        self.maxPixelSize = maxPixelSize
    }

    /// `wsPath` resolved against the Gateway's URL, the way upstream's `resolveGatewayWebSocketUrl` does:
    /// http(s) becomes ws(s), and anything else is refused. Plain ws:// to a public host is refused too.
    public static func resolveURL(wsPath: String, gateway: URL) -> URL? {
        guard var base = URLComponents(url: gateway, resolvingAgainstBaseURL: false) else { return nil }
        base.scheme = Self.webSocketScheme(base.scheme)
        guard let baseURL = base.url, let resolved = URL(string: wsPath, relativeTo: baseURL)?.absoluteURL,
              var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
        else { return nil }
        parts.scheme = Self.webSocketScheme(parts.scheme)
        guard let scheme = parts.scheme, scheme == "ws" || scheme == "wss", let host = parts.host?.lowercased(), !host.isEmpty,
              scheme == "wss" || GatewayProfile.isPrivateHost(host)
        else { return nil }
        return parts.url
    }

    private static func webSocketScheme(_ scheme: String?) -> String? {
        switch scheme?.lowercased() {
        case "https": "wss"
        case "http": "ws"
        default: scheme?.lowercased()
        }
    }

    public nonisolated func frames() -> AsyncThrowingStream<BrowserStreamEvent, Error> {
        let url = self.url
        let fingerprint = self.fingerprint
        let maxPixelSize = self.maxPixelSize
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(url: url, fingerprint: fingerprint, maxPixelSize: maxPixelSize, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(url: URL, fingerprint: String?, maxPixelSize: Int,
                            into continuation: AsyncThrowingStream<BrowserStreamEvent, Error>.Continuation) async
    {
        let delegate = BrowserSocketDelegate(fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: URLRequest(url: url))
        socket.maximumMessageSize = BrowserScreencastWire.maxMessageBytes + BrowserScreencastWire.maxHeaderBytes + 4096
        let pump = BrowserFramePump(maxPixelSize: maxPixelSize)
        let forwarder = Task.detached {
            for await frame in pump.frames { continuation.yield(.frame(frame)) }
        }
        socket.resume()
        var closeCode: Int?
        receiving: while !Task.isCancelled {
            do {
                switch try await socket.receive() {
                case let .data(data):
                    pump.push(data)
                case let .string(text):
                    switch BrowserScreencastWire.parseControl(text) {
                    case let .ready(_, url, title), let .meta(url, title):
                        continuation.yield(.meta(url: url.flatMap { BrowserTabRef.webURL($0) }, title: title))
                    case .error:
                        closeCode = 1011
                        break receiving
                    case nil:
                        break
                    }
                @unknown default:
                    break
                }
            } catch {
                let code = socket.closeCode.rawValue
                closeCode = code != 0 ? code : (delegate.closeCode ?? 1006)
                break receiving
            }
        }
        pump.finish()
        socket.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
        await forwarder.value
        if Task.isCancelled {
            continuation.finish()
        } else {
            continuation.yield(.closed(code: closeCode))
            continuation.finish()
        }
    }
}

/// Server-trust through the same pinning as the main connection, and the server's close code.
private final class BrowserSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let pinning: PinningDelegate
    private let code = LockedBox<Int?>(nil)

    init(fingerprint: String?) { self.pinning = PinningDelegate(fingerprint: fingerprint) }

    var closeCode: Int? { self.code.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await self.pinning.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    {
        self.code.withLock { $0 = closeCode.rawValue }
    }
}
