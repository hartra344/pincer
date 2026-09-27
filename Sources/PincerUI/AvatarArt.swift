import CoreGraphics
import Foundation
import PincerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws the companion creatures. Plain CoreGraphics, so the animated SwiftUI view (through
/// `Canvas`) and the transcript's cached bitmaps share one renderer. Everything is laid out on a
/// 16×16 pixel grid; the drawing area is 18×18 cells so hops, bubbles and the "z" have room.
enum AvatarArt {
    /// Cells across the drawing area.
    static let canvasCells: CGFloat = 18
    /// Where the creature's 16×16 grid sits in the drawing area.
    static let origin = CGPoint(x: 1, y: 1)

    /// A soft accent halo and thin ring behind the creature while the agent is doing something.
    /// The theme accent only ever tints this and the badge, never the creature itself.
    static func drawGlow(accent: CGColor, in context: CGContext, rect: CGRect) {
        let side = min(rect.width, rect.height)
        let circle = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let line = max(side / 36, 0.75)
        context.saveGState()
        defer { context.restoreGState() }
        let space = CGColorSpaceCreateDeviceRGB()
        if let halo = CGGradient(colorsSpace: space, colors: [accent.copy(alpha: 0.2), accent.copy(alpha: 0.02)]
            .compactMap { $0 } as CFArray, locations: [0.55, 1])
        {
            context.addEllipse(in: circle)
            context.clip()
            let center = CGPoint(x: circle.midX, y: circle.midY)
            context.drawRadialGradient(halo, startCenter: center, startRadius: 0, endCenter: center, endRadius: side / 2,
                                       options: [])
            context.resetClip()
        }
        context.setStrokeColor(accent.copy(alpha: 0.4) ?? accent)
        context.setLineWidth(line)
        context.strokeEllipse(in: circle.insetBy(dx: line / 2, dy: line / 2))
    }

    /// Whether the glow shows: whenever the agent is doing something, not when it's resting.
    static func showsGlow(_ state: AvatarState) -> Bool { state != .idle }

    /// Draws into a new bitmap of `size` points, for the AppKit and UIKit views (transcript,
    /// sidebar) that show avatars as layer contents: the glow when `accent` is set, the creature,
    /// then `badge` (an SF Symbol) in the bottom-right corner.
    @MainActor
    static func image(_ style: AvatarStyle, pose: AvatarPose, dark: Bool, accent: CGColor?, badge: String? = nil,
                      size: CGSize, scale: CGFloat) -> CGImage?
    {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let rect = CGRect(origin: .zero, size: size)
        if let accent { self.drawGlow(accent: accent, in: context, rect: rect) }
        self.draw(style, pose: pose, dark: dark, in: context, rect: rect)
        if let badge, let accent { self.drawBadge(badge, accent: accent, dark: dark, in: context, rect: rect) }
        return context.makeImage()
    }

    /// The state's SF Symbol on a small disc, tinted with the accent.
    @MainActor
    static func drawBadge(_ symbol: String, accent: CGColor, dark: Bool, in context: CGContext, rect: CGRect) {
        let side = max(min(rect.width, rect.height) * 0.42, 9)
        let disc = CGRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
        let line = max(side * 0.07, 0.75)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(dark ? Colors.rgb(0x1F1F22) : Colors.rgb(0xFFFFFF))
        context.fillEllipse(in: disc)
        context.setStrokeColor(accent.copy(alpha: 0.45) ?? accent)
        context.setLineWidth(line)
        context.strokeEllipse(in: disc.insetBy(dx: line / 2, dy: line / 2))
        let point = side * 0.58
        #if os(macOS)
        guard let color = NSColor(cgColor: accent),
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
              .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: point, weight: .bold)
                  .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return }
        let fit = image.size
        let target = CGRect(x: disc.midX - fit.width / 2, y: disc.midY - fit.height / 2, width: fit.width, height: fit.height)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current = previous
        #else
        guard let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: point, weight: .bold))?
            .withTintColor(UIColor(cgColor: accent), renderingMode: .alwaysOriginal) else { return }
        let fit = image.size
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: disc.midX - fit.width / 2, y: disc.midY - fit.height / 2, width: fit.width, height: fit.height))
        UIGraphicsPopContext()
        #endif
    }

    @MainActor private static var stills: [String: CGImage] = [:]

    /// A state's still pose (with the glow while busy, no badge), cached, for small avatars that
    /// never move, like the sidebar's.
    @MainActor
    static func still(_ style: AvatarStyle, state: AvatarState, dark: Bool, accent: CGColor, side: CGFloat,
                      scale: CGFloat) -> CGImage?
    {
        let glow = self.showsGlow(state) ? accent : nil
        let key = "\(style)|\(state)|\(dark)|\(glow?.components ?? [])|\(side)|\(scale)"
        if let image = self.stills[key] { return image }
        let image = self.image(style, pose: AvatarMotion.keyPose(for: state), dark: dark, accent: glow,
                               size: CGSize(width: side, height: side), scale: scale)
        if self.stills.count > 64 { self.stills.removeAll() }
        self.stills[key] = image
        return image
    }

    /// Draws `style` in `pose` into `rect` of a context with a top-left origin (y down).
    static func draw(_ style: AvatarStyle, pose: AvatarPose, dark: Bool, in context: CGContext, rect: CGRect) {
        let colors = Colors(style.palette, dark: dark)
        let cell = min(rect.width, rect.height) / self.canvasCells
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX + (rect.width - cell * self.canvasCells) / 2,
                            y: rect.minY + (rect.height - cell * self.canvasCells) / 2)
        context.scaleBy(x: cell, y: cell)
        context.translateBy(x: self.origin.x, y: self.origin.y)
        context.saveGState()
        // Squash and stretch about the feet; tilt (plush only) about the middle of the body.
        // A plain blob has nothing on top to twitch, so it wiggles instead.
        let plainBlob = style.creature == .blob && style.accessory != .hat && style.accessory != .antenna
        let sway = pose.sway + (plainBlob ? pose.twitch : 0)
        context.translateBy(x: 8 + CGFloat(sway), y: 15 + CGFloat(pose.bob))
        if style.renderStyle == .plush, pose.tilt != 0 { context.rotate(by: pose.tilt * .pi / 180) }
        if pose.squash != 1 { context.scaleBy(x: pose.squash, y: 1 / pose.squash) }
        context.translateBy(x: -8, y: -15)
        let spec = Spec.for(style.creature)
        switch style.renderStyle {
        case .pixel:
            context.setShouldAntialias(false)
            PixelArt.draw(spec, style: style, pose: pose, colors: colors, in: context)
            context.setShouldAntialias(true)
        case .plush:
            PlushArt.draw(spec, style: style, pose: pose, colors: colors, in: context)
        }
        context.restoreGState()
        Extras.draw(pose, colors: colors, pixel: style.renderStyle == .pixel, in: context)
    }

    // MARK: Colors

    struct Colors {
        let body, bodyLight, shade, face, belly, outline, eye, blush: CGColor
        let beak, beakDark, leaf, leafDark, hat, hatDark, trim, bow, bowDark, petal, petalDark, pollen: CGColor
        let sweat, bubble, bubbleEdge, ink: CGColor

        init(_ palette: AvatarPalette, dark: Bool) {
            let (body, face): (UInt32, UInt32) = switch palette {
            case .cream: (0xF1E2C6, 0xFFF7EA)
            case .apricot: (0xF0A45C, 0xFCE2C2)
            case .moss: (0xAACB8C, 0xEEF5DF)
            case .stone: (0xB9B3AA, 0xECE7DF)
            case .peach: (0xF4B3A0, 0xFFE8DE)
            case .lilac: (0xC7B2E6, 0xF3ECFB)
            case .sky: (0xA6CDEB, 0xE7F3FC)
            }
            self.body = Self.rgb(body)
            self.bodyLight = Self.rgb(Self.mix(body, 0xFFFFFF, 0.35))
            self.shade = Self.rgb(Self.mix(body, Self.darker(body), 0.35))
            self.face = Self.rgb(face)
            self.belly = Self.rgb(Self.mix(body, face, 0.7))
            // Outlines are a deep shade of the body's own hue, never black; a touch lighter in
            // dark mode so the silhouette doesn't sink into the background.
            self.outline = Self.rgb(dark ? Self.mix(Self.darker(body), body, 0.25) : Self.darker(body))
            self.eye = Self.rgb(Self.mix(Self.darker(body), 0x000000, 0.55))
            self.blush = Self.rgb(palette == .peach ? 0xEE8A98 : 0xF5A3AE)
            self.beak = Self.rgb(palette == .apricot ? 0xC8702C : 0xEE9A45)
            self.beakDark = Self.rgb(palette == .apricot ? 0x80431A : 0xA5602A)
            self.leaf = Self.rgb(0x8CC265)
            self.leafDark = Self.rgb(0x4B7A34)
            self.hat = Self.rgb(palette == .peach ? 0x8FB7E0 : 0xEE7B72)
            self.hatDark = Self.rgb(palette == .peach ? 0x4E7196 : 0x9E4640)
            self.trim = Self.rgb(0xFFF8EE)
            self.bow = Self.rgb(palette == .lilac ? 0xF08FA8 : 0xF28AB6)
            self.bowDark = Self.rgb(0xA24C72)
            self.petal = Self.rgb(palette == .peach ? 0xFFFFFF : 0xF9B7CF)
            self.petalDark = Self.rgb(0xB9708C)
            self.pollen = Self.rgb(0xFFD46A)
            self.sweat = Self.rgb(0x8FD0F5)
            self.bubble = Self.rgb(dark ? 0x3A3A40 : 0xFFFFFF)
            self.bubbleEdge = Self.rgb(dark ? 0x8A8A94 : 0xB8B2AA)
            self.ink = Self.rgb(dark ? 0xE8E6E2 : 0x6A625A)
        }

        static func rgb(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
            func channel(_ shift: UInt32) -> UInt32 {
                let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
                return UInt32((x + (y - x) * t).rounded()) << shift
            }
            return channel(16) | channel(8) | channel(0)
        }

        /// Same hue, much darker and a little more saturated.
        static func darker(_ hex: UInt32) -> UInt32 {
            let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
            let mean = (r + g + b) / 3
            func channel(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (mean + (v - mean) * 1.5) * 0.45)).rounded()) }
            return channel(r) << 16 | channel(g) << 8 | channel(b)
        }
    }

    // MARK: Creatures

    struct P: Hashable, Sendable {
        var x: Int, y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }

    enum Role: UInt8, Sendable {
        case body, shade, face, belly, beak, leaf, stem, hat, trim, bow, knot, petal, pollen, antenna, bobble

        var fillsOutline: Bool { self == .body || self == .shade || self == .face || self == .belly }
    }

    /// One creature's pixel layout. Rows are 16 characters: `b` body, `s` shade, `f` face plate,
    /// `l` belly, `y` beak or talons, `.` empty. Outlines are added around whatever is filled.
    struct Spec: Sendable {
        let creature: AvatarCreature
        let body: [P: Role]
        let leftEye: P, rightEye: P
        let blushRow: Int
        let mouthRow: Int?
        /// Columns of the arm nubs just outside the body, and the row they hang from.
        let leftArm: Int, rightArm: Int, armRow: Int
        /// Top row of the head, for hats.
        let headTop: Int
        /// Tufts, leaves or stones on top; they twitch while a tool runs.
        let top: @Sendable (Int) -> [P: Role]

        static func `for`(_ creature: AvatarCreature) -> Spec {
            switch creature {
            case .blob: self.blob
            case .owl: self.owl
            case .rock: self.rock
            case .sprout: self.sprout
            }
        }

        static func parse(_ rows: [String]) -> [P: Role] {
            var cells: [P: Role] = [:]
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() {
                    let role: Role? = switch char {
                    case "b": .body
                    case "s": .shade
                    case "f": .face
                    case "l": .belly
                    case "y": .beak
                    case "g": .leaf
                    case "t": .stem
                    default: nil
                    }
                    if let role { cells[P(x, y)] = role }
                }
            }
            return cells
        }

        static let blob = Spec(
            creature: .blob,
            body: parse([
                "................",
                "................",
                "................",
                ".....bbbbbb.....",
                "...bbbbbbbbbb...",
                "..bbbbbbbbbbbb..",
                "..bbbbffffbbbb..",
                "..bbbffffffbbb..",
                "..bbffffffffbb..",
                "..bbffffffffbb..",
                "..bbffffffffbb..",
                "..bbbffffffbbb..",
                "..bbbbbbbbbbbb..",
                "...sbbbbbbbbs...",
                "....ss....ss....",
            ]),
            leftEye: P(5, 9), rightEye: P(10, 9), blushRow: 10, mouthRow: 10,
            leftArm: 1, rightArm: 14, armRow: 11, headTop: 3,
            // A plain hood; while a tool runs the whole blob wiggles instead.
            top: { _ in [:] })

        static let owl = Spec(
            creature: .owl,
            body: parse([
                "................",
                "................",
                "................",
                "................",
                "...bbbbbbbbbb...",
                "..bbbbbbbbbbbb..",
                "..bffffbbffffb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bbffffffffbb..",
                "..bbbbllllbbbb..",
                "..sbblsllslbbs..",
                "..sbbllllllbbs..",
                "...sbllsslbbs...",
                "....yy....yy....",
            ]).merging([P(7, 9): .beak, P(8, 9): .beak]) { $1 },
            leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: nil,
            leftArm: 1, rightArm: 14, armRow: 10, headTop: 4,
            top: { twitch in
                // Ear tufts; they flick outward.
                twitch == 0
                    ? [P(3, 3): .body, P(2, 2): .body, P(12, 3): .body, P(13, 2): .body]
                    : [P(3, 3): .body, P(2, 3): .body, P(12, 3): .body, P(13, 3): .body]
            })

        static let rock = Spec(
            creature: .rock,
            body: parse([
                "................",
                "................",
                "................",
                "................",
                "...bbbbbbbbbb...",
                "..bbbbbbbbbbbb..",
                "..bbffffffffbb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bbffffffffbb..",
                "..bbbbbbbbbbbb..",
                "..bbbbbbbbbbbb..",
                "..sbbbbbbbbbbs..",
                "...ss......ss...",
            ]),
            leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 9,
            leftArm: 1, rightArm: 14, armRow: 11, headTop: 4,
            top: { twitch in
                // Pebbles on its head; the small one hops.
                [P(5, 3): .shade, P(6, 3): .shade, P(10, twitch == 0 ? 3 : 2): .shade]
            })

        static let sprout = Spec(
            creature: .sprout,
            body: parse([
                "................",
                "................",
                "................",
                "................",
                "...bbbbbbbbbb...",
                "..bbbbbbbbbbbb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bffffffffffb..",
                "..bbbbbbbbbbbb..",
                "...sbbbbbbbbs...",
                ".....bbbbbb.....",
                ".....bbbbbb.....",
                ".....ss..ss.....",
            ]),
            leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 9,
            leftArm: 4, rightArm: 11, armRow: 12, headTop: 4,
            top: { twitch in
                // A stem and two leaves; they perk up.
                let lift = twitch == 0 ? 0 : 1
                var cells: [P: Role] = [P(7, 3): .stem, P(7, 2 - lift): .stem]
                if lift == 1 { cells[P(7, 2)] = .stem }
                for p in [P(4, 1), P(5, 1), P(3, 2), P(4, 2), P(5, 2), P(6, 2)] { cells[P(p.x, p.y - lift)] = .leaf }
                for p in [P(9, 0), P(10, 0), P(8, 1), P(9, 1), P(10, 1), P(11, 1)] { cells[P(p.x, p.y - lift)] = .leaf }
                return cells
            })
    }
}

