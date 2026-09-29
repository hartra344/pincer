import CoreGraphics
import CoreText
import Foundation

/// Native LaTeX display-math renderer: a small parser for a practical LaTeX math subset, a TeX-lite
/// box layout, and a static SVG emitter. Every glyph run is its own positioned `<text>` (CoreSVG
/// ignores `baseline-shift`), fraction bars/radicals/delimiters are `<line>`/`<path>` shapes.
public enum MathSource {
    public static func isMath(language: String) -> Bool {
        ["math", "latex", "tex", "katex"].contains(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func svg(for latex: String, theme: RichRenderSVG.Theme) -> String? {
        guard latex.count <= 4_000, let root = MathParser.parseDocument(latex) else { return nil }
        if root.unknownCount > 3 { return nil }
        let palette = RichRenderSVG.palette(theme)
        let error = theme == .dark ? "#FF7B72" : "#CC0000"
        let ctx = MathLayout.Ctx(size: 17, base: 17, depth: 0, face: nil)
        let box = MathLayout.layout(root.node, ctx)
        let pad: CGFloat = 4
        let width = max(box.w, 1) + pad * 2
        let height = box.asc + box.desc + pad * 2
        var body = ""
        for prim in box.prims {
            body += prim.svg(dx: pad, dy: pad + box.asc, text: palette.text, error: error)
        }
        return RichRenderSVG.document(width: width, height: height, theme: theme, card: false, body: body)
    }
}

// MARK: - Model

enum MathKind { case ord, bin, rel, open, close, punct, op, fn }
enum MathFace { case italic, roman, bold, boldItalic, bb }

indirect enum MathNode {
    case atom(String, MathKind, MathFace)
    case group([MathNode])
    case script(MathNode, MathNode?, MathNode?)
    case frac(MathNode, MathNode, bar: Bool, mode: Character)
    case sqrt(MathNode?, MathNode)
    case bigop(String, limits: Bool)
    case fn(String, limits: Bool)
    case delim(String, String, [MathNode])
    case sized(String, CGFloat)
    case accent(String, MathNode)
    case styled(MathFace, MathNode)
    case text(String)
    case space(CGFloat)
    case table(MathTableKind, [[[MathNode]]])
    case unknown(String)
}

enum MathTableKind { case lines, matrix(String, String), cases, aligned, gather }

struct MathParseResult {
    var node: MathNode
    var unknownCount: Int
}

// MARK: - Tokenizer

enum MathTok: Equatable {
    case char(Character), cmd(String), lbrace, rbrace, caret, underscore, amp, rowsep, ws
}

enum MathParser {
    struct Fail: Error {}

    static func tokenize(_ s: String) throws -> [MathTok] {
        var out: [MathTok] = []
        let chars = Array(s)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 1
                guard i < chars.count else { throw Fail() }
                if chars[i] == "\\" { out.append(.rowsep); i += 1 }
                else if chars[i].isLetter {
                    var name = ""
                    while i < chars.count, chars[i].isLetter, chars[i].isASCII { name.append(chars[i]); i += 1 }
                    if name.isEmpty { name = String(chars[i]); i += 1 }
                    out.append(.cmd(name))
                } else { out.append(.cmd(String(chars[i]))); i += 1 }
            case "{": depth += 1; out.append(.lbrace); i += 1
            case "}":
                depth -= 1
                if depth < 0 { throw Fail() }
                out.append(.rbrace); i += 1
            case "^": out.append(.caret); i += 1
            case "_": out.append(.underscore); i += 1
            case "&": out.append(.amp); i += 1
            case "%":
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case " ", "\t", "\n", "\r": out.append(.ws); i += 1
            default: out.append(.char(c)); i += 1
            }
        }
        if depth != 0 { throw Fail() }
        return out
    }

