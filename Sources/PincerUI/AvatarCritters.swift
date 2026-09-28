import CoreGraphics
import PincerKit

// The companions beyond the first four, on the same 16×16 grid and with the same rules: palette
// body, face-coloured plates, blush-pink details, outlines in a deep shade of the body's own hue.

// MARK: - Pixel

extension AvatarArt.Spec {
    typealias P = AvatarArt.P

    /// `cells` plus their mirror image across the grid's centre line.
    static func mirrored(_ cells: [P: AvatarArt.Role]) -> [P: AvatarArt.Role] {
        var all = cells
        for (p, role) in cells { all[P(15 - p.x, p.y)] = role }
        return all
    }

    static let cat = Self(
        creature: .cat,
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
            "..bffffnnffffb..",
            "..bbffffffffbb..",
            "..bbbbllllbbbb..",
            "..sbbllllllbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 10,
        leftArm: 1, rightArm: 14, armRow: 11, headTop: 4,
        top: { twitch in
            // Pointed ears with pink insides; they flick outward.
            let tip = twitch == 0
                ? [P(3, 2): AvatarArt.Role.body, P(4, 2): .body, P(3, 1): .body]
                : [P(2, 2): .body, P(3, 2): .body, P(4, 2): .body, P(2, 1): .body]
            return mirrored(tip.merging([P(3, 3): .body, P(4, 3): .pink, P(5, 3): .body]) { $1 })
        })

    static let bunny = Self(
        creature: .bunny,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            "................",
            "....bbbbbbbb....",
            "...bbbbbbbbbb...",
            "..bbbffffffbbb..",
            "..bbffffffffbb..",
            "..bbfffnnfffbb..",
            "..bbbffffffbbb..",
            "..bbbbbbbbbbbb..",
            "..sbbbllllbbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 10,
        leftArm: 1, rightArm: 14, armRow: 11, headTop: 5,
        top: { twitch in
            // Long ears; the right one flops over.
            var cells: [P: AvatarArt.Role] = [:]
            for y in 1...4 {
                cells[P(4, y)] = .body
                cells[P(5, y)] = .pink
                let flop = twitch == 1 && y <= 2 ? 1 : 0
                cells[P(10 + flop, y)] = .pink
                cells[P(11 + flop, y)] = .body
            }
            return cells
        })

