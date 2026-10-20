import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Avatars repeat on every row, and drawing emoji is slow, so each distinct avatar is drawn once
/// into a bitmap that the rows share as layer contents.
final class TranscriptAvatarView: TranscriptBaseView {
    private static var cache: [String: CGImage] = [:]
    private var avatar: TranscriptPart.Avatar?
    private var key: String?

    /// The row it's attached to in the live avatar, which animates the latest reply's avatar.
    var liveRowId: String?
    private weak var liveController: TranscriptLiveAvatar?
    /// Set by the live avatar: the chat's state, and the frame to draw (nil holds the still pose).
    private var liveFrame: (state: AvatarState, pose: AvatarPose?)?

    var agentSeed: String { self.avatar?.seed ?? "" }
    var isPlush: Bool { self.avatar?.creature?.renderStyle == .plush }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .avatar(avatar) = part else { return }
        self.avatar = avatar
        if avatar.isAgent, let live = actions.liveAvatar {
            self.liveController = live
            live.attach(self, rowId: row.id, style: avatar.creature)
        } else {
            self.liveController?.detach(self)
            self.liveFrame = nil
        }
        self.refresh()
    }

    override func didHide() {
        self.liveController?.detach(self)
        self.liveFrame = nil
    }

    func showLive(_ frame: (state: AvatarState, pose: AvatarPose?)?) {
        if frame == nil, self.liveFrame == nil { return }
        self.liveFrame = frame
        self.key = nil
        self.refresh()
    }

    override func layoutContent() { self.refresh() }
    override func appearanceChanged() { self.refresh() }

    #if os(macOS)
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        self.key = nil
        self.refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.liveController?.moved(self)
    }

    private var scale: CGFloat { self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var isDark: Bool { self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.liveController?.moved(self)
    }

    private var scale: CGFloat { max(self.traitCollection.displayScale, 1) }
    private var isDark: Bool { self.traitCollection.userInterfaceStyle == .dark }
    #endif

    private func refresh() {
        guard let avatar, self.bounds.width > 0 else { return }
        if let creature = avatar.creature {
            self.refresh(creature, state: avatar.state)
            return
        }
        let top = self.resolved(lighten(avatar.color, by: 0.18)), bottom = self.resolved(avatar.color)
        let size = self.bounds.size, scale = self.scale
        let key = "\(avatar.text)|\(avatar.emoji ?? "")|\(avatar.symbol ?? "")|\(top.components ?? [])|\(bottom.components ?? [])|\(size.width)|\(scale)"
        guard key != self.key else { return }
        self.key = key
        let image = Self.cache[key] ?? Self.render(avatar, top: top, bottom: bottom, size: size, scale: scale)
        if let image {
            if Self.cache.count > 64 { Self.cache.removeAll() }
            Self.cache[key] = image
        }
        withoutLayerAnimations {
            self.hostLayer.contentsScale = scale
            self.hostLayer.contents = image
        }
    }

    /// The companion's pose for the row. Still poses are drawn once per look and shared like the
    /// initials; the live avatar's moving frames are drawn fresh each time.
    private func refresh(_ style: AvatarStyle, state: AvatarState) {
        let size = self.bounds.size, scale = self.scale, dark = self.isDark
        let state = self.liveFrame?.state ?? state
        let accent = AvatarArt.showsGlow(state) ? self.resolved(TranscriptColors.tint) : nil
        let badge = AgentAvatarView.badgeSymbol(for: state)
        let image: CGImage?
        if let pose = self.liveFrame?.pose {
            self.key = nil
            // Animated poses cycle through a few looks, so redraws reuse a bounded cache of bitmaps.
            let key = "live|\(style)|\(state)|\(pose.hashValue)|\(dark)|\(accent?.components ?? [])|\(size.width)|\(scale)"
            image = Self.cache[key] ?? AvatarArt.image(style, pose: pose, dark: dark, accent: accent, badge: badge, size: size, scale: scale)
            if let image {
                if Self.cache.count > 64 { Self.cache.removeAll() }
                Self.cache[key] = image
            }
        } else {
            let key = "creature|\(style)|\(state)|\(dark)|\(accent?.components ?? [])|\(size.width)|\(scale)"
            guard key != self.key else { return }
            self.key = key
            image = Self.cache[key] ?? AvatarArt.image(style, pose: AvatarMotion.keyPose(for: state), dark: dark,
                                                       accent: accent, badge: badge, size: size, scale: scale)
            if let image {
                if Self.cache.count > 64 { Self.cache.removeAll() }
                Self.cache[key] = image
            }
        }
        withoutLayerAnimations {
            self.hostLayer.contentsScale = scale
            self.hostLayer.contents = image
        }
    }

    private static func render(_ avatar: TranscriptPart.Avatar, top: CGColor, bottom: CGColor,
                               size: CGSize, scale: CGFloat) -> CGImage?
    {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Top-left origin, in points, to match how the rest of the transcript draws.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addEllipse(in: bounds)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }
        context.restoreGState()
        #if os(macOS)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif
        if let symbol = avatar.symbol {
            TranscriptSymbols.draw(symbol, in: bounds.insetBy(dx: size.width * 0.22, dy: size.height * 0.22),
                                   size: size.width * 0.46, weight: .semibold, color: .white)
            return context.makeImage()
        }
        let text: NSAttributedString = if let emoji = avatar.emoji {
            NSAttributedString(string: emoji, attributes: [.font: PFont.systemFont(ofSize: size.width * 0.55)])
        } else {
            NSAttributedString(string: avatar.text, attributes: [
                .font: TranscriptStyle.rounded(size: size.width * 0.38, weight: .semibold),
                .foregroundColor: PColor.white,
            ])
        }
        let textSize = text.size()
        text.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2))
        return context.makeImage()
    }
}