    static func stripWrappers(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$"), s.hasSuffix("$$"), s.count >= 4 { s = String(s.dropFirst(2).dropLast(2)) }
        else if s.hasPrefix("\\["), s.hasSuffix("\\]") { s = String(s.dropFirst(2).dropLast(2)) }
        else if s.hasPrefix("\\("), s.hasSuffix("\\)") { s = String(s.dropFirst(2).dropLast(2)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDocument(_ raw: String) -> MathParseResult? {
        let s = stripWrappers(raw)
        guard !s.isEmpty else { return nil }
        // Without explicit `\\` rows or environments, physical lines are separate stacked lines.
        let sources: [String]
        if s.contains("\\\\") || s.contains("\\begin") { sources = [s] }
        else { sources = s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        var rows: [[[MathNode]]] = []
        var unknown = 0
        for src in sources {
            guard let toks = try? tokenize(src) else { return nil }
            var p = Parser(toks: toks)
            do {
                var first = true
                while first || p.peek == .rowsep {
                    if !first { p.i += 1 }
                    first = false
                    let row = try p.parseRow { $0 == .rowsep }
                    rows.append([row])
                }
                if p.i < toks.count { return nil }
            } catch { return nil }
            unknown += p.unknown
        }
        if rows.count > 1, rows.last?.first?.isEmpty == true { rows.removeLast() }
        if rows.count == 1 { return MathParseResult(node: .group(rows[0][0]), unknownCount: unknown) }
        return MathParseResult(node: .table(.lines, rows), unknownCount: unknown)
    }

    static let greekLower: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "ell": "ℓ", "hbar": "ℏ", "imath": "ı", "jmath": "ȷ",
    ]
    static let greekUpper: [String: String] = [
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    static let symbols: [String: (String, MathKind)] = [
        "cdot": ("⋅", .bin), "times": ("×", .bin), "div": ("÷", .bin), "pm": ("±", .bin), "mp": ("∓", .bin),
        "ast": ("∗", .bin), "star": ("⋆", .bin), "circ": ("∘", .bin), "bullet": ("∙", .bin), "oplus": ("⊕", .bin),
        "otimes": ("⊗", .bin), "cup": ("∪", .bin), "cap": ("∩", .bin), "wedge": ("∧", .bin), "land": ("∧", .bin),
        "vee": ("∨", .bin), "lor": ("∨", .bin), "setminus": ("∖", .bin), "wedgeq": ("≙", .rel),
        "le": ("≤", .rel), "leq": ("≤", .rel), "ge": ("≥", .rel), "geq": ("≥", .rel), "ne": ("≠", .rel),
        "neq": ("≠", .rel), "approx": ("≈", .rel), "equiv": ("≡", .rel), "sim": ("∼", .rel), "simeq": ("≃", .rel),
        "cong": ("≅", .rel), "propto": ("∝", .rel), "ll": ("≪", .rel), "gg": ("≫", .rel), "to": ("→", .rel),
        "rightarrow": ("→", .rel), "leftarrow": ("←", .rel), "gets": ("←", .rel), "leftrightarrow": ("↔", .rel),
        "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel), "Leftrightarrow": ("⇔", .rel), "iff": ("⇔", .rel),
        "implies": ("⟹", .rel), "mapsto": ("↦", .rel), "uparrow": ("↑", .rel), "downarrow": ("↓", .rel),
        "in": ("∈", .rel), "notin": ("∉", .rel), "ni": ("∋", .rel), "subset": ("⊂", .rel), "subseteq": ("⊆", .rel),
        "supset": ("⊃", .rel), "supseteq": ("⊇", .rel), "perp": ("⊥", .rel), "parallel": ("∥", .rel), "mid": ("∣", .rel),
        "infty": ("∞", .ord), "partial": ("∂", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord), "exists": ("∃", .ord),
        "nexists": ("∄", .ord), "emptyset": ("∅", .ord), "varnothing": ("∅", .ord), "neg": ("¬", .ord), "lnot": ("¬", .ord),
        "angle": ("∠", .ord), "triangle": ("△", .ord), "aleph": ("ℵ", .ord), "Re": ("ℜ", .ord), "Im": ("ℑ", .ord),
        "prime": ("′", .ord), "ldots": ("…", .ord), "dots": ("…", .ord), "cdots": ("⋯", .ord), "vdots": ("⋮", .ord),
        "ddots": ("⋱", .ord), "dotsc": ("…", .ord), "dotsb": ("⋯", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord),
        "degree": ("°", .ord), "%": ("%", .ord), "$": ("$", .ord), "#": ("#", .ord), "&": ("&", .ord), "_": ("_", .ord),
        "colon": (":", .punct), "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open),
        "rfloor": ("⌋", .close), "lceil": ("⌈", .open), "rceil": ("⌉", .close), "{": ("{", .open), "}": ("}", .close),
        "lbrace": ("{", .open), "rbrace": ("}", .close), "|": ("‖", .ord), "vert": ("|", .ord), "Vert": ("‖", .ord),
        "backslash": ("\\", .ord), "checkmark": ("✓", .ord), "dagger": ("†", .bin),
    ]
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "limsup", "liminf", "max", "min", "sup", "inf", "det", "arg", "deg", "dim",
        "gcd", "hom", "ker", "Pr", "mod", "bmod", "sgn",
    ]
    static let limitFunctions: Set<String> = ["lim", "limsup", "liminf", "max", "min", "sup", "inf", "det", "gcd", "Pr"]
    static let bigOps: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
    ]
    static let nolimitOps: Set<String> = ["int", "iint", "iiint", "oint"]
    static let accents: Set<String> = [
        "hat", "widehat", "bar", "overline", "vec", "dot", "ddot", "tilde", "widetilde", "underline", "check", "overrightarrow",
    ]
    static let sizedNames: [String: CGFloat] = [
        "big": 1.2, "Big": 1.8, "bigg": 2.4, "Bigg": 3.0, "bigl": 1.2, "bigr": 1.2, "Bigl": 1.8, "Bigr": 1.8,
        "biggl": 2.4, "biggr": 2.4, "Biggl": 3.0, "Biggr": 3.0, "bigm": 1.2, "Bigm": 1.8,
    ]
    static let bbMap: [Character: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "H": "ℍ", "P": "ℙ", "E": "𝔼", "F": "𝔽",
    ]

    struct Parser {
        let toks: [MathTok]
        var i = 0
        var unknown = 0
        init(toks: [MathTok]) { self.toks = toks }

        var peek: MathTok? { i < toks.count ? toks[i] : nil }
        mutating func skipWS() { while peek == .ws { i += 1 } }

        mutating func parseRow(until stop: (MathTok) -> Bool) throws -> [MathNode] {
            var out: [MathNode] = []
            while true {
                skipWS()
                guard let t = peek, !stop(t) else { return out }
                if t == .rbrace { throw Fail() }
                if let n = try parseScripted() { out.append(n) }
            }
        }

        mutating func parseScripted() throws -> MathNode? {
            guard var base = try parseAtom() else { return nil }
            var sub: MathNode?, sup: MathNode?
            var sawScript = false
            while true {
                skipWS()
                guard let t = peek else { break }
                if t == .caret {
                    i += 1
                    let arg = try parseArg()
                    sup = sup.map { .group([$0, arg]) } ?? arg
                    sawScript = true
                } else if t == .underscore {
                    i += 1
                    sub = try parseArg()
                    sawScript = true
                } else if t == .char("'") {
                    i += 1
                    let p = MathNode.atom("′", .ord, .roman)
                    sup = sup.map { .group([$0, p]) } ?? p
                    sawScript = true
                } else { break }
            }
            if case .bigop(let g, _) = base, peek == .cmd("limits") || peek == .cmd("nolimits") {
                base = .bigop(g, limits: peek == .cmd("limits")); i += 1
                return try finishScripts(base)
            }
            return sawScript ? .script(base, sub, sup) : base
        }

        mutating func finishScripts(_ base: MathNode) throws -> MathNode {
            var sub: MathNode?, sup: MathNode?
            while true {
                skipWS()
                if peek == .caret { i += 1; sup = try parseArg() }
                else if peek == .underscore { i += 1; sub = try parseArg() }
                else { break }
            }
            return (sub == nil && sup == nil) ? base : .script(base, sub, sup)
        }

        mutating func parseArg() throws -> MathNode {
            skipWS()
            guard let t = peek else { throw Fail() }
            switch t {
            case .lbrace:
                i += 1
                let row = try parseRow { $0 == .rbrace }
                guard peek == .rbrace else { throw Fail() }
                i += 1
                return .group(row)
            case .char(let c) where c.isNumber || c.isLetter:
                i += 1
                return .atom(String(c), .ord, c.isLetter ? .italic : .roman)
            default:
                guard let n = try parseAtom() else { throw Fail() }
                return n
            }
        }

        mutating func rawGroup() throws -> String {
            skipWS()
            guard peek == .lbrace else { throw Fail() }
            i += 1
            var depth = 1
            var s = ""
            while i < toks.count {
                let t = toks[i]; i += 1
                switch t {
                case .lbrace: depth += 1; s += "{"
                case .rbrace:
                    depth -= 1
                    if depth == 0 { return s }
                    s += "}"
                case .char(let c): s.append(c)
                case .ws: s += " "
                case .caret: s += "^"
                case .underscore: s += "_"
                case .amp: s += "&"
                case .rowsep: s += " "
                case .cmd(let n):
                    if ["&", "%", "$", "_", "#", "{", "}"].contains(n) { s += n }
                    else if [",", ";", ":", " ", "quad", "qquad"].contains(n) { s += " " }
                }
            }
            throw Fail()
        }

        mutating func delimiter() throws -> String {
            skipWS()
            guard let t = peek else { throw Fail() }
            i += 1
            switch t {
            case .char(let c):
                switch c {
                case "(", ")", "[", "]", "|", ".", "/": return String(c)
                case "<": return "⟨"
                case ">": return "⟩"
                default: throw Fail()
                }
            case .cmd(let n):
                switch n {
                case "{", "lbrace": return "{"
                case "}", "rbrace": return "}"
                case "|", "Vert", "lVert", "rVert": return "‖"
                case "vert", "lvert", "rvert": return "|"
                case "langle": return "⟨"
                case "rangle": return "⟩"
                case "lfloor": return "⌊"
                case "rfloor": return "⌋"
                case "lceil": return "⌈"
                case "rceil": return "⌉"
                case "backslash": return "\\"
                default: throw Fail()
                }
            default: throw Fail()
            }
        }

        mutating func parseAtom() throws -> MathNode? {
            skipWS()
            guard let t = peek else { return nil }
            i += 1
            switch t {
            case .ws: return nil
            case .lbrace:
                let row = try parseRow { $0 == .rbrace }
                guard peek == .rbrace else { throw Fail() }
                i += 1
                return .group(row)
            case .rbrace, .caret, .underscore, .amp, .rowsep: throw Fail()
            case .char(let c): return atom(for: c)
            case .cmd(let name): return try command(name)
            }
        }

        mutating func atom(for c: Character) -> MathNode {
            if c.isNumber || (c == "." && peek.map({ if case .char(let d) = $0 { d.isNumber } else { false } }) == true) {
                var s = String(c)
                while let t = peek, case .char(let d) = t, d.isNumber || (d == "." && i + 1 < toks.count && { if case .char(let e) = toks[i + 1] { e.isNumber } else { false } }()) {
                    s.append(d); i += 1
                }
                return .atom(s, .ord, .roman)
            }
            if c.isLetter { return .atom(String(c), .ord, .italic) }
            switch c {
            case "+": return .atom("+", .bin, .roman)
            case "-": return .atom("−", .bin, .roman)
            case "*": return .atom("∗", .bin, .roman)
            case "=", "<", ">": return .atom(String(c), .rel, .roman)
            case ":": return .atom(":", .rel, .roman)
            case "(", "[": return .atom(String(c), .open, .roman)
            case ")", "]": return .atom(String(c), .close, .roman)
            case ",", ";": return .atom(String(c), .punct, .roman)
            case "~": return .space(0.3)
            default: return .atom(String(c), .ord, .roman)
            }
        }

        mutating func command(_ name: String) throws -> MathNode? {
            if let g = greekLower[name] { return .atom(g, .ord, .italic) }
            if let g = greekUpper[name] { return .atom(g, .ord, .roman) }
            if let (s, k) = symbols[name] { return .atom(s, k, .roman) }
            if let g = bigOps[name] { return .bigop(g, limits: !nolimitOps.contains(name)) }
            if functions.contains(name) { return .fn(name == "bmod" || name == "mod" ? "mod" : name, limits: limitFunctions.contains(name)) }
            if accents.contains(name) { return .accent(name, try parseArg()) }
            if let h = sizedNames[name] {
                let d = try delimiter()
                return .sized(d, h)
            }
            switch name {
            case ",": return .space(3.0 / 18)
            case ":": return .space(4.0 / 18)
            case ";": return .space(5.0 / 18)
            case "!": return .space(-3.0 / 18)
            case " ": return .space(0.25)
            case "quad": return .space(1)
            case "qquad": return .space(2)
            case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "mathord", "nonumber", "notag", "hline", "middle": return nil
            case "frac", "dfrac", "tfrac", "cfrac":
                let a = try parseArg(), b = try parseArg()
                return .frac(a, b, bar: true, mode: name == "dfrac" || name == "cfrac" ? "d" : (name == "tfrac" ? "t" : "n"))
            case "binom", "dbinom", "tbinom":
                let a = try parseArg(), b = try parseArg()
                return .delim("(", ")", [.frac(a, b, bar: false, mode: "n")])
            case "sqrt":
                skipWS()
                var index: MathNode?
                if peek == .char("[") {
                    i += 1
                    var row: [MathNode] = []
                    while true {
                        skipWS()
                        guard let t = peek else { throw Fail() }
                        if t == .char("]") { i += 1; break }
                        if let n = try parseScripted() { row.append(n) }
                    }
                    index = .group(row)
                }
                return .sqrt(index, try parseArg())
            case "text", "textrm", "textnormal", "mbox", "hbox", "textbf", "textit":
                return .text(try rawGroup())
            case "mathrm", "mathsf", "mathtt", "mathnormal", "operatorname", "operatorname*", "mathop": return .styled(.roman, try parseArg())
            case "mathbf", "boldsymbol", "bm", "bf", "pmb": return .styled(.bold, try parseArg())
            case "mathit": return .styled(.italic, try parseArg())
            case "mathbb", "Bbb": return .styled(.bb, try parseArg())
            case "mathcal", "mathscr", "mathfrak", "cal": return .styled(.italic, try parseArg())
            case "left":
                let l = try delimiter()
                let row = try parseRow { $0 == .cmd("right") }
                guard peek == .cmd("right") else { throw Fail() }
                i += 1
                return .delim(l, try delimiter(), row)
            case "right": throw Fail()
            case "begin": return try environment()
            case "end": throw Fail()
            case "quad_": return nil
            default:
                unknown += 1
                return .unknown(name)
            }
        }

        mutating func environment() throws -> MathNode {
            let name = try rawGroup().trimmingCharacters(in: .whitespaces)
            var rows: [[[MathNode]]] = []
            var row: [[MathNode]] = []
            while true {
                let cell = try parseRow { $0 == .amp || $0 == .rowsep || $0 == .cmd("end") }
                row.append(cell)
                guard let t = peek else { throw Fail() }
                i += 1
                if t == .amp { continue }
                if t == .rowsep { rows.append(row); row = []; continue }
                let closing = try rawGroup().trimmingCharacters(in: .whitespaces)
                guard closing == name else { throw Fail() }
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                break
            }
            let base = name.hasSuffix("*") ? String(name.dropLast()) : name
            let kind: MathTableKind
            switch base {
            case "matrix", "smallmatrix": kind = .matrix("", "")
            case "pmatrix": kind = .matrix("(", ")")
            case "bmatrix": kind = .matrix("[", "]")
            case "Bmatrix": kind = .matrix("{", "}")
            case "vmatrix": kind = .matrix("|", "|")
            case "Vmatrix": kind = .matrix("‖", "‖")
            case "cases": kind = .cases
            case "aligned", "align", "alignat", "split", "eqnarray": kind = .aligned
            case "gather", "gathered", "equation", "multline": kind = .gather
            default: throw Fail()
            }
            return .table(kind, rows)
        }
    }
}