// MARK: - Pixel

private enum PixelArt {
    typealias P = AvatarArt.P
    typealias Role = AvatarArt.Role

    static func draw(_ spec: AvatarArt.Spec, style: AvatarStyle, pose: AvatarPose, colors: AvatarArt.Colors,
                     in context: CGContext)
    {
        var cells = spec.body
        cells.merge(spec.top(pose.twitch)) { old, _ in old }
        for (arm, x, side) in [(pose.leftArm, spec.leftArm, -1), (pose.rightArm, spec.rightArm, 1)] {
            for p in self.arm(arm, x: x, row: spec.armRow, side: side) { cells[p] = .body }
        }
        cells.merge(self.accessory(style.accessory, spec: spec, twitch: pose.twitch)) { _, new in new }

        // Outline every empty cell next to a filled one, in the darker shade of what it borders.
        var outline: [P: CGColor] = [:]
        for (p, role) in cells {
            for n in [P(p.x - 1, p.y), P(p.x + 1, p.y), P(p.x, p.y - 1), P(p.x, p.y + 1)] where cells[n] == nil {
                let color = self.outlineColor(role, colors)
                if outline[n] == nil || role.fillsOutline { outline[n] = color }
            }
        }
        for (p, color) in outline { self.fill(p, color, context) }
        for (p, role) in cells { self.fill(p, self.color(role, colors), context) }

        // Face.
        for x in [spec.leftEye.x - 1, spec.leftEye.x, spec.rightEye.x, spec.rightEye.x + 1] {
            self.fill(P(x, spec.blushRow), colors.blush, context)
        }
        if style.accessory == .glasses { self.glasses(spec, colors, context) }
        // The ^ ^ eyes alone read as happy; with the "u" too they crowd into a grin.
        if pose.mouth, pose.eyes != .happy, let row = spec.mouthRow {
            // A tiny "u" in half pixels.
            let y = CGFloat(row)
            context.setFillColor(colors.eye)
            context.fill(CGRect(x: 6.5, y: y, width: 0.5, height: 0.5))
            context.fill(CGRect(x: 7, y: y + 0.5, width: 2, height: 0.5))
            context.fill(CGRect(x: 9, y: y, width: 0.5, height: 0.5))
        }
        for eye in [spec.leftEye, spec.rightEye] {
            let p = P(eye.x, eye.y + pose.gaze)
            switch pose.eyes {
            case .open:
                self.fill(p, colors.eye, context)
            case .closed:
                context.setFillColor(colors.eye)
                context.fill(CGRect(x: CGFloat(p.x) - 0.25, y: CGFloat(p.y) + 0.4, width: 1.5, height: 0.4))
            case .happy:
                // Feet on the eye row, apex above, clear of the blush row.
                self.fill(P(p.x - 1, p.y), colors.eye, context)
                self.fill(P(p.x, p.y - 1), colors.eye, context)
                self.fill(P(p.x + 1, p.y), colors.eye, context)
            }
        }
    }

