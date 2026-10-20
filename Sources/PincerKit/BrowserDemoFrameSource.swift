import CoreGraphics
import CoreText
import Foundation

/// The pages the demo's browser shows, and what the seeded chat's `browser` calls point at.
public enum BrowserDemoPages {
    public struct Page: Sendable {
        public let targetId: String
        public let title: String
        public let url: String
        public let heading: String
        public let lines: [String]
    }

    public static let docs = Page(
        targetId: "DEMO-TAB-DOCS", title: "OpenClaw Docs", url: "https://docs.openclaw.ai/",
        heading: "Get started with OpenClaw",
        lines: ["Install the Gateway on a machine you control.", "Pair a device and pick a model.",
                "Add channels: WhatsApp, Telegram, Slack and more.", "Give your agent tools: browser, exec, files.",
                "Connect MCP servers for GitHub, Linear and others.", "Review approvals before risky commands run.",
                "Schedule automations with cron.", "Read the security guide before exposing the Gateway."])
    public static let release = Page(
        targetId: "DEMO-TAB-RELEASE", title: "Releases · openclaw/openclaw",
        url: "https://github.com/openclaw/openclaw/releases/latest", heading: "OpenClaw 2026.10",
        lines: ["Browser panel: watch the agent's browser live.", "Faster transcript loading on long chats.",
                "MCP servers can sign in with OAuth.", "Fixes for flaky channel reconnects.",
                "Contributors: 41 people shipped this release.", "Assets: macOS, Linux and Docker images."])
    public static let all = [docs, release]

    public static func page(targetId: String) -> Page? { self.all.first { $0.targetId == targetId } }

    /// The page for an address: the seeded pages by URL, otherwise a generic page headed by the host.
    public static func page(targetId: String, url: String, title: String?) -> Page {
        if let known = self.all.first(where: { $0.url == url }) {
            return Page(targetId: targetId, title: title ?? known.title, url: url, heading: known.heading, lines: known.lines)
        }
        let host = URL(string: url)?.host ?? "New tab"
        return Page(targetId: targetId, title: title ?? host, url: url, heading: host,
                    lines: ["This is a demo page for \(host).", "The demo gateway doesn't browse the real web.",
                            "Back, Forward and Reload work on these pages.", "Open a new tab to try the tab strip."])
    }
}

/// An in-process stand-in for the screencast socket: draws a page with CoreGraphics at about 2 fps,
/// with a scrolling text column and a moving pointer so the view looks live.
public struct BrowserDemoFrameSource: BrowserFrameSource {
    public static let scheme = "demo-screencast"

    private let page: BrowserDemoPages.Page
    private let interval: Duration

    public init(targetId: String, framesPerSecond: Double = 2) {
        self.page = BrowserDemoPages.page(targetId: targetId) ?? BrowserDemoPages.docs
        self.interval = .milliseconds(Int(1000 / max(framesPerSecond, 0.5)))
    }

    /// Renders what a `demo-screencast://<targetId>?url=…&title=…` path describes.
    public init(wsPath: String, framesPerSecond: Double = 2) {
        let items = URLComponents(string: wsPath)?.queryItems ?? []
        let url = items.first { $0.name == "url" }?.value
        let id = Self.targetId(wsPath: wsPath) ?? BrowserDemoPages.docs.targetId
        if let url {
            self.page = BrowserDemoPages.page(targetId: id, url: url, title: items.first { $0.name == "title" }?.value)
        } else {
            self.page = BrowserDemoPages.page(targetId: id) ?? BrowserDemoPages.docs
        }
        self.interval = .milliseconds(Int(1000 / max(framesPerSecond, 0.5)))
    }

    /// The target id inside a `demo-screencast://<targetId>` path.
    public static func targetId(wsPath: String) -> String? {
        let prefix = "\(Self.scheme)://"
        guard wsPath.hasPrefix(prefix) else { return nil }
        let id = String(wsPath.dropFirst(prefix.count).prefix { $0 != "?" })
        return id.isEmpty ? nil : id
    }

    public func frames() -> AsyncThrowingStream<BrowserStreamEvent, Error> {
        let page = self.page
        let interval = self.interval
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let task = Task.detached(priority: .utility) {
                continuation.yield(.meta(url: URL(string: page.url), title: page.title))
                var tick = 0
                while !Task.isCancelled {
                    if let image = Self.render(page, tick: tick) {
                        continuation.yield(.frame(BrowserFrame(
                            image: image, pageURL: URL(string: page.url), cssSize: CGSize(width: 1280, height: 800),
                            sequence: tick + 1)))
                    }
                    tick += 1
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func render(_ page: BrowserDemoPages.Page, tick: Int) -> CGImage? {
        let width = 800, height = 500
        guard let context = ImageEncoding.bitmapContext(width: width, height: height, alpha: .premultipliedLast)
        else { return nil }
        let size = CGSize(width: width, height: height)
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // Page header band.
        context.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: size.height - 56, width: size.width, height: 56))
        Self.draw(page.title, in: context, x: 28, top: 36, size: 20, bold: true, white: true, height: size.height)
        Self.draw(page.heading, in: context, x: 40, top: 110, size: 32, bold: true, white: false, height: size.height)
        // The lines scroll by one row every few frames, looping.
        let rowHeight = 44.0
        let offset = Double(tick % (page.lines.count * 4)) / 4 * rowHeight
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: size.height - 150))
        for index in 0..<(page.lines.count * 2) {
            let top = 190 + Double(index) * rowHeight - offset
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1))
            context.fillEllipse(in: CGRect(x: 40, y: size.height - top - 14, width: 8, height: 8))
            Self.draw(page.lines[index % page.lines.count], in: context, x: 62, top: top, size: 18, bold: false,
                      white: false, height: size.height)
        }
        context.restoreGState()
        // Pointer.
        let angle = Double(tick) / 6
        let pointer = CGPoint(x: 560 + 120 * cos(angle), y: 250 + 70 * sin(angle * 1.3))
        context.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: pointer.x - 7, y: pointer.y - 7, width: 14, height: 14))
        return context.makeImage()
    }

    private static func draw(_ text: String, in context: CGContext, x: Double, top: Double, size: Double, bold: Bool,
                             white: Bool, height: Double)
    {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let color = white ? CGColor(gray: 1, alpha: 1) : CGColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any] as [NSAttributedString.Key: Any]))
        context.textPosition = CGPoint(x: x, y: height - top)
        CTLineDraw(line, context)
    }
}