final class TranscriptTypingView: TranscriptBaseView {
    private let dots = (0..<3).map { _ in CALayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (index, dot) in self.dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 10, y: 4, width: 6, height: 6)
            dot.cornerRadius = 3
            self.hostLayer.addSublayer(dot)
        }
        self.appearanceChanged()
        #if os(macOS)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.progressIndicator)
        self.setAccessibilityLabel(L("Working"))
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = L("Working")
        #endif
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.animate()
    }

    override func appearanceChanged() {
        withoutLayerAnimations {
            for dot in self.dots { dot.backgroundColor = self.resolved(TranscriptColors.secondary) }
        }
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil { self.animate() }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil { self.animate() }
    }
    #endif

    private func animate() {
        for (index, dot) in self.dots.enumerated() where dot.animation(forKey: "pulse") == nil {
            let steps = 24
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = (0...steps).map { step in
                let phase = Double(step) / Double(steps) * .pi * 2
                return 0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.8))
            }
            animation.duration = 1.2
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: "pulse")
        }
    }
}

final class TranscriptMarkerView: TranscriptBaseView {
    private var label = ""

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        guard case let .marker(label) = part else { return }
        guard label != self.label else { return }
        self.label = label
        #if os(macOS)
        self.toolTip = label.hasPrefix("Context") ? L("Earlier messages were summarized for the agent. They're still shown here.") : nil
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel(label)
        #else
        self.isAccessibilityElement = true
        self.accessibilityLabel = label
        #endif
        self.redraw()
    }

    override func draw(_ rect: CGRect) {
        let style = TranscriptStyle.shared
        let bounds = self.bounds
        let text = singleLine(self.label, style.caption, TranscriptColors.secondary)
        let textWidth = min(text.lineWidth, bounds.width - 60)
        let contentWidth = 14 + 4 + textWidth
        let x = (bounds.width - contentWidth) / 2
        let lineHeight = TranscriptStyle.lineHeight(style.caption)
        let y = (bounds.height - lineHeight) / 2
        let symbol = self.label.hasPrefix("Context") || self.label.hasPrefix("Compacting") ? "archivebox" : "sparkle"
        TranscriptSymbols.draw(symbol, in: CGRect(x: x, y: y, width: 14, height: lineHeight), size: style.caption.pointSize, color: TranscriptColors.secondary)
        text.drawLine(at: CGPoint(x: x + 18, y: y), width: textWidth, font: style.caption)
        TranscriptColors.separator.setFill()
        let midY = floor(bounds.midY)
        PBezierPath(rect: CGRect(x: 0, y: midY, width: max(x - 8, 0), height: 1)).fill()
        let rightX = x + contentWidth + 8
        PBezierPath(rect: CGRect(x: rightX, y: midY, width: max(bounds.width - rightX, 0), height: 1)).fill()
    }
}

final class TranscriptLoadingView: TranscriptBaseView {
    private let spinner = TranscriptSpinner(size: 16)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.spinner)
    }

    override func configure(_ part: TranscriptPart, row: TranscriptRowLayout, actions: TranscriptRowActions) {
        self.spinner.setAnimating(true)
    }

    override func didHide() {
        self.spinner.setAnimating(false)
    }

    override func layoutContent() {
        self.spinner.place(center: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
    }
}