    static func arm(_ arm: AvatarPose.Arm, x: Int, row: Int, side: Int) -> [P] {
        switch arm {
        case .down: [P(x, row), P(x, row + 1)]
        case .tap: [P(x, row - 1), P(x, row)]
        // Out and up from the side, clear of the head so it reads as an arm, not an ear.
        case let .up(wave): [P(x, row), P(x + side, row - 1), P(x + side * 2, row - 2), P(x + side * (2 - wave), row - 3)]
        }
    }

    static func accessory(_ accessory: AvatarAccessory, spec: AvatarArt.Spec, twitch: Int) -> [P: Role] {
        let top = spec.headTop
        switch accessory {
        case .none, .glasses:
            return [:]
        case .hat:
            var cells: [P: Role] = [:]
            for x in 5...10 { cells[P(x, top - 1)] = .hat }
            for x in 4...11 { cells[P(x, top)] = .trim }
            cells[P(twitch == 0 ? 7 : 8, top - 2)] = .trim
            cells[P(twitch == 0 ? 8 : 9, top - 2)] = .trim
            return cells
        case .antenna:
            let tip = twitch == 0 ? 7 : 8
            return [P(7, top - 1): .antenna, P(tip, top - 2): .antenna, P(tip, top - 3): .bobble]
        case .leaf:
            let (x, y) = (11, top + 1)
            return [P(x, y - 1): .petal, P(x - 1, y): .petal, P(x + 1, y): .petal, P(x, y + 1): .petal, P(x, y): .pollen]
        case .bow:
            let (x, y) = (4, top)
            return [P(x - 1, y - 1): .bow, P(x - 1, y): .bow, P(x, y): .knot, P(x + 1, y - 1): .bow, P(x + 1, y): .bow]
        }
    }

