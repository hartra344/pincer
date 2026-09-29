import CoreGraphics
import CoreText
import Foundation

struct MathSeg {
    var cmd: Character
    var pts: [CGPoint]
}

enum MathPrim {
    case text(x: CGFloat, y: CGFloat, s: String, size: CGFloat, face: MathFace, error: Bool)
    case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, w: CGFloat)
    case path([MathSeg], w: CGFloat)
    case dot(x: CGFloat, y: CGFloat, r: CGFloat)

    func shifted(_ dx: CGFloat, _ dy: CGFloat) -> MathPrim {
        switch self {
        case let .text(x, y, s, size, face, error): .text(x: x + dx, y: y + dy, s: s, size: size, face: face, error: error)
        case let .line(x1, y1, x2, y2, w): .line(x1: x1 + dx, y1: y1 + dy, x2: x2 + dx, y2: y2 + dy, w: w)
        case let .path(segs, w): .path(segs.map { MathSeg(cmd: $0.cmd, pts: $0.pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }) }, w: w)
        case let .dot(x, y, r): .dot(x: x + dx, y: y + dy, r: r)
        }
    }

    func svg(dx: CGFloat, dy: CGFloat, text: String, error: String) -> String {
        let n = RichRenderSVG.number
        switch self.shifted(dx, dy) {
        case let .text(x, y, s, size, face, isError):
            let style = (face == .italic || face == .boldItalic) ? #" font-style="italic""# : ""
            let weight = (face == .bold || face == .boldItalic) ? #" font-weight="bold""# : ""
            return #"<text x="\#(n(x))" y="\#(n(y))" font-family="\#(MathLayout.family)" font-size="\#(n(size))"\#(style)\#(weight) fill="\#(isError ? error : text)">\#(RichRenderSVG.escape(s))</text>"#
        case let .line(x1, y1, x2, y2, w):
            return #"<line x1="\#(n(x1))" y1="\#(n(y1))" x2="\#(n(x2))" y2="\#(n(y2))" stroke="\#(text)" stroke-width="\#(n(w))"/>"#
        case let .path(segs, w):
            let d = segs.map { seg in String(seg.cmd) + seg.pts.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: " ") }.joined(separator: " ")
            return #"<path d="\#(d)" fill="none" stroke="\#(text)" stroke-width="\#(n(w))" stroke-linecap="round" stroke-linejoin="round"/>"#
        case let .dot(x, y, r):
            return #"<circle cx="\#(n(x))" cy="\#(n(y))" r="\#(n(r))" fill="\#(text)"/>"#
        }
    }
}

/// Positioned content; `y` is measured downward from the box's baseline.
struct MathBox {
    var w: CGFloat = 0
    var asc: CGFloat = 0
    var desc: CGFloat = 0
    var prims: [MathPrim] = []

    mutating func place(_ b: MathBox, dx: CGFloat, dy: CGFloat) {
        prims += b.prims.map { $0.shifted(dx, dy) }
        w = max(w, dx + b.w)
        asc = max(asc, b.asc - dy)
        desc = max(desc, b.desc + dy)
    }
}

enum MathLayout {
    static let family = "Times New Roman, Times, serif"

    struct Ctx {
        var size: CGFloat
        var base: CGFloat
        var depth: Int
        var face: MathFace?
        /// Text style (inline math): big operators stay small with side limits, fractions shrink.
        var inline = false
        var axis: CGFloat { size * 0.25 }
        func script() -> Ctx { Ctx(size: max(size * 0.7, base * 0.5), base: base, depth: depth + 1, face: face, inline: inline) }
    }

    // MARK: Measurement

    static func fontName(_ face: MathFace) -> String {
        switch face {
        case .italic: "TimesNewRomanPS-ItalicMT"
        case .bold: "TimesNewRomanPS-BoldMT"
        case .boldItalic: "TimesNewRomanPS-BoldItalicMT"
        case .roman, .bb: "TimesNewRomanPSMT"
        }
    }

