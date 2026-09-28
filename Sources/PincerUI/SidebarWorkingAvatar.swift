import CoreText
import PincerKit
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The sidebar row's working indicator: the chat's agent avatar doing a little looping hop, driven
/// entirely by Core Animation. Shared pieces for the AppKit and UIKit views below.
@MainActor
enum SidebarDance {
    static let animationKey = "pincer.sidebarDance"
    static let duration: CFTimeInterval = 1.0
    /// The art is drawn one point per pixel cell so the pixel style stays crisp; it may overhang
    /// the view's frame by a point, which never affects layout.
    static let artSide = SidebarAvatar.side
    static let dotSide: CGFloat = 7
    static let badgeHeight: CGFloat = 10
    static let badgeFontSize: CGFloat = 8

    static let keyTimes: [CGFloat] = [0, 0.08, 0.25, 0.42, 0.5, 0.58, 0.75, 0.92, 1]

    /// Two hops a loop: anticipate, hop up leaning one way, land with a squash, then the other way.
    /// `up` is the sign of "up" in the host layer's coordinates (+1 on macOS, -1 on iOS). Keyed by
    /// transform key path, one value per `keyTimes` entry.
    static func tracks(up: CGFloat) -> [(path: String, values: [CGFloat])] {
        let tilt = 6 * CGFloat.pi / 180
        return [
            ("transform.translation.y", [0, 0, 1.5 * up, 0, 0, 0, 1.5 * up, 0, 0]),
            ("transform.rotation.z", [0, 0, tilt, 0, 0, 0, -tilt, 0, 0]),
            ("transform.scale.x", [1, 1.06, 0.97, 1.06, 1, 1.06, 0.97, 1.06, 1]),
            ("transform.scale.y", [1, 0.94, 1.03, 0.94, 1, 0.94, 1.03, 0.94, 1]),
        ]
    }