    static let bear = Self(
        creature: .bear,
        body: parse([
            "................",
            "................",
            "..bbb......bbb..",
            "..bnb.bbbb.bnb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbfeefbbbb..",
            "..bbbffffffbbb..",
            "..bbbbffffbbbb..",
            "..bbbbllllbbbb..",
            "..sbbllllllbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 7), rightEye: P(10, 7), blushRow: 8, mouthRow: 9,
        leftArm: 1, rightArm: 14, armRow: 11, headTop: 3,
        top: { _ in [:] })

    static let frog = Self(
        creature: .frog,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            "..bbbbb..bbbbb..",
            "..bfffb..bfffb..",
            "..bfffbbbbfffb..",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            "..bbbbllllbbbb..",
            "..bbbllllllbbb..",
            "..sbbllllllbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(4, 6), rightEye: P(11, 6), blushRow: 7, mouthRow: 8,
        leftArm: 1, rightArm: 14, armRow: 10, headTop: 4,
        top: { _ in [:] })

    static let fox = Self(
        creature: .fox,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            "...bbbbbbbbbb...",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..fffbbbbbbfff..",
            "..bffffeeffffb..",
            "...bffffffffb...",
            "...bbbllllbbb...",
            "...bbllllllbb...",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 7), rightEye: P(10, 7), blushRow: 8, mouthRow: 10,
        leftArm: 2, rightArm: 13, armRow: 11, headTop: 4,
        top: { twitch in
            // Tall pointed ears with pale insides and dark tips; they flick outward.
            let upper = twitch == 0
                ? [P(3, 2): AvatarArt.Role.body, P(4, 2): .face, P(3, 1): .shade, P(3, 0): .shade]
                : [P(2, 2): .body, P(3, 2): .body, P(4, 2): .face, P(2, 1): .shade, P(2, 0): .shade]
            return mirrored(upper.merging([P(3, 3): .body, P(4, 3): .face, P(5, 3): .body]) { $1 })
        })

    static let mouse = Self(
        creature: .mouse,
        body: parse([
            "................",
            "..bb........bb..",
            ".bnnb......bnnb.",
            ".bnnb......bnnb.",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbffffffffbb..",
            "..bffffffffffb..",
            "..bffffffffffb..",
            "..bbfffnnfffbb..",
            "...bbffffffbb...",
            "...bbbbbbbbbb...",
            "...sbbllllbbs...",
            "....sbllllbs....",
            "....ss....ss....",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 10,
        leftArm: 2, rightArm: 13, armRow: 11, headTop: 4,
        top: { _ in [:] })

    static let penguin = Self(
        creature: .penguin,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            "....bbbbbbbb....",
            "...bbbbbbbbbb...",
            "..bbbffbbffbbb..",
            "..bbffffffffbb..",
            "..bbfffyyfffbb..",
            "..bbbffffffbbb..",
            "..bbffffffffbb..",
            "..bbffffffffbb..",
            "..sbffffffffbs..",
            "...sbffffffbs...",
            "....yy....yy....",
        ]),
        leftEye: P(5, 7), rightEye: P(10, 7), blushRow: 8, mouthRow: nil,
        leftArm: 1, rightArm: 14, armRow: 9, headTop: 4,
        top: { _ in [:] })

    static let chick = Self(
        creature: .chick,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            ".....bbbbbb.....",
            "...bbbbbbbbbb...",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbyybbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbllllllbbb..",
            "..sbllllllllbs..",
            "...sbllllllbs...",
            "....yy....yy....",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: nil,
        leftArm: 1, rightArm: 14, armRow: 10, headTop: 4,
        top: { twitch in
            // A little tuft of fluff; it sways.
            twitch == 0
                ? [P(7, 3): .body, P(8, 3): .body, P(7, 2): .body, P(6, 1): .body]
                : [P(7, 3): .body, P(8, 3): .body, P(8, 2): .body, P(9, 1): .body]
        })

    static let pig = Self(
        creature: .pig,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            "...bbbbbbbbbb...",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbnnnnbbbb..",
            "..bbbbneenbbbb..",
            "..bbbbllllbbbb..",
            "..sbbllllllbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 7), rightEye: P(10, 7), blushRow: 8, mouthRow: nil,
        leftArm: 1, rightArm: 14, armRow: 11, headTop: 4,
        top: { twitch in
            // Small ears; they flop outward.
            let tip = twitch == 0 ? P(3, 2) : P(2, 2)
            return mirrored([P(3, 3): .body, P(4, 3): .pink, tip: .body])
        })

    static let ghost = Self(
        creature: .ghost,
        body: parse([
            "................",
            "................",
            "................",
            "................",
            ".....bbbbbb.....",
            "...bbbbbbbbbb...",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..sbbbbbbbbbbs..",
            "..s.ss.ss.ss.s..",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 9,
        leftArm: 1, rightArm: 14, armRow: 9, headTop: 4,
        top: { _ in [:] })

    static let mushroom = Self(
        creature: .mushroom,
        body: parse([
            "................",
            "................",
            ".....hhhhhh.....",
            "...hhhhhhrrhh...",
            "..hrrhhhhrrhhh..",
            ".hhrrhhhhhhhhhh.",
            ".hhhhhhhhhhrrhh.",
            "...bbbbbbbbbb...",
            "...bffffffffb...",
            "...bffffffffb...",
            "...bffffffffb...",
            "...bbbbbbbbbb...",
            "...sbbbbbbbbs...",
            "....sbbbbbbs....",
            "....ss....ss....",
        ]),
        leftEye: P(5, 9), rightEye: P(10, 9), blushRow: 10, mouthRow: 10,
        leftArm: 2, rightArm: 13, armRow: 11, headTop: 2,
        top: { _ in [:] })

    static let cloud = Self(
        creature: .cloud,
        body: parse([
            "................",
            "................",
            "................",
            "......bbbb......",
            "..bb.bbbbbb.bb..",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbb.",
            "..sbbbbbbbbbbs..",
            "...ssss..ssss...",
            "................",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 9,
        leftArm: 0, rightArm: 15, armRow: 9, headTop: 3,
        top: { _ in [:] })

    static let axolotl = Self(
        creature: .axolotl,
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
            "..bbffffffffbb..",
            "..bbbbbbbbbbbb..",
            "...bbllllllbb...",
            "...bbllllllbb...",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 7), rightEye: P(10, 7), blushRow: 8, mouthRow: 8,
        leftArm: 2, rightArm: 13, armRow: 11, headTop: 4,
        top: { twitch in
            // Frilly gills, three a side; they ripple.
            let tips = twitch == 0 ? [P(0, 4), P(0, 7), P(0, 10)] : [P(0, 5), P(0, 6), P(0, 9)]
            var cells: [P: AvatarArt.Role] = [P(1, 5): .pink, P(1, 7): .pink, P(1, 9): .pink]
            for tip in tips { cells[tip] = .pink }
            return mirrored(cells)
        })

    static let hedgehog = Self(
        creature: .hedgehog,
        body: parse([
            "................",
            "................",
            "................",
            "...s..s..s..s...",
            "..ss.ssssss.ss..",
            ".ssssssssssssss.",
            ".ssssssssssssss.",
            "ssbffffffffffbss",
            ".sbffffffffffbs.",
            "ssbffffffffffbss",
            ".sbbfffeefffbbs.",
            "ssbbbffffffbbbss",
            ".sbbbbllllbbbbs.",
            "..sbbllllllbbs..",
            "...sbbllllbbs...",
            "....ss....ss....",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 10,
        leftArm: 0, rightArm: 15, armRow: 11, headTop: 3,
        top: { twitch in
            // A coat of quills; they bristle.
            twitch == 0 ? [:] : mirrored([P(3, 1): .shade, P(6, 1): .shade, P(0, 5): .shade])
        })

    static let octopus = Self(
        creature: .octopus,
        body: parse([
            "................",
            "................",
            "................",
            ".....bbbbbb.....",
            "...bbbbbbbbbb...",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..bbbbbbbbbbbb..",
            "..sbbbbbbbbbbs..",
            "..bb.bb..bb.bb..",
            "..bb.bb..bb.bb..",
            "................",
        ]),
        leftEye: P(5, 8), rightEye: P(10, 8), blushRow: 9, mouthRow: 9,
        leftArm: 1, rightArm: 14, armRow: 9, headTop: 3,
        top: { twitch in
            // Tentacle tips; they curl out, then in.
            mirrored(twitch == 0 ? [P(1, 14): .shade, P(4, 14): .shade] : [P(3, 14): .shade, P(6, 14): .shade])
        })
}

// MARK: - Plush

extension PlushArt {
    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [a, b, c])
        path.closeSubpath()
        return path
    }

    /// `path` and its mirror image across the grid's centre line, as one path.
    private static func pair(_ path: CGPath) -> CGPath {
        let both = CGMutablePath()
        both.addPath(path)
        both.addPath(path, transform: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -16, y: 0))
        return both
    }

    private static func rotated(_ rect: CGRect, at center: CGPoint, by angle: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
        return CGPath(ellipseIn: rect, transform: &transform)
    }

    /// A pointed ear on the head's left corner, tip flicking outward on a twitch.
    private static func pointedEar(twitch: CGFloat, height: CGFloat) -> CGPath {
        self.triangle(CGPoint(x: 2.4, y: 6), CGPoint(x: 6.6, y: 4.3),
                      CGPoint(x: 3.1 - twitch * 0.9, y: 4.3 - height + twitch * 0.3))
    }

    private static func pointedInner(twitch: CGFloat, height: CGFloat) -> CGPath {
        self.triangle(CGPoint(x: 3.4, y: 5.2), CGPoint(x: 5.6, y: 4.4),
                      CGPoint(x: 3.5 - twitch * 0.7, y: 4.6 - height * 0.62 + twitch * 0.25))
    }

    private static func pigEar(twitch: CGFloat) -> CGPath {
        self.triangle(CGPoint(x: 2.8, y: 5.6), CGPoint(x: 5.8, y: 4.2), CGPoint(x: 2.6 - twitch * 0.9, y: 2.7 + twitch * 0.8))
    }

    private static func bunnyEar(right: Bool, twitch: CGFloat, inner: Bool) -> CGPath {
        let flop = right ? twitch : 0
        let side: CGFloat = right ? 1 : -1
        let rect = inner ? CGRect(x: -0.5, y: -2, width: 1, height: 3.6) : CGRect(x: -1.25, y: -2.9, width: 2.5, height: 5.8)
        return self.rotated(rect, at: CGPoint(x: 8 + side * 2.9 + flop * 0.6, y: 2.9 + flop * 0.4), by: side * (0.12 + flop * 0.55))
    }

    private static func gill(right: Bool, index: Int, twitch: CGFloat) -> CGPath {
        let side: CGFloat = right ? -1 : 1
        let y: CGFloat = [5.6, 7.6, 9.6][index]
        let angle = (CGFloat(1 - index) * 0.5 + twitch * 0.3) * side
        let rect = right ? CGRect(x: -0.4, y: -0.55, width: 2.8, height: 1.1) : CGRect(x: -2.4, y: -0.55, width: 2.8, height: 1.1)
        return self.rotated(rect, at: CGPoint(x: right ? 13.4 : 2.6, y: y), by: angle)
    }

    /// The silhouette parts for the creatures in this file, drawn behind the face.
    static func critterParts(_ creature: AvatarCreature, twitch: CGFloat) -> [Part] {
        func body(_ path: CGPath) -> Part { Part(path: path, fill: { $0.body }) }
        func pink(_ path: CGPath) -> Part { Part(path: path, fill: { $0.blush }, light: { _ in nil }, outline: { $0.outline }) }
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        switch creature {
        case .blob, .owl, .rock, .sprout:
            return []
        case .cat:
            return [body(self.pair(self.pointedEar(twitch: twitch, height: 3.4))), body(rounded(2, 4, 12, 10.1, 4.4))]
        case .bunny:
            return [body(self.bunnyEar(right: false, twitch: twitch, inner: false)),
                    body(self.bunnyEar(right: true, twitch: twitch, inner: false)),
                    body(rounded(2, 5, 12, 9.2, 4.6))]
        case .bear:
            return [body(self.pair(self.ellipse(3.4, 4.4, 1.9, 1.9))), body(rounded(2, 3.9, 12, 10.3, 5.2))]
        case .frog:
            return [body(self.pair(self.ellipse(4.5, 5.7, 2.3, 2.3))), body(rounded(1.2, 6.2, 13.6, 8.1, 4))]
        case .fox:
            return [body(self.pair(self.pointedEar(twitch: twitch, height: 4.4))), body(rounded(2, 4, 12, 10.1, 4.2))]
        case .mouse:
            return [body(self.pair(self.ellipse(2.9, 2.9, 2.3, 2.3))), body(rounded(2, 4, 12, 10.1, 5))]
        case .penguin:
            return [body(self.ellipse(8, 9.1, 6, 5.3))]
        case .chick:
            let tuft = CGMutablePath()
            tuft.addPath(self.rotated(CGRect(x: -0.6, y: -1.6, width: 1.2, height: 3.2), at: CGPoint(x: 7.4, y: 3.2), by: -0.45 + twitch * 0.4))
            tuft.addPath(self.rotated(CGRect(x: -0.55, y: -1.3, width: 1.1, height: 2.6), at: CGPoint(x: 8.7, y: 3.3), by: 0.35 + twitch * 0.4))
            return [body(tuft), body(self.ellipse(8, 9.1, 6, 5.3))]
        case .pig:
            return [body(self.pair(self.pigEar(twitch: twitch))), body(rounded(2, 3.9, 12, 10.3, 5.2))]
        case .ghost:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 2.2, y: 13.4))
            path.addArc(center: CGPoint(x: 8, y: 9.6), radius: 5.8, startAngle: .pi, endAngle: 0, clockwise: false)
            path.addLine(to: CGPoint(x: 13.8, y: 13.4))
            for x in stride(from: 13.8, to: 2.3, by: -2.9) {
                path.addQuadCurve(to: CGPoint(x: x - 2.9, y: 13.4), control: CGPoint(x: x - 1.45, y: 15.6))
            }
            path.closeSubpath()
            return [body(path)]
        case .mushroom:
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: 1, y: 7.3))
            cap.addCurve(to: CGPoint(x: 15, y: 7.3), control1: CGPoint(x: 1.2, y: 0.9), control2: CGPoint(x: 14.8, y: 0.9))
            cap.addQuadCurve(to: CGPoint(x: 1, y: 7.3), control: CGPoint(x: 8, y: 8.7))
            cap.closeSubpath()
            return [body(rounded(3.2, 6.4, 9.6, 7.8, 3)),
                    Part(path: cap, fill: { $0.hat }, light: { _ in nil }, outline: { $0.hatDark })]
        case .cloud:
            let puffs = CGMutablePath()
            puffs.addPath(self.ellipse(8, 6.2, 3.3, 3.3))
            puffs.addPath(self.ellipse(4.5, 8.3, 2.9, 2.9))
            puffs.addPath(self.ellipse(11.5, 8.3, 2.9, 2.9))
            puffs.addPath(rounded(1.2, 7.4, 13.6, 6, 3))
            return [body(puffs)]
        case .axolotl:
            let gills = CGMutablePath()
            for index in 0..<3 {
                gills.addPath(self.gill(right: false, index: index, twitch: twitch))
                gills.addPath(self.gill(right: true, index: index, twitch: twitch))
            }
            return [pink(gills), body(rounded(2, 4, 12, 10.1, 4.6))]
        case .hedgehog:
            // A crown of quills around the top half, longer when they bristle.
            let quills = CGMutablePath()
            let center = CGPoint(x: 8, y: 9.4), points = 13
            for i in 0...points * 2 {
                let angle = CGFloat.pi + CGFloat.pi * CGFloat(i) / CGFloat(points * 2)
                let reach: CGFloat = i.isMultiple(of: 2) ? 0.82 : 1 + twitch * 0.1
                let point = CGPoint(x: center.x + cos(angle) * 7.2 * reach, y: center.y + sin(angle) * 6.6 * reach)
                if i == 0 { quills.move(to: point) } else { quills.addLine(to: point) }
            }
            quills.closeSubpath()
            return [Part(path: quills, fill: { $0.shade }, light: { $0.body }),
                    body(rounded(1.8, 4.6, 12.4, 9.6, 4.8))]
        case .octopus:
            let tentacles = CGMutablePath()
            for (x, outward) in [(3.0, -1.0), (6.0, -1.0), (10.0, 1.0), (13.0, 1.0)] {
                tentacles.addPath(rounded(x - 1.1, 10, 2.2, 3.9, 1.1))
                let curl = (twitch == 0 ? outward : -outward) * 0.9
                tentacles.addPath(self.ellipse(x + curl, 13.7, 1, 0.8))
            }
            return [body(tentacles), body(self.ellipse(8, 7.8, 6, 4.9))]
        }
    }

    /// Face plates, inner ears, snouts and noses for the creatures in this file, drawn over the
    /// silhouette and under the eyes and blush.
    static func critterFace(_ creature: AvatarCreature, twitch: CGFloat, colors: AvatarArt.Colors, in context: CGContext) {
        func fill(_ path: CGPath, _ color: CGColor) { self.fillSoft(path, color, light: nil, in: context) }
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func nose(_ y: CGFloat, _ color: CGColor, width: CGFloat = 1.5) {
            fill(self.ellipse(8, y, width / 2, 0.45), color)
        }
        switch creature {
        case .blob, .owl, .rock, .sprout:
            break
        case .cat:
            fill(self.pair(self.pointedInner(twitch: twitch, height: 3.4)), colors.blush)
            fill(rounded(3.3, 6, 9.4, 5.1, 2.4), colors.face)
            fill(self.triangle(CGPoint(x: 7.3, y: 9.2), CGPoint(x: 8.7, y: 9.2), CGPoint(x: 8, y: 9.9)), colors.blush)
        case .bunny:
            fill(self.bunnyEar(right: false, twitch: twitch, inner: true), colors.blush)
            fill(self.bunnyEar(right: true, twitch: twitch, inner: true), colors.blush)
            fill(self.ellipse(8, 8.9, 4.4, 2.5), colors.face)
            fill(self.triangle(CGPoint(x: 7.3, y: 9.2), CGPoint(x: 8.7, y: 9.2), CGPoint(x: 8, y: 9.9)), colors.blush)
        case .bear:
            fill(self.pair(self.ellipse(3.4, 4.3, 0.95, 0.95)), colors.blush)
            fill(self.ellipse(8, 9.5, 2.9, 1.8), colors.face)
            nose(8.6, colors.eye, width: 1.7)
        case .frog:
            fill(self.pair(self.ellipse(4.5, 6, 1.55, 1.5)), colors.face)
            fill(self.ellipse(8, 11.7, 4, 2.4), colors.belly)
        case .fox:
            fill(self.pair(self.pointedInner(twitch: twitch, height: 4.4)), colors.face)
            let cheeks = CGMutablePath()
            cheeks.addPath(self.ellipse(5.1, 9.3, 2.8, 1.7))
            cheeks.addPath(self.ellipse(10.9, 9.3, 2.8, 1.7))
            cheeks.addPath(self.ellipse(8, 10.1, 2.8, 1.3))
            fill(cheeks, colors.face)
            nose(9.4, colors.eye, width: 1.4)
            fill(self.ellipse(8, 12.4, 3.2, 1.8), colors.belly)
        case .mouse:
            fill(self.pair(self.ellipse(2.9, 2.9, 1.35, 1.35)), colors.blush)
            fill(self.ellipse(8, 8.6, 4.6, 2.6), colors.face)
            nose(9.5, colors.blush, width: 1.3)
        case .penguin:
            let plate = CGMutablePath()
            plate.addPath(self.ellipse(5.9, 7.6, 2.3, 2.1))
            plate.addPath(self.ellipse(10.1, 7.6, 2.3, 2.1))
            plate.addPath(self.ellipse(8, 11.2, 4.2, 3))
            fill(plate, colors.face)
            let beak = self.triangle(CGPoint(x: 7.2, y: 8.1), CGPoint(x: 8.8, y: 8.1), CGPoint(x: 8, y: 9.3))
            context.addPath(beak)
            context.setFillColor(colors.beak)
            context.fillPath()
        case .chick:
            fill(self.ellipse(8, 11.9, 3.8, 2.3), colors.belly)
            let beak = self.triangle(CGPoint(x: 7.2, y: 9.1), CGPoint(x: 8.8, y: 9.1), CGPoint(x: 8, y: 10.3))
            context.addPath(beak)
            context.setFillColor(colors.beak)
            context.fillPath()
        case .pig:
            fill(self.pair(self.triangle(CGPoint(x: 3.5, y: 5.0), CGPoint(x: 5.0, y: 4.4),
                                         CGPoint(x: 3.2 - twitch * 0.6, y: 3.6 + twitch * 0.5))), colors.blush)
            let snout = self.ellipse(8, 10.3, 2.2, 1.3)
            context.addPath(snout)
            context.setStrokeColor(colors.petalDark)
            context.setLineWidth(0.4)
            context.strokePath()
            fill(snout, colors.blush)
            fill(self.pair(self.ellipse(7.3, 10.3, 0.35, 0.5)), colors.eye)
        case .ghost, .cloud, .octopus:
            break
        case .mushroom:
            for (x, y, r) in [(4.6, 5.0, 1.1), (10.2, 3.6, 1.0), (12.6, 5.9, 0.7), (7.3, 2.6, 0.6)] {
                fill(self.ellipse(x, y, r, r * 0.9), colors.trim)
            }
            fill(rounded(4, 8.4, 8, 3.2, 1.5), colors.face)
        case .axolotl:
            fill(self.ellipse(8, 8.1, 4.8, 2.6), colors.face)
        case .hedgehog:
            fill(self.ellipse(8, 9, 4.8, 2.7), colors.face)
            nose(9.3, colors.eye, width: 1.3)
        }
    }
}