    static func glasses(_ spec: AvatarArt.Spec, _ colors: AvatarArt.Colors, _ context: CGContext) {
        context.setStrokeColor(colors.eye)
        context.setLineWidth(0.4)
        for eye in [spec.leftEye, spec.rightEye] {
            context.stroke(CGRect(x: CGFloat(eye.x) - 0.8, y: CGFloat(eye.y) - 0.8, width: 2.6, height: 2.6))
        }
        context.fill(CGRect(x: CGFloat(spec.leftEye.x) + 1.8, y: CGFloat(spec.leftEye.y) + 0.3,
                            width: CGFloat(spec.rightEye.x - spec.leftEye.x) - 2.6, height: 0.4))
    }

    static func color(_ role: Role, _ c: AvatarArt.Colors) -> CGColor {
        switch role {
        case .body: c.body
        case .shade: c.shade
        case .face: c.face
        case .belly: c.belly
        case .beak: c.beak
        case .leaf: c.leaf
        case .stem: c.leafDark
        case .hat: c.hat
        case .trim: c.trim
        case .bow: c.bow
        case .knot: c.bowDark
        case .petal: c.petal
        case .pollen: c.pollen
        case .antenna: c.outline
        case .bobble: c.hat
        }
    }

    static func outlineColor(_ role: Role, _ c: AvatarArt.Colors) -> CGColor {
        switch role {
        case .body, .shade, .face, .belly, .antenna: c.outline
        case .beak: c.beakDark
        case .leaf, .stem: c.leafDark
        case .hat, .trim, .bobble: c.hatDark
        case .bow, .knot: c.bowDark
        case .petal, .pollen: c.petalDark
        }
    }