    static func animation(up: CGFloat, offset: CFTimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = self.tracks(up: up).map { track in
            let animation = CAKeyframeAnimation(keyPath: track.path)
            animation.values = track.values
            animation.keyTimes = self.keyTimes.map { NSNumber(value: Double($0)) }
            animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: self.keyTimes.count - 1)
            return animation
        }
        group.duration = self.duration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timeOffset = offset
        return group
    }

    /// The dance's transform at `progress` (0...1) through a loop, eased like the animation.
    static func transform(at progress: CGFloat, up: CGFloat) -> CATransform3D {
        let i = max(self.keyTimes.lastIndex { $0 <= progress } ?? 0, 0)
        let j = min(i + 1, self.keyTimes.count - 1)
        let span = self.keyTimes[j] - self.keyTimes[i]
        let t = span > 0 ? (progress - self.keyTimes[i]) / span : 0
        let eased = t * t * (3 - 2 * t)
        let value = { (values: [CGFloat]) in values[i] + (values[j] - values[i]) * eased }
        let v = self.tracks(up: up).map { value($0.values) }
        var transform = CATransform3DMakeTranslation(0, v[0], 0)
        transform = CATransform3DRotate(transform, v[1], 0, 0, 1)
        return CATransform3DScale(transform, v[2], v[3], 1)
    }

    /// A stable phase in the loop for `seed`, so several working rows don't hop in lockstep.
    static func phase(for seed: String) -> CFTimeInterval {
        var hash: UInt32 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return Double(hash % 1000) / 1000 * self.duration
    }

    /// Forces Reduce Motion on or off; only the snapshot renderer sets it.
    static var reduceMotionOverride: Bool?
    /// Forces the bitmap scale; only the snapshot renderer sets it.
    static var scaleOverride: CGFloat?

    static func reduceMotion() -> Bool {
        if let reduceMotionOverride { return reduceMotionOverride }
        #if os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        return UIAccessibility.isReduceMotionEnabled
        #endif
    }

    // MARK: Images

    private static var cache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let image = self.cache[key] { return image }
        guard let image = make() else { return nil }
        if self.cache.count > 64 { self.cache.removeAll() }
        self.cache[key] = image
        return image
    }

    /// The avatar picture for `source`: the companion in a cheerful pose, or the emoji or initial
    /// on the theme's agent-avatar disc, like `Avatar`.
    static func image(for source: SidebarWorkingIndicator.Source, companion: AvatarStyle?, dark: Bool, disc: CGColor,
                      scale: CGFloat) -> CGImage?
    {
        let side = self.artSide
        switch source {
        case .companion:
            guard let companion else { return nil }
            return self.cached("companion|\(companion)|\(dark)|\(side)|\(scale)") {
                AvatarArt.image(companion, pose: AvatarMotion.keyPose(for: .success), dark: dark, accent: nil,
                                size: CGSize(width: side, height: side), scale: scale)
            }
        case let .emoji(text):
            return self.cached("emoji|\(text)|\(dark)|\(disc.components ?? [])|\(side)|\(scale)") {
                self.disc(text: text, emoji: true, color: disc, side: side, scale: scale)
            }
        case let .initials(text):
            return self.cached("initials|\(text)|\(dark)|\(disc.components ?? [])|\(side)|\(scale)") {
                self.disc(text: text, emoji: false, color: disc, side: side, scale: scale)
            }
        }
    }

    /// Bold count text for the helper-runs badge.
    static func badgeText(_ text: String, color: CGColor, scale: CGFloat) -> CGImage? {
        self.cached("badge|\(text)|\(color.components ?? [])|\(scale)") {
            let line = self.line(text, font: self.font(size: self.badgeFontSize, weight: .bold, rounded: false), color: color)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let size = CGSize(width: ceil(bounds.width), height: self.badgeHeight)
            return self.render(size: size, scale: scale) { context in
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                context.textPosition = CGPoint(x: -bounds.minX, y: (size.height - ascent + descent) / 2)
                CTLineDraw(line, context)
            }
        }
    }

    private static func disc(text: String, emoji: Bool, color: CGColor, side: CGFloat, scale: CGFloat) -> CGImage? {
        self.render(size: CGSize(width: side, height: side), scale: scale) { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            // Like SwiftUI's `Color.gradient`: a touch lighter at the top.
            let top = color.copy(alpha: 1).flatMap { self.lightened($0) } ?? color
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, color] as CFArray,
                                         locations: [0, 1])
            {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: .zero, options: [])
            }
            context.restoreGState()
            let font = emoji ? self.font(size: side * 0.55, weight: .regular, rounded: false)
                : self.font(size: side * 0.38, weight: .semibold, rounded: true)
            let line = self.line(text, font: font)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let baseline = emoji ? (side - ascent + descent) / 2 : (side - CTFontGetCapHeight(font)) / 2
            context.textPosition = CGPoint(x: (side - width) / 2, y: baseline)
            CTLineDraw(line, context)
        }
    }

    private static func lightened(_ color: CGColor) -> CGColor? {
        guard let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return nil }
        let mix = { (value: CGFloat) in value + (1 - value) * 0.18 }
        return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [mix(parts[0]), mix(parts[1]), mix(parts[2]), 1])
    }

    private static func font(size: CGFloat, weight: PFont.Weight, rounded: Bool) -> CTFont {
        let base = PFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base as CTFont }
        #if os(macOS)
        return (PFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #else
        return PFont(descriptor: descriptor, size: size) as CTFont
        #endif
    }

    private static func line(_ text: String, font: CTFont, color: CGColor = CGColor(gray: 1, alpha: 1)) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// A bitmap of `size` points drawn in Core Graphics' own y-up coordinates.
    private static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }
}

/// The layers both platforms' views host: the hopping avatar, the Reduce Motion activity dot and
/// the helper-runs count badge.
@MainActor
private final class SidebarDanceLayers {
    let dancer = CALayer()
    let dot = CALayer()
    let badge = CALayer()
    let badgeText = CALayer()
    /// +1 when the host layer's y axis points up (AppKit), -1 when it points down (UIKit).
    let up: CGFloat

    init(host: CALayer, up: CGFloat) {
        self.up = up
        self.dancer.anchorPoint = CGPoint(x: 0.5, y: up > 0 ? 0 : 1)
        self.dot.cornerRadius = SidebarDance.dotSide / 2
        self.dot.borderWidth = 1
        self.badge.cornerRadius = SidebarDance.badgeHeight / 2
        self.badge.borderWidth = 1
        self.badge.addSublayer(self.badgeText)
        for layer in [self.dancer, self.dot, self.badge] { host.addSublayer(layer) }
        self.disableActions()
    }

    private func disableActions() {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                        "hidden": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
        for layer in [self.dancer, self.dot, self.badge, self.badgeText] { layer.actions = none }
    }

