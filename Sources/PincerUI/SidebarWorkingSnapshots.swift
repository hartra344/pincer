#if os(macOS)
import AppKit
import PincerKit

/// Renders the sidebar's working indicator to PNGs for review:
/// `swift run PincerMacDev --sidebar-working-snapshots ~/Desktop/sidebar`.
public enum SidebarWorkingSnapshots {
    static let scale: CGFloat = 3
    static let forge = AgentSummary(id: "forge", name: "Forge", emoji: "🔨")

    /// Writes `sidebar-working.png` (every variant, light and dark) and `sidebar-working-dance.png`
    /// (the companion across one loop). Returns how many files it wrote.
    @MainActor
    public static func write(to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SidebarDance.scaleOverride = self.scale
        defer {
            SidebarDance.scaleOverride = nil
            SidebarDance.reduceMotionOverride = nil
        }
        try self.save(self.contactSheet(), to: directory.appending(path: "sidebar-working.png"))
        try self.save(self.filmstrip(), to: directory.appending(path: "sidebar-working-dance.png"))
        return 2
    }

    struct Variant {
        let title: String
        let agent: AgentSummary
        var companions = true
        var helpers = 0
        var reduceMotion = false
        var selected = false
        var unread = false
        /// An idle unread chat: the still avatar with the unread mark, not working.
        var idle = false
    }

    static let variants: [Variant] = [
        Variant(title: "Companion", agent: forge),
        Variant(title: "Emoji", agent: forge, companions: false),
        Variant(title: "Initials", agent: AgentSummary(id: "moki", name: "Moki"), companions: false),
        Variant(title: "Helpers 2", agent: forge, helpers: 2),
        Variant(title: "Helpers 9+", agent: forge, helpers: 12),
        Variant(title: "Reduce Motion", agent: forge, reduceMotion: true),
        Variant(title: "Selected", agent: forge, helpers: 2, reduceMotion: true, selected: true),
        Variant(title: "Idle unread", agent: forge, idle: true),
        Variant(title: "Working unread", agent: forge, unread: true),
        Variant(title: "Idle unread selected", agent: forge, selected: true, idle: true),
    ]

    static let cell = CGSize(width: 150, height: 30), header: CGFloat = 22, gutter: CGFloat = 44

    @MainActor
    static func contactSheet() -> CGImage? {
        let width = self.gutter + self.cell.width * CGFloat(self.variants.count)
        let height = self.header + self.cell.height * 2
        return self.draw(size: CGSize(width: width, height: height)) { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (i, variant) in self.variants.enumerated() {
                self.text(variant.title, at: CGPoint(x: self.gutter + CGFloat(i) * self.cell.width + 8, y: height - self.header + 6),
                          size: 11, weight: .semibold, color: .black)
            }
            for (row, dark) in [false, true].enumerated() {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let y = height - self.header - self.cell.height * CGFloat(row + 1)
                context.setFillColor(dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                    : CGColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: width, height: self.cell.height))
                self.text(dark ? "Dark" : "Light", at: CGPoint(x: 8, y: y + 8), size: 11, weight: .medium,
                          color: dark ? .white : .black)
                for (i, variant) in self.variants.enumerated() {
                    self.row(variant, appearance: appearance,
                             in: CGRect(x: self.gutter + CGFloat(i) * self.cell.width, y: y, width: self.cell.width,
                                        height: self.cell.height),
                             context: context)
                }
            }
        }
    }

    /// One sidebar row: the title and the real `SidebarWorkingAvatarView` at its trailing edge.
    @MainActor
    static func row(_ variant: Variant, appearance: NSAppearance, in rect: CGRect, context: CGContext) {
        let row = rect.insetBy(dx: 6, dy: 3)
        var titleColor = CGColor.black
        appearance.performAsCurrentDrawingAppearance {
            if variant.selected {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.addPath(CGPath(roundedRect: row, cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.fillPath()
            }
            titleColor = variant.selected ? .white : NSColor.labelColor.cgColor
        }
        self.text("Fix the parser", at: CGPoint(x: row.minX + 8, y: row.midY - 8), size: 13, weight: .regular, color: titleColor)

        let resolved = variant.idle
            ? SidebarWorkingIndicator.resolveUnread(isUnread: true, isSubagent: false, agent: variant.agent,
                                                    companionsEnabled: variant.companions)
            : SidebarWorkingIndicator.resolve(
                hasActiveRun: variant.helpers == 0, runningSubagents: variant.helpers, showSubagentRuns: false,
                agent: variant.agent, companionsEnabled: variant.companions, isUnread: variant.unread)
        guard let indicator = resolved else { return }
        SidebarDance.reduceMotionOverride = variant.reduceMotion
        let view = SidebarWorkingAvatarView()
        view.appearance = appearance
        view.isEmphasized = variant.selected
        view.configure(indicator, companion: variant.companions ? AvatarSettings.style(for: variant.agent, creature: "", renderStyle: "") : nil)
        view.layoutSubtreeIfNeeded()
        let side = SidebarWorkingAvatarView.side
        context.saveGState()
        context.translateBy(x: row.maxX - 10 - side, y: row.midY - side / 2)
        view.layer?.render(in: context)
        context.restoreGState()
    }

    /// The companion at eight evenly spaced points through one loop, with a baseline under its feet.
    @MainActor
    static func filmstrip() -> CGImage? {
        let frames = 8, cell = CGSize(width: 40, height: 44)
        let style = AvatarSettings.style(for: self.forge, creature: "", renderStyle: "")
        guard let art = SidebarDance.image(for: .companion, companion: style, dark: false,
                                           disc: NSColor.gray.cgColor, scale: self.scale) else { return nil }
        let size = CGSize(width: cell.width * CGFloat(frames), height: cell.height)
        return self.draw(size: size) { context in
            context.setFillColor(CGColor(srgbRed: 0.91, green: 0.91, blue: 0.92, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let side = SidebarDance.artSide
            for frame in 0 ..< frames {
                let progress = CGFloat(frame) / CGFloat(frames)
                let host = CALayer()
                host.frame = CGRect(origin: .zero, size: cell)
                let dancer = CALayer()
                dancer.anchorPoint = CGPoint(x: 0.5, y: 0)
                dancer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                dancer.position = CGPoint(x: cell.width / 2, y: 14)
                dancer.contents = art
                dancer.contentsScale = self.scale
                dancer.transform = SidebarDance.transform(at: progress, up: 1)
                host.addSublayer(dancer)
                context.saveGState()
                context.translateBy(x: CGFloat(frame) * cell.width, y: 0)
                context.setFillColor(CGColor(gray: 0.6, alpha: 1))
                context.fill(CGRect(x: 8, y: 13.5, width: cell.width - 16, height: 0.5))
                host.render(in: context)
                context.restoreGState()
                self.text(String(format: "%.3fs", progress * SidebarDance.duration),
                          at: CGPoint(x: CGFloat(frame) * cell.width + 7, y: 3), size: 8, weight: .regular, color: .black)
            }
        }
    }

    static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color) ?? .black,
        ]).draw(at: point)
    }

    static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * self.scale), height: Int(size.height * self.scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: self.scale, y: self.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func save(_ image: CGImage?, to url: URL) throws {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
#endif