    static func fill(_ p: P, _ color: CGColor, _ context: CGContext) {
        context.setFillColor(color)
        context.fill(CGRect(x: p.x, y: p.y, width: 1, height: 1))
    }
}

// MARK: - Plush

private enum PlushArt {
    typealias P = AvatarArt.P

    static func draw(_ spec: AvatarArt.Spec, style: AvatarStyle, pose: AvatarPose, colors: AvatarArt.Colors,
                     in context: CGContext)
    {
        context.setLineWidth(1.1)
        context.setLineJoin(.round)
        self.paint(self.silhouette(spec, style: style, pose: pose), colors, in: context)
        self.face(spec, style: style, pose: pose, colors: colors, in: context)
        self.accessory(style.accessory, spec: spec, twitch: pose.twitch, colors: colors, in: context)
    }

    /// Strokes every part, then fills them, so the outline hugs the combined shape.
    static func paint(_ parts: [Part], _ colors: AvatarArt.Colors, in context: CGContext) {
        for part in parts {
            context.addPath(part.path)
            context.setStrokeColor(part.outline(colors))
            context.strokePath()
        }
        for part in parts {
            self.fillSoft(part.path, part.fill(colors), light: part.light(colors), in: context)
        }
    }

    struct Part {
        let path: CGPath
        let fill: (AvatarArt.Colors) -> CGColor
        var light: (AvatarArt.Colors) -> CGColor? = { $0.bodyLight }
        var outline: (AvatarArt.Colors) -> CGColor = { $0.outline }
    }