    struct Look {
        var image: CGImage?
        var badge: String?
        var badgeImage: CGImage?
        /// The dot and badge fill; the badge text is drawn into `badgeImage`.
        var fill: CGColor
        var ring: CGColor
        var scale: CGFloat
        var reduceMotion: Bool
    }

    func apply(_ look: Look, in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let side = SidebarDance.artSide
        // Bottom of the art in host coordinates, where the avatar's feet (anchor) sit.
        let artBottom = self.up > 0 ? bounds.midY - side / 2 : bounds.midY + side / 2
        self.dancer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        self.dancer.position = CGPoint(x: bounds.midX, y: artBottom)
        self.dancer.contents = look.image
        self.dancer.contentsScale = look.scale

        let dot = SidebarDance.dotSide
        self.dot.isHidden = !look.reduceMotion
        self.dot.frame = CGRect(x: bounds.maxX - dot + 1, y: self.up > 0 ? bounds.minY - 1 : bounds.maxY - dot + 1,
                                width: dot, height: dot)
        self.dot.backgroundColor = look.fill
        self.dot.borderColor = look.ring

        self.badge.isHidden = look.badge == nil
        if look.badge != nil, let text = look.badgeImage {
            let textSize = CGSize(width: CGFloat(text.width) / look.scale, height: CGFloat(text.height) / look.scale)
            let height = SidebarDance.badgeHeight
            let width = max(height, textSize.width + 5)
            // Overhangs up and right, into the row's spare height and trailing padding.
            self.badge.frame = CGRect(x: bounds.maxX - width + 4, y: self.up > 0 ? bounds.maxY - height + 5 : bounds.minY - 5,
                                      width: width, height: height)
            self.badge.backgroundColor = look.fill
            self.badge.borderColor = look.ring
            self.badgeText.frame = CGRect(x: (width - textSize.width) / 2, y: (height - textSize.height) / 2,
                                          width: textSize.width, height: textSize.height)
            self.badgeText.contents = text
            self.badgeText.contentsScale = look.scale
        }
    }

    /// Starts the dance unless it's already running, so reconfiguring never restarts it.
    func setDancing(_ dancing: Bool, phase: CFTimeInterval) {
        if dancing {
            guard self.dancer.animation(forKey: SidebarDance.animationKey) == nil else { return }
            self.dancer.add(SidebarDance.animation(up: self.up, offset: phase), forKey: SidebarDance.animationKey)
        } else {
            self.dancer.removeAnimation(forKey: SidebarDance.animationKey)
        }
    }
}

#if os(macOS)

/// The mini spinner's 16pt footprint, with the avatar hopping in it.
final class SidebarWorkingAvatarView: NSView {
    private var layers: SidebarDanceLayers!
    private var indicator: SidebarWorkingIndicator?
    private var companion: AvatarStyle?
    private var phase: CFTimeInterval = 0
    /// On an emphasized (accent) selection the dot and badge turn white so they stand out.
    var isEmphasized = false {
        didSet { if self.isEmphasized != oldValue { self.refresh() } }
    }

    static let side: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .never
        self.layers = SidebarDanceLayers(host: self.layer!, up: 1)
        self.setAccessibilityElement(false)
        self.setContentHuggingPriority(.required, for: .horizontal)
        self.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(self.reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// Shows `indicator`; `companion` is the agent's companion style when animated avatars are on.
    /// `phaseSeed` (the row's key) staggers the dance between rows.
    func configure(_ indicator: SidebarWorkingIndicator, companion: AvatarStyle?, phaseSeed: String? = nil) {
        self.indicator = indicator
        self.companion = companion
        self.phase = SidebarDance.phase(for: phaseSeed ?? indicator.agentId)
        self.toolTip = indicator.label
        self.setAccessibilityLabel(indicator.label)
        // Cheap: images come from the cache. Picks up theme color changes on reconfigure too.
        self.refresh()
    }

    /// Stops the dance and forgets the indicator.
    func stop() {
        self.indicator = nil
        self.companion = nil
        self.layers.setDancing(false, phase: 0)
        self.toolTip = nil
    }

    private var isVisible: Bool { self.window != nil && !self.isHiddenOrHasHiddenAncestor }

    private func updateDancing() {
        self.layers.setDancing(self.indicator != nil && self.isVisible && !SidebarDance.reduceMotion(), phase: self.phase)
    }

    private func refresh() {
        guard let indicator else { return }
        var look: SidebarDanceLayers.Look?
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scale = SidebarDance.scaleOverride ?? self.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let tint = TranscriptColors.tint.cgColor
            let (fill, text) = self.isEmphasized ? (CGColor.white, tint) : (tint, CGColor.white)
            look = SidebarDanceLayers.Look(
                image: SidebarDance.image(for: indicator.source, companion: self.companion, dark: dark,
                                          disc: TranscriptColors.agentAvatar.cgColor, scale: scale),
                badge: indicator.badge,
                badgeImage: indicator.badge.flatMap { SidebarDance.badgeText($0, color: text, scale: scale) },
                fill: fill,
                ring: self.isEmphasized ? .clear : NSColor.windowBackgroundColor.cgColor,
                scale: scale, reduceMotion: SidebarDance.reduceMotion())
        }
        if let look { self.layers.apply(look, in: self.bounds) }
        self.updateDancing()
    }