    static func measure(_ s: String, size: CGFloat, face: MathFace) -> (w: CGFloat, asc: CGFloat, desc: CGFloat) {
        _ = RichRenderSVG.fontsReady
        let font = CTFontCreateWithName(fontName(face) as CFString, size, nil)
        let str = CFAttributedStringCreate(nil, s as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(str)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if b.isNull || b.isEmpty { return (w, 0, 0) }
        return (w, max(0, b.maxY), max(0, -b.minY))
    }

    static func textBox(_ s: String, _ ctx: Ctx, _ face: MathFace, error: Bool = false, size: CGFloat? = nil) -> MathBox {
        let size = size ?? ctx.size
        let m = measure(s, size: size, face: face)
        return MathBox(w: m.w, asc: m.asc, desc: m.desc,
                       prims: [.text(x: 0, y: 0, s: s, size: size, face: face, error: error)])
    }

    // MARK: Layout

    static func kind(_ n: MathNode) -> MathKind {
        switch n {
        case .atom(_, let k, _): k
        case .script(let b, _, _): kind(b)
        case .bigop, .fn: .op
        case .styled(_, let inner): kind(inner)
        case .group(let items) where items.count == 1: kind(items[0])
        default: .ord
        }
    }

    static func gap(_ prev: MathKind, _ cur: MathKind, _ ctx: Ctx) -> CGFloat {
        let s = ctx.size
        if ctx.size < ctx.base * 0.9 { return prev == .punct ? 0.1 * s : 0 }
        if prev == .bin || cur == .bin { return 0.22 * s }
        if cur == .rel || prev == .rel {
            return (cur == .close || prev == .open) ? 0 : 0.28 * s
        }
        if prev == .punct { return cur == .close || cur == .punct ? 0 : 0.17 * s }
        if (prev == .op || prev == .fn), [.ord, .op, .fn].contains(cur) { return 0.17 * s }
        if (cur == .op || cur == .fn), [.ord, .close].contains(prev) { return 0.17 * s }
        return 0
    }

    static func row(_ nodes: [MathNode], _ ctx: Ctx) -> MathBox {
        var kinds = nodes.map(kind)
        for i in kinds.indices where kinds[i] == .bin {
            let prev: MathKind? = i > 0 ? kinds[i - 1] : nil
            let next: MathKind? = i + 1 < kinds.count ? kinds[i + 1] : nil
            if prev == nil || [.bin, .rel, .open, .punct, .op, .fn].contains(prev!) || next == nil || [.rel, .close, .punct].contains(next!) {
                kinds[i] = .ord
            }
        }
        var out = MathBox()
        var x: CGFloat = 0
        var prev: MathKind?
        for (n, k) in zip(nodes, kinds) {
            if case .space = n {} else {
                if let p = prev { x += gap(p, k, ctx) }
                prev = k
            }
            let b = layout(n, ctx)
            out.place(b, dx: x, dy: 0)
            x += b.w
        }
        out.w = x
        return out
    }

    static func layout(_ n: MathNode, _ ctx: Ctx) -> MathBox {
        let s = ctx.size
        switch n {
        case .atom(let str, _, let face):
            return atomBox(str, face: ctx.face ?? face, ctx)
        case .group(let items): return row(items, ctx)
        case .space(let em): return MathBox(w: em * s)
        case .text(let str):
            return textBox(str.replacingOccurrences(of: " ", with: "\u{00A0}"), ctx, .roman)
        case .unknown(let name):
            return textBox("\\" + name, ctx, .roman, error: true)
        case .styled(let face, let inner):
            var c = ctx; c.face = face
            return layout(inner, c)
        case .fn(let name, _): return textBox(name, ctx, .roman)
        case .bigop(let g, _): return bigOpGlyph(g, ctx)
        case .script(let base, let sub, let sup): return scriptBox(base, sub, sup, ctx)
        case .frac(let a, let b, let bar, let mode): return fracBox(a, b, bar: bar, mode: mode, ctx)
        case .sqrt(let idx, let body): return sqrtBox(idx, body, ctx)
        case .accent(let name, let body): return accentBox(name, body, ctx)
        case .delim(let l, let r, let items):
            return delimBox(l, r, inner: row(items, ctx), height: nil, ctx)
        case .sized(let d, let h):
            let isRight = [")", "]", "}", "⟩", "⌋", "⌉"].contains(d)
            var box = MathBox(w: 0, asc: h * s / 2 + ctx.axis, desc: h * s / 2 - ctx.axis)
            box = isRight ? delimBox(".", d, inner: box, height: h * s, ctx, pad: false) : delimBox(d, ".", inner: box, height: h * s, ctx, pad: false)
            return box
        case .table(let kind, let rows): return tableBox(kind, rows, ctx)
        }
    }

    /// CoreSVG ignores `font-style`, so italic/bold variables use the Unicode Mathematical Alphanumeric block.
    static func styled(_ text: String, _ face: MathFace) -> String {
        String(text.unicodeScalars.map { u -> String in
            let v = u.value
            func at(_ base: UInt32, _ off: UInt32) -> String { String(UnicodeScalar(base + off)!) }
            switch (face, v) {
            case (.italic, 0x68): return "ℎ"
            case (.italic, 0x41...0x5A): return at(0x1D434, v - 0x41)
            case (.italic, 0x61...0x7A): return at(0x1D44E, v - 0x61)
            case (.italic, 0x3B1...0x3C9) where v != 0x3C2: return at(0x1D6FC, v - 0x3B1)
            case (.boldItalic, 0x41...0x5A): return at(0x1D468, v - 0x41)
            case (.boldItalic, 0x61...0x7A): return at(0x1D482, v - 0x61)
            case (.bold, 0x41...0x5A): return at(0x1D400, v - 0x41)
            case (.bold, 0x61...0x7A): return at(0x1D41A, v - 0x61)
            case (.bold, 0x30...0x39): return at(0x1D7CE, v - 0x30)
            default: return String(u)
            }
        }.joined())
    }

    static func atomBox(_ str: String, face: MathFace, _ ctx: Ctx) -> MathBox {
        var text = str
        if face == .bb {
            text = str.map { MathParser.bbMap[$0] ?? String($0) }.joined()
        } else {
            text = styled(str, face)
        }
        var box = textBox(text, ctx, .roman)
        if face == .italic { box.w += ctx.size * 0.04 }
        return box
    }

    static func bigOpGlyph(_ g: String, _ ctx: Ctx) -> MathBox {
        if ctx.depth > 0 || ctx.inline { return textBox(g, ctx, .roman) }
        let scale: CGFloat = g == "∫" || g == "∬" || g == "∭" || g == "∮" ? 1.5 : 1.4
        let size = ctx.size * scale
        let m = measure(g, size: size, face: .roman)
        let center = (m.asc - m.desc) / 2
        let drop = center - ctx.axis
        return MathBox(w: m.w + ctx.size * 0.06, asc: m.asc - drop, desc: m.desc + drop,
                       prims: [.text(x: 0, y: drop, s: g, size: size, face: .roman, error: false)])
    }

    static func scriptBox(_ base: MathNode, _ sub: MathNode?, _ sup: MathNode?, _ ctx: Ctx) -> MathBox {
        let s = ctx.size
        var limits = false
        var baseBox: MathBox
        var isIntegral = false
        switch base {
        case .bigop(let g, let l):
            baseBox = bigOpGlyph(g, ctx)
            limits = l && ctx.depth == 0 && !ctx.inline
            isIntegral = ["∫", "∬", "∭", "∮"].contains(g)
        case .fn(let name, let l):
            baseBox = textBox(name, ctx, .roman)
            limits = l && ctx.depth == 0 && !ctx.inline
        default:
            baseBox = layout(base, ctx)
        }
        let sc = ctx.script()
        let subBox = sub.map { layout($0, sc) }
        let supBox = sup.map { layout($0, sc) }
        var out = MathBox()
        if limits {
            let g = 0.12 * s
            let w = max(baseBox.w, subBox?.w ?? 0, supBox?.w ?? 0)
            out.place(baseBox, dx: (w - baseBox.w) / 2, dy: 0)
            if let u = supBox { out.place(u, dx: (w - u.w) / 2, dy: -(baseBox.asc + g + u.desc)) }
            if let d = subBox { out.place(d, dx: (w - d.w) / 2, dy: baseBox.desc + g + d.asc) }
            out.w = w
            return out
        }
        out.place(baseBox, dx: 0, dy: 0)
        var x = baseBox.w
        var supY: CGFloat = 0, subY: CGFloat = 0
        let isBigOp = { if case .bigop = base { return true } else { return false } }()
        if isBigOp {
            supY = -(baseBox.asc - (supBox?.asc ?? 0) * 0.5)
            subY = baseBox.desc - (subBox?.desc ?? 0) * 0.5
        } else {
            supY = -max(0.4 * s, baseBox.asc - 0.3 * sc.size)
            subY = max(0.2 * s, baseBox.desc + 0.1 * s)
            if isEmptyScriptBase(base) { supY = -0.4 * s; subY = 0.2 * s }
        }
        if let u = supBox, let d = subBox {
            let need = (u.desc - supY) + (d.asc + subY)
            let minGap = 0.15 * s
            _ = need
            let dist = subY - supY - u.desc - d.asc
            if dist < minGap { subY += minGap - dist }
        }
        let subX = isIntegral ? x - 0.35 * s : x
        let supX = isIntegral ? x + 0.1 * s : x
        if let d = subBox { out.place(d, dx: subX, dy: subY) }
        if let u = supBox { out.place(u, dx: supX, dy: supY) }
        x = max(subX + (subBox?.w ?? 0), supX + (supBox?.w ?? 0))
        out.w = x + 0.03 * s
        return out
    }

    static func isEmptyScriptBase(_ n: MathNode) -> Bool {
        if case .group(let items) = n { return items.isEmpty }
        return false
    }

    static func fracBox(_ a: MathNode, _ b: MathNode, bar: Bool, mode: Character, _ ctx: Ctx) -> MathBox {
        var c = ctx
        c.depth += 1
        switch mode {
        case "t": c.size = ctx.size * 0.8
        case "d": break
        default: c.size = ctx.depth == 0 && !ctx.inline ? ctx.size : max(ctx.size * 0.75, ctx.base * 0.5)
        }
        let s = ctx.size
        let num = layout(a, c), den = layout(b, c)
        let axis = ctx.axis
        let t = bar ? max(0.9, 0.055 * s) : 0
        let g = 0.16 * s
        let w = max(num.w, den.w) + 0.2 * s
        var out = MathBox()
        out.w = w
        out.place(num, dx: (w - num.w) / 2, dy: -(axis + t / 2 + g + num.desc))
        out.place(den, dx: (w - den.w) / 2, dy: -axis + t / 2 + g + den.asc)
        if bar {
            out.prims.append(.line(x1: 0.05 * s, y1: -axis, x2: w - 0.05 * s, y2: -axis, w: t))
        }
        return out
    }

    static func sqrtBox(_ index: MathNode?, _ body: MathNode, _ ctx: Ctx) -> MathBox {
        let s = ctx.size
        let b = layout(body, ctx)
        let t = max(0.9, 0.055 * s)
        let a = max(b.asc, 0.62 * s)
        let top = -(a + 0.14 * s)
        let bottom = b.desc + 0.03 * s
        let hh = bottom - top
        let rw = 0.6 * s
        var idxBox: MathBox?
        if let index { var c = ctx.script(); c.size = max(ctx.size * 0.6, ctx.base * 0.45); idxBox = layout(index, c) }
        let off = max(0, (idxBox?.w ?? 0) - 0.2 * s)
        var out = MathBox()
        let path: [MathSeg] = [
            MathSeg(cmd: "M", pts: [CGPoint(x: off, y: top + 0.62 * hh)]),
            MathSeg(cmd: "L", pts: [CGPoint(x: off + 0.16 * rw, y: top + 0.56 * hh),
                                     CGPoint(x: off + 0.48 * rw, y: bottom),
                                     CGPoint(x: off + rw, y: top),
                                     CGPoint(x: off + rw + b.w + 0.1 * s, y: top)]),
        ]
        out.place(b, dx: off + rw + 0.05 * s, dy: 0)
        out.prims.append(.path(path, w: t))
        out.asc = max(out.asc, -top + t)
        out.desc = max(out.desc, bottom)
        out.w = off + rw + b.w + 0.15 * s
        if let i = idxBox { out.place(i, dx: max(0, off - i.w + 0.2 * s) * 0 + 0, dy: top + 0.45 * hh) }
        return out
    }

    static func accentBox(_ name: String, _ body: MathNode, _ ctx: Ctx) -> MathBox {
        let s = ctx.size
        let b = layout(body, ctx)
        var out = b
        let w = b.w
        let cx = w / 2
        let stroke = max(0.8, 0.05 * s)
        let top = -(max(b.asc, 0.45 * s) + 0.1 * s)
        let hw = min(max(w * 0.5, 0.15 * s), 0.5 * s)
        func add(_ p: MathPrim) { out.prims.append(p) }
        switch name {
        case "overline":
            add(.line(x1: 0, y1: top + 0.02 * s, x2: w, y2: top + 0.02 * s, w: stroke))
            out.asc = -top + stroke
        case "bar":
            add(.line(x1: cx - hw * 0.8, y1: top + 0.08 * s, x2: cx + hw * 0.8, y2: top + 0.08 * s, w: stroke))
            out.asc = max(b.asc, -top + stroke)
        case "underline":
            let y = b.desc + 0.12 * s
            add(.line(x1: 0, y1: y, x2: w, y2: y, w: stroke))
            out.desc = y + stroke
        case "hat", "widehat", "check":
            let h = name == "check" ? 0.12 * s : 0
            let half = name == "widehat" ? max(w / 2, hw) : hw * 0.8
            add(.path([MathSeg(cmd: "M", pts: [CGPoint(x: cx - half, y: top + 0.12 * s - h)]),
                       MathSeg(cmd: "L", pts: [CGPoint(x: cx, y: top + h), CGPoint(x: cx + half, y: top + 0.12 * s - h)])], w: stroke))
            out.asc = max(b.asc, -top + stroke)
        case "vec", "overrightarrow":
            let half = name == "vec" ? hw * 0.9 : max(w / 2, hw)
            let y = top + 0.08 * s
            add(.line(x1: cx - half, y1: y, x2: cx + half, y2: y, w: stroke))
            add(.path([MathSeg(cmd: "M", pts: [CGPoint(x: cx + half - 0.1 * s, y: y - 0.06 * s)]),
                       MathSeg(cmd: "L", pts: [CGPoint(x: cx + half, y: y), CGPoint(x: cx + half - 0.1 * s, y: y + 0.06 * s)])], w: stroke))
            out.asc = max(b.asc, -top + stroke + 0.06 * s)
        case "dot":
            add(.dot(x: cx, y: top + 0.06 * s, r: 0.05 * s)); out.asc = max(b.asc, -top + 0.05 * s)
        case "ddot":
            add(.dot(x: cx - 0.1 * s, y: top + 0.06 * s, r: 0.05 * s))
            add(.dot(x: cx + 0.1 * s, y: top + 0.06 * s, r: 0.05 * s)); out.asc = max(b.asc, -top + 0.05 * s)
        default: // tilde, widetilde
            let half = name == "widetilde" ? max(w / 2, hw) : hw * 0.8
            add(.path([MathSeg(cmd: "M", pts: [CGPoint(x: cx - half, y: top + 0.11 * s)]),
                       MathSeg(cmd: "C", pts: [CGPoint(x: cx - half * 0.4, y: top - 0.02 * s), CGPoint(x: cx - half * 0.1, y: top + 0.02 * s), CGPoint(x: cx, y: top + 0.06 * s)]),
                       MathSeg(cmd: "C", pts: [CGPoint(x: cx + half * 0.3, y: top + 0.12 * s), CGPoint(x: cx + half * 0.6, y: top + 0.12 * s), CGPoint(x: cx + half, y: top + 0.01 * s)])], w: stroke))
            out.asc = max(b.asc, -top + stroke)
        }
        return out
    }

    // MARK: Delimiters

    static func delimWidth(_ d: String, _ s: CGFloat) -> CGFloat {
        switch d {
        case ".": 0
        case "(", ")", "⟨", "⟩": 0.36 * s
        case "[", "]", "⌊", "⌋", "⌈", "⌉": 0.32 * s
        case "{", "}": 0.5 * s
        case "|", "/", "\\": 0.2 * s
        case "‖": 0.32 * s
        default: 0.3 * s
        }
    }

    static func delimPrims(_ d: String, x0: CGFloat, top: CGFloat, bot: CGFloat, ctx: Ctx) -> [MathPrim] {
        let s = ctx.size
        let w = delimWidth(d, s)
        let stroke = max(0.9, 0.055 * s)
        let x1 = x0 + w
        let mid = (top + bot) / 2
        let H = bot - top
        let inset = 0.08 * s
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch d {
        case ".": return []
        case "(":
            return [.path([MathSeg(cmd: "M", pts: [P(x1 - inset, top)]),
                           MathSeg(cmd: "C", pts: [P(x0 + inset, top + H * 0.28), P(x0 + inset, bot - H * 0.28), P(x1 - inset, bot)])], w: stroke)]
        case ")":
            return [.path([MathSeg(cmd: "M", pts: [P(x0 + inset, top)]),
                           MathSeg(cmd: "C", pts: [P(x1 - inset, top + H * 0.28), P(x1 - inset, bot - H * 0.28), P(x0 + inset, bot)])], w: stroke)]
        case "[", "⌈", "⌊":
            let a = P(x1 - inset, d == "⌊" ? top : top), b = P(x0 + inset * 1.5, top), c = P(x0 + inset * 1.5, bot), e = P(x1 - inset, bot)
            switch d {
            case "[": return [.path([MathSeg(cmd: "M", pts: [a]), MathSeg(cmd: "L", pts: [b, c, e])], w: stroke)]
            case "⌈": return [.path([MathSeg(cmd: "M", pts: [a]), MathSeg(cmd: "L", pts: [b, P(b.x, bot)])], w: stroke)]
            default: return [.path([MathSeg(cmd: "M", pts: [b]), MathSeg(cmd: "L", pts: [c, e])], w: stroke)]
            }
        case "]", "⌉", "⌋":
            let a = P(x0 + inset, top), b = P(x1 - inset * 1.5, top), c = P(x1 - inset * 1.5, bot), e = P(x0 + inset, bot)
            switch d {
            case "]": return [.path([MathSeg(cmd: "M", pts: [a]), MathSeg(cmd: "L", pts: [b, c, e])], w: stroke)]
            case "⌉": return [.path([MathSeg(cmd: "M", pts: [a]), MathSeg(cmd: "L", pts: [b, c])], w: stroke)]
            default: return [.path([MathSeg(cmd: "M", pts: [b]), MathSeg(cmd: "L", pts: [c, e])], w: stroke)]
            }
        case "{", "}":
            let q = min(H * 0.18, 0.3 * s)
            let xa = d == "{" ? x1 - inset : x0 + inset      // outer tips
            let xm = d == "{" ? x0 + w * 0.55 : x0 + w * 0.45 // spine
            let xt = d == "{" ? x0 + inset : x1 - inset       // middle point
            return [.path([MathSeg(cmd: "M", pts: [P(xa, top)]),
                           MathSeg(cmd: "Q", pts: [P(xm, top), P(xm, top + q)]),
                           MathSeg(cmd: "L", pts: [P(xm, mid - q)]),
                           MathSeg(cmd: "Q", pts: [P(xm, mid), P(xt, mid)]),
                           MathSeg(cmd: "Q", pts: [P(xm, mid), P(xm, mid + q)]),
                           MathSeg(cmd: "L", pts: [P(xm, bot - q)]),
                           MathSeg(cmd: "Q", pts: [P(xm, bot), P(xa, bot)])], w: stroke)]
        case "|": return [.line(x1: x0 + w / 2, y1: top, x2: x0 + w / 2, y2: bot, w: stroke)]
        case "‖":
            return [.line(x1: x0 + w / 2 - 0.05 * s, y1: top, x2: x0 + w / 2 - 0.05 * s, y2: bot, w: stroke),
                    .line(x1: x0 + w / 2 + 0.05 * s, y1: top, x2: x0 + w / 2 + 0.05 * s, y2: bot, w: stroke)]
        case "/": return [.line(x1: x1 - inset, y1: top, x2: x0 + inset, y2: bot, w: stroke)]
        case "\\": return [.line(x1: x0 + inset, y1: top, x2: x1 - inset, y2: bot, w: stroke)]
        case "⟨": return [.path([MathSeg(cmd: "M", pts: [P(x1 - inset, top)]), MathSeg(cmd: "L", pts: [P(x0 + inset, mid), P(x1 - inset, bot)])], w: stroke)]
        case "⟩": return [.path([MathSeg(cmd: "M", pts: [P(x0 + inset, top)]), MathSeg(cmd: "L", pts: [P(x1 - inset, mid), P(x0 + inset, bot)])], w: stroke)]
        default: return []
        }
    }

    static func delimBox(_ l: String, _ r: String, inner: MathBox, height: CGFloat?, _ ctx: Ctx, pad: Bool = true) -> MathBox {
        let s = ctx.size
        let axis = ctx.axis
        let half = max(inner.asc - axis, inner.desc + axis)
        let H = height ?? max(half * 2 + 0.1 * s, 1.15 * s)
        let top = -axis - H / 2, bot = -axis + H / 2
        let p = pad ? 0.06 * s : 0
        var out = MathBox()
        let lw = delimWidth(l, s), rw = delimWidth(r, s)
        out.prims += delimPrims(l, x0: 0, top: top, bot: bot, ctx: ctx)
        out.place(inner, dx: lw + p, dy: 0)
        let rx = lw + p + inner.w + p
        out.prims += delimPrims(r, x0: rx, top: top, bot: bot, ctx: ctx)
        out.w = rx + rw
        out.asc = max(out.asc, -top)
        out.desc = max(out.desc, bot)
        return out
    }

    // MARK: Tables

    static func tableBox(_ kind: MathTableKind, _ rows: [[[MathNode]]], _ ctx: Ctx) -> MathBox {
        let s = ctx.size
        let cells: [[MathBox]] = rows.map { $0.map { row($0, ctx) } }
        let cols = cells.map(\.count).max() ?? 0
        guard cols > 0 else { return MathBox() }
        var colW = [CGFloat](repeating: 0, count: cols)
        for r in cells { for (j, c) in r.enumerated() { colW[j] = max(colW[j], c.w) } }
        let rowAsc = cells.map { max($0.map(\.asc).max() ?? 0, 0.7 * s) }
        let rowDesc = cells.map { max($0.map(\.desc).max() ?? 0, 0.2 * s) }
        let rowGap: CGFloat
        var align: (Int) -> Character = { _ in "c" }
        var sep: (Int) -> CGFloat = { _ in s }
        var leftDelim = ".", rightDelim = "."
        switch kind {
        case .lines: rowGap = 0.35 * s; sep = { _ in 0 }
        case .matrix(let l, let r): rowGap = 0.3 * s; leftDelim = l.isEmpty ? "." : l; rightDelim = r.isEmpty ? "." : r
        case .cases: rowGap = 0.3 * s; align = { _ in "l" }; leftDelim = "{"
        case .aligned:
            rowGap = 0.3 * s
            align = { $0 % 2 == 0 ? "r" : "l" }
            sep = { $0 % 2 == 0 ? 0 : 2 * s }
        case .gather: rowGap = 0.3 * s; sep = { _ in 0 }
        }
        var colX = [CGFloat](repeating: 0, count: cols)
        var x: CGFloat = 0
        for j in 0..<cols { colX[j] = x; x += colW[j] + (j + 1 < cols ? sep(j) : 0) }
        let total = x
        let height = rowAsc.reduce(0, +) + rowDesc.reduce(0, +) + rowGap * CGFloat(max(rows.count - 1, 0))
        var out = MathBox()
        var top: CGFloat = 0
        for (i, r) in cells.enumerated() {
            let baseline = -ctx.axis - height / 2 + top + rowAsc[i]
            for (j, c) in r.enumerated() {
                let dx: CGFloat
                switch align(j) {
                case "r": dx = colX[j] + colW[j] - c.w
                case "l": dx = colX[j]
                default: dx = colX[j] + (colW[j] - c.w) / 2
                }
                let extra: CGFloat = { if case .lines = kind { return (total - c.w) / 2 - colX[j] } else { return 0 } }()
                let extra2: CGFloat = { if case .gather = kind { return (total - c.w) / 2 - colX[j] } else { return 0 } }()
                out.place(c, dx: dx + extra + extra2, dy: baseline)
            }
            top += rowAsc[i] + rowDesc[i] + rowGap
        }
        out.w = total
        out.asc = max(out.asc, height / 2 + ctx.axis)
        out.desc = max(out.desc, height / 2 - ctx.axis)
        if leftDelim == "." && rightDelim == "." { return out }
        var wrapped = delimBox(leftDelim, rightDelim, inner: out, height: nil, ctx)
        if case .cases = kind { wrapped.w += 0 }
        return wrapped
    }
}