    static func silhouette(_ spec: AvatarArt.Spec, style: AvatarStyle, pose: AvatarPose) -> [Part] {
        var parts: [Part] = []
        let twitch = CGFloat(pose.twitch)
        func body(_ path: CGPath) { parts.append(Part(path: path, fill: { $0.body })) }
        func arm(_ arm: AvatarPose.Arm, x: Int, side: CGFloat) {
            let cx = CGFloat(x) + 0.5 - side * 0.3, row = CGFloat(spec.armRow)
            let rect: CGRect = switch arm {
            case .down: CGRect(x: cx - 0.95, y: row - 0.1, width: 1.9, height: 2.4)
            case .tap: CGRect(x: cx - 0.95, y: row - 1.1, width: 1.9, height: 2.4)
            case .up: CGRect(x: -0.95, y: -1.6, width: 1.9, height: 3.2)
            }
            if case let .up(wave) = arm {
                // Raised and tipped outward, waving a little further out on alternate frames.
                // From the body's side, whichever creature it is, so it never covers the face.
                let shoulder: CGFloat = side < 0 ? 1.6 : 14.4
                var transform = CGAffineTransform(translationX: shoulder + side * CGFloat(wave) * 0.5, y: min(row, 11) - 2.4)
                    .rotated(by: side * (0.5 + CGFloat(wave) * 0.25))
                body(CGPath(ellipseIn: rect, transform: &transform))
            } else {
                body(CGPath(ellipseIn: rect, transform: nil))
            }
        }
        arm(pose.leftArm, x: spec.leftArm, side: -1)
        arm(pose.rightArm, x: spec.rightArm, side: 1)
        let footColor: (AvatarArt.Colors) -> CGColor = spec.creature == .owl ? { $0.beak } : { $0.shade }
        let footOutline: (AvatarArt.Colors) -> CGColor = spec.creature == .owl ? { $0.beakDark } : { $0.outline }
        let feet: [CGFloat] = spec.creature == .sprout ? [6, 10] : [5, 11]
        for x in feet {
            parts.append(Part(path: CGPath(ellipseIn: CGRect(x: x - 1.3, y: 13.4, width: 2.6, height: 1.9), transform: nil),
                              fill: footColor, light: { _ in nil }, outline: footOutline))
        }
        switch spec.creature {
        case .blob:
            body(CGPath(roundedRect: CGRect(x: 2, y: 2.9, width: 12, height: 11.3), cornerWidth: 5.6, cornerHeight: 5.4, transform: nil))
        case .owl:
            // Little feather tufts on the head's corners; they flick outward.
            for side: CGFloat in [-1, 1] {
                let path = CGMutablePath()
                let base = 8 + side * 4.4
                path.move(to: CGPoint(x: base - side * 1.4, y: 4.4))
                path.addQuadCurve(to: CGPoint(x: base + side * (1.1 + twitch * 0.5), y: 2.4 + twitch * 0.3),
                                  control: CGPoint(x: base - side * 0.2, y: 3.2))
                path.addQuadCurve(to: CGPoint(x: base + side * 1.2, y: 5.2), control: CGPoint(x: base + side * 1.3, y: 3.6))
                path.closeSubpath()
                body(path)
            }
            body(CGPath(ellipseIn: CGRect(x: 2, y: 3.6, width: 12, height: 10.8), transform: nil))
        case .rock:
            for (x, y, r) in [(6.0, 3.9, 1.2), (10.4, 3.7 - Double(twitch) * 0.9, 0.95)] {
                parts.append(Part(path: CGPath(ellipseIn: CGRect(x: x - r, y: y - r * 0.85, width: r * 2, height: r * 1.7), transform: nil),
                                  fill: { $0.shade }, light: { $0.body }))
            }
            body(CGPath(roundedRect: CGRect(x: 2, y: 4, width: 12, height: 10.1), cornerWidth: 3.6, cornerHeight: 3.4, transform: nil))
        case .sprout:
            let lift = twitch * 0.8
            let stem = CGMutablePath()
            stem.addRect(CGRect(x: 7.35, y: 1.8 - lift, width: 0.8, height: 2.6 + lift))
            parts.append(Part(path: stem, fill: { $0.leafDark }, light: { _ in nil }, outline: { $0.leafDark }))
            for (cx, cy, angle) in [(5.0, 2.1, 0.35), (10.2, 1.2, -0.4)] {
                var transform = CGAffineTransform(translationX: cx, y: cy - lift).rotated(by: angle)
                let leaf = CGPath(ellipseIn: CGRect(x: -2.2, y: -1, width: 4.4, height: 2), transform: &transform)
                parts.append(Part(path: leaf, fill: { $0.leaf }, light: { _ in nil }, outline: { $0.leafDark }))
            }
            body(CGPath(roundedRect: CGRect(x: 4.6, y: 10, width: 6.8, height: 4.2), cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
            body(CGPath(roundedRect: CGRect(x: 2, y: 4, width: 12, height: 7.2), cornerWidth: 2.8, cornerHeight: 2.8, transform: nil))
        }
        return parts
    }

    static func face(_ spec: AvatarArt.Spec, style: AvatarStyle, pose: AvatarPose, colors: AvatarArt.Colors,
                     in context: CGContext)
    {
        // Face plate or belly.
        switch spec.creature {
        case .blob:
            self.fillSoft(CGPath(ellipseIn: CGRect(x: 3.7, y: 5.9, width: 8.6, height: 6.5), transform: nil), colors.face, light: nil, in: context)
        case .owl:
            let plate = CGMutablePath()
            plate.addEllipse(in: CGRect(x: 2.9, y: 5.4, width: 5.4, height: 4.8))
            plate.addEllipse(in: CGRect(x: 7.7, y: 5.4, width: 5.4, height: 4.8))
            self.fillSoft(plate, colors.face, light: nil, in: context)
            self.fillSoft(CGPath(ellipseIn: CGRect(x: 5, y: 9.8, width: 6, height: 4.2), transform: nil), colors.belly, light: nil, in: context)
            let beak = CGMutablePath()
            beak.move(to: CGPoint(x: 7.2, y: 9.1))
            beak.addLine(to: CGPoint(x: 8.8, y: 9.1))
            beak.addLine(to: CGPoint(x: 8, y: 10.4))
            beak.closeSubpath()
            context.addPath(beak)
            context.setFillColor(colors.beak)
            context.fillPath()
        case .rock:
            self.fillSoft(CGPath(roundedRect: CGRect(x: 3.4, y: 5.9, width: 9.2, height: 5.1), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil),
                          colors.face, light: nil, in: context)
        case .sprout:
            self.fillSoft(CGPath(roundedRect: CGRect(x: 3.1, y: 5.6, width: 9.8, height: 4.8), cornerWidth: 1.9, cornerHeight: 1.9, transform: nil),
                          colors.face, light: nil, in: context)
        }
        // Blush.
        context.setFillColor(colors.blush.copy(alpha: 0.85) ?? colors.blush)
        for x in [CGFloat(spec.leftEye.x) - 0.6, CGFloat(spec.rightEye.x) + 0.6] {
            context.fillEllipse(in: CGRect(x: x - 0.4, y: CGFloat(spec.blushRow) + 0.15, width: 1.8, height: 0.9))
        }
        if style.accessory == .glasses {
            context.setStrokeColor(colors.eye)
            context.setLineWidth(0.3)
            for eye in [spec.leftEye, spec.rightEye] {
                context.strokeEllipse(in: CGRect(x: CGFloat(eye.x) - 0.9, y: CGFloat(eye.y) - 0.9, width: 2.8, height: 2.8))
            }
            context.move(to: CGPoint(x: CGFloat(spec.leftEye.x) + 1.9, y: CGFloat(spec.leftEye.y) + 0.4))
            context.addLine(to: CGPoint(x: CGFloat(spec.rightEye.x) - 0.9, y: CGFloat(spec.rightEye.y) + 0.4))
            context.strokePath()
        }
        context.setLineCap(.round)
        if pose.mouth, let row = spec.mouthRow {
            context.setStrokeColor(colors.eye)
            context.setLineWidth(0.3)
            context.move(to: CGPoint(x: 7.4, y: CGFloat(row) + 0.35))
            context.addQuadCurve(to: CGPoint(x: 8.6, y: CGFloat(row) + 0.35), control: CGPoint(x: 8, y: CGFloat(row) + 1.05))
            context.strokePath()
        }
        context.setFillColor(colors.eye)
        context.setStrokeColor(colors.eye)
        context.setLineWidth(0.35)
        for eye in [spec.leftEye, spec.rightEye] {
            let c = CGPoint(x: CGFloat(eye.x) + 0.5, y: CGFloat(eye.y + pose.gaze) + 0.5)
            switch pose.eyes {
            case .open:
                context.fillEllipse(in: CGRect(x: c.x - 0.5, y: c.y - 0.55, width: 1, height: 1.1))
            case .closed:
                context.move(to: CGPoint(x: c.x - 0.6, y: c.y + 0.1))
                context.addLine(to: CGPoint(x: c.x + 0.6, y: c.y + 0.1))
                context.strokePath()
            case .happy:
                context.move(to: CGPoint(x: c.x - 0.7, y: c.y + 0.4))
                context.addLine(to: CGPoint(x: c.x, y: c.y - 0.3))
                context.addLine(to: CGPoint(x: c.x + 0.7, y: c.y + 0.4))
                context.strokePath()
            }
        }
    }

    static func accessory(_ accessory: AvatarAccessory, spec: AvatarArt.Spec, twitch: Int, colors: AvatarArt.Colors,
                          in context: CGContext)
    {
        let top = CGFloat(spec.headTop)
        let t = CGFloat(twitch)
        func blob(_ path: CGPath, _ fill: CGColor, _ outline: CGColor) {
            context.addPath(path)
            context.setStrokeColor(outline)
            context.setLineWidth(0.8)
            context.strokePath()
            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
        }
        switch accessory {
        case .none, .glasses:
            break
        case .hat:
            let cap = CGMutablePath()
            cap.addArc(center: CGPoint(x: 8, y: top + 0.9), radius: 3.6, startAngle: .pi, endAngle: 0, clockwise: false)
            cap.closeSubpath()
            blob(cap, colors.hat, colors.hatDark)
            blob(CGPath(roundedRect: CGRect(x: 3.9, y: top + 0.1, width: 8.2, height: 1.5), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil),
                 colors.trim, colors.hatDark)
            blob(CGPath(ellipseIn: CGRect(x: 7.1 + t * 0.6, y: top - 3.8, width: 1.8, height: 1.8), transform: nil), colors.trim, colors.hatDark)
        case .antenna:
            context.setStrokeColor(colors.outline)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: 8, y: top + 0.6))
            context.addLine(to: CGPoint(x: 8 + t * 0.7, y: top - 2))
            context.strokePath()
            blob(CGPath(ellipseIn: CGRect(x: 7.1 + t * 0.7, y: top - 3.2, width: 1.8, height: 1.8), transform: nil), colors.hat, colors.hatDark)
        case .leaf:
            let c = CGPoint(x: 11.5, y: top + 1.5)
            for (dx, dy) in [(0.0, -1.0), (1.0, 0.0), (0.0, 1.0), (-1.0, 0.0)] {
                blob(CGPath(ellipseIn: CGRect(x: c.x + dx - 0.75, y: c.y + dy - 0.75, width: 1.5, height: 1.5), transform: nil),
                     colors.petal, colors.petalDark)
            }
            context.setFillColor(colors.pollen)
            context.fillEllipse(in: CGRect(x: c.x - 0.6, y: c.y - 0.6, width: 1.2, height: 1.2))
        case .bow:
            let c = CGPoint(x: 4.5, y: top + 0.3)
            let loops = CGMutablePath()
            loops.move(to: c)
            loops.addLine(to: CGPoint(x: c.x - 1.9, y: c.y - 1.2))
            loops.addLine(to: CGPoint(x: c.x - 1.9, y: c.y + 1.2))
            loops.closeSubpath()
            loops.move(to: c)
            loops.addLine(to: CGPoint(x: c.x + 1.9, y: c.y - 1.2))
            loops.addLine(to: CGPoint(x: c.x + 1.9, y: c.y + 1.2))
            loops.closeSubpath()
            blob(loops, colors.bow, colors.bowDark)
            blob(CGPath(ellipseIn: CGRect(x: c.x - 0.6, y: c.y - 0.6, width: 1.2, height: 1.2), transform: nil), colors.bowDark, colors.bowDark)
        }
    }