    override func layout() {
        super.layout()
        self.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil { self.layers.setDancing(false, phase: 0) } else { self.refresh() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        self.layers.setDancing(false, phase: 0)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        self.updateDancing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.refresh()
    }

    @objc private func reduceMotionChanged() {
        self.refresh()
    }
}

#else

/// The medium activity indicator's footprint, with the avatar hopping in it.
final class SidebarWorkingAvatarView: UIView {
    private var layers: SidebarDanceLayers!
    private var indicator: SidebarWorkingIndicator?
    private var companion: AvatarStyle?
    private var phase: CFTimeInterval = 0
    /// On a tinted selection the dot and badge turn white so they stand out.
    var isEmphasized = false {
        didSet { if self.isEmphasized != oldValue { self.refresh() } }
    }

    /// `UIActivityIndicatorView(style: .medium)`'s fitted size, so swapping it in shifts nothing.
    static let side: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        self.layers = SidebarDanceLayers(host: self.layer, up: -1)
        self.isAccessibilityElement = false
        self.isUserInteractionEnabled = false
        self.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: Self, _) in
            view.refresh()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { self.intrinsicContentSize }

    override var isHidden: Bool {
        didSet { if self.isHidden != oldValue { self.updateDancing() } }
    }

    /// Shows `indicator`; `companion` is the agent's companion style when animated avatars are on.
    /// `phaseSeed` (the row's key) staggers the dance between rows.
    func configure(_ indicator: SidebarWorkingIndicator, companion: AvatarStyle?, phaseSeed: String? = nil) {
        self.indicator = indicator
        self.companion = companion
        self.phase = SidebarDance.phase(for: phaseSeed ?? indicator.agentId)
        self.accessibilityLabel = indicator.label
        // Cheap: images come from the cache. Picks up theme color changes on reconfigure too.
        self.refresh()
    }

    /// Stops the dance and forgets the indicator.
    func stop() {
        self.indicator = nil
        self.companion = nil
        self.layers.setDancing(false, phase: 0)
    }

    private var isVisible: Bool { self.window != nil && !self.isHidden }

    private func updateDancing() {
        self.layers.setDancing(self.indicator != nil && self.isVisible && !SidebarDance.reduceMotion(), phase: self.phase)
    }

    private func refresh() {
        guard let indicator else { return }
        let traits = self.traitCollection
        let scale = max(traits.displayScale, 1)
        let tint = TranscriptColors.tint.resolvedColor(with: traits).cgColor
        let white = UIColor.white.cgColor
        let (fill, text) = self.isEmphasized ? (white, tint) : (tint, white)
        let look = SidebarDanceLayers.Look(
            image: SidebarDance.image(for: indicator.source, companion: self.companion, dark: traits.userInterfaceStyle == .dark,
                                      disc: TranscriptColors.agentAvatar.resolvedColor(with: traits).cgColor, scale: scale),
            badge: indicator.badge,
            badgeImage: indicator.badge.flatMap { SidebarDance.badgeText($0, color: text, scale: scale) },
            fill: fill,
            ring: self.isEmphasized ? UIColor.clear.cgColor : UIColor.systemBackground.resolvedColor(with: traits).cgColor,
            scale: scale, reduceMotion: SidebarDance.reduceMotion())
        self.layers.apply(look, in: self.bounds)
        self.updateDancing()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.refresh()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil { self.layers.setDancing(false, phase: 0) } else { self.refresh() }
    }

    @objc private func reduceMotionChanged() {
        self.refresh()
    }
}

#endif