    /// Fills with a gentle top-to-bottom gradient from `light`, or flat when it's nil.
    static func fillSoft(_ path: CGPath, _ color: CGColor, light: CGColor?, in context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let box = path.boundingBoxOfPath
        if let light, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                colors: [light, color] as CFArray, locations: [0, 0.75])
        {
            context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                                       end: CGPoint(x: box.midX, y: box.maxY), options: [.drawsAfterEndLocation])
        } else {
            context.setFillColor(color)
            context.fill(box)
        }
        context.restoreGState()
    }
}

// MARK: - Extras

/// The "…" bubble, the floating "z" and the sweat drop, drawn over the creature.
private enum Extras {
    static func draw(_ pose: AvatarPose, colors: AvatarArt.Colors, pixel: Bool, in context: CGContext) {
        context.setShouldAntialias(!pixel)
        defer { context.setShouldAntialias(true) }
        if pose.bubbleDots > 0 {
            // Up and to the right of the head, holding still while the body bounces.
            let box = CGRect(x: 10, y: -1, width: 7, height: 3)
            let path = CGPath(roundedRect: box, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil)
            context.addPath(path)
            context.setFillColor(colors.bubble)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(colors.bubbleEdge)
            context.setLineWidth(0.35)
            context.strokePath()
            context.setFillColor(colors.ink)
            for i in 0..<pose.bubbleDots {
                let x = box.minX + 1 + CGFloat(i) * 2
                if pixel {
                    context.fill(CGRect(x: x, y: box.minY + 1, width: 1, height: 1))
                } else {
                    context.fillEllipse(in: CGRect(x: x, y: box.midY - 0.5, width: 1, height: 1))
                }
            }
        }
        if let rise = pose.zRise {
            let x = 12.5 + CGFloat(rise) * 2, y = 3 - CGFloat(rise) * 3.5
            context.setAlpha(1 - CGFloat(rise) * 0.6)
            context.setStrokeColor(colors.ink)
            context.setLineWidth(pixel ? 0.6 : 0.45)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 2, y: y))
            context.addLine(to: CGPoint(x: x, y: y + 2))
            context.addLine(to: CGPoint(x: x + 2, y: y + 2))
            context.strokePath()
            context.setAlpha(1)
        }
        if pose.sweat {
            context.setFillColor(colors.sweat)
            if pixel {
                context.fill(CGRect(x: 13, y: 5, width: 1, height: 1))
            } else {
                let drop = CGMutablePath()
                drop.move(to: CGPoint(x: 13.5, y: 4.4))
                drop.addQuadCurve(to: CGPoint(x: 13.5, y: 6.2), control: CGPoint(x: 12.4, y: 6))
                drop.addQuadCurve(to: CGPoint(x: 13.5, y: 4.4), control: CGPoint(x: 14.6, y: 6))
                context.addPath(drop)
                context.fillPath()
            }
        }
    }
}
