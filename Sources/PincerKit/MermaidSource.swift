import CoreGraphics
import Foundation

/// Native Mermaid rendering (issue #40): parses a subset of Mermaid (flowchart, sequenceDiagram, pie),
/// lays it out and emits a static SVG restricted to what CoreSVG draws (see `RichRenderSVG`).
public enum MermaidSource {
    static let maxCharacters = 20_000
    static let maxNodes = 150
    static let maxEdges = 400

    /// True for a fence language of "mermaid" (case-insensitive, trimmed).
    public static func isMermaid(language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid"
    }

    /// SVG for a mermaid diagram, or nil when the diagram type or syntax isn't supported (the transcript
    /// then keeps showing it as code). Pure, thread-safe, deterministic; no caching (the caller caches).
    public static func svg(for code: String, theme: RichRenderSVG.Theme) -> String? {
        guard code.count <= maxCharacters else { return nil }
        var lines = code.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }

        var title: String?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
                return nil
            }
            for line in lines[1..<close] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("title:") {
                    title = cleanLabel(String(trimmed.dropFirst(6)))
                }
            }
            lines = Array(lines[(close + 1)...])
        }
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }
        let keyword = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? header
        let rest = Array(lines.dropFirst())

        var canvas: Canvas?
        switch keyword.lowercased() {
        case "graph", "flowchart", "flowchart-elk":
            guard let chart = MermaidFlowchart.parse(header: header, lines: rest) else { return nil }
            canvas = chart.render(theme: theme)
        case "sequencediagram":
            guard let diagram = MermaidSequence.parse(lines: rest) else { return nil }
            if title == nil { title = diagram.title }
            canvas = diagram.render(theme: theme)
        case "pie":
            guard let pie = MermaidPie.parse(header: header, lines: rest) else { return nil }
            if title == nil { title = pie.title }
            canvas = pie.render(theme: theme)
        default:
            return nil
        }
        guard let canvas else { return nil }
        return finish(canvas, title: title, theme: theme)
    }

    // MARK: - Shared drawing helpers

    /// Accumulates SVG body text and the bounding box of what was drawn.
    struct Canvas {
        var body = ""
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity

        var isEmpty: Bool { body.isEmpty }

        mutating func include(_ rect: CGRect) {
            minX = min(minX, rect.minX); minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }

        mutating func include(_ point: CGPoint) {
            include(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }

        mutating func add(_ svg: String) { body += svg }
    }

    static func finish(_ canvas: Canvas, title: String?, theme: RichRenderSVG.Theme) -> String? {
        guard !canvas.isEmpty, canvas.minX.isFinite, canvas.maxX.isFinite else { return nil }
        let palette = RichRenderSVG.palette(theme)
        let pad: CGFloat = 16
        let contentW = canvas.maxX - canvas.minX, contentH = canvas.maxY - canvas.minY
        var width = contentW + pad * 2
        var titleHeight: CGFloat = 0
        var titleSVG = ""
        if let title, !title.isEmpty {
            let titleWidth = RichRenderSVG.textWidth(title, size: 15, bold: true)
            width = max(width, titleWidth + pad * 2)
            titleHeight = 30
            titleSVG = text(width / 2, pad + 14, title, size: 15, fill: palette.text, bold: true)
        }
        let height = contentH + pad * 2 + titleHeight
        let dx = pad + (width - pad * 2 - contentW) / 2 - canvas.minX
        let dy = pad + titleHeight - canvas.minY
        let body = titleSVG
            + #"<g transform="translate(\#(RichRenderSVG.number(dx)) \#(RichRenderSVG.number(dy)))">"# + canvas.body + "</g>"
        return RichRenderSVG.document(width: width, height: height, theme: theme, body: body)
    }

    static func n(_ value: CGFloat) -> String { RichRenderSVG.number(value) }

    /// One `<text>` element with an explicit baseline (CoreSVG ignores dominant-baseline).
    static func text(_ x: CGFloat, _ baseline: CGFloat, _ string: String, size: CGFloat, fill: String,
                     anchor: String = "middle", bold: Bool = false) -> String {
        let weight = bold ? #" font-weight="bold""# : ""
        return #"<text x="\#(n(x))" y="\#(n(baseline))" fill="\#(fill)" font-family="\#(RichRenderSVG.fontFamily)" font-size="\#(n(size))" text-anchor="\#(anchor)"\#(weight)>\#(RichRenderSVG.escape(string))</text>"#
    }

    /// Vertically centered multi-line text block.
    static func textBlock(centerX: CGFloat, centerY: CGFloat, lines: [String], size: CGFloat, fill: String,
                          lineHeight: CGFloat, anchor: String = "middle", bold: Bool = false) -> String {
        var out = ""
        let top = centerY - CGFloat(lines.count - 1) * lineHeight / 2
        for (index, line) in lines.enumerated() {
            out += text(centerX, top + CGFloat(index) * lineHeight + size * 0.35, line, size: size, fill: fill,
                        anchor: anchor, bold: bold)
        }
        return out
    }

    static func textLines(_ label: String) -> [String] {
        let lines = label.components(separatedBy: "\n")
        return lines.isEmpty ? [""] : lines
    }

    static func maxWidth(_ lines: [String], size: CGFloat, bold: Bool = false) -> CGFloat {
        lines.map { RichRenderSVG.textWidth($0, size: size, bold: bold) }.max() ?? 0
    }

    /// Strips quotes and simple HTML, turns `<br>` into newlines and decodes `#quot;`-style entities.
    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        for (name, value) in [("quot", "\""), ("amp", "&"), ("lt", "<"), ("gt", ">"), ("apos", "'")] {
            s = s.replacingOccurrences(of: "#\(name);", with: value)
        }
        while let range = s.range(of: #"#\d+;"#, options: .regularExpression) {
            let digits = s[range].dropFirst().dropLast()
            let scalar = Int(digits).flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
            s.replaceSubrange(range, with: scalar)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func arrowHead(tip: CGPoint, from: CGPoint, length: CGFloat = 9, halfWidth: CGFloat = 4.5, fill: String) -> String {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / d, uy = dy / d
        let bx = tip.x - ux * length, by = tip.y - uy * length
        let p1 = CGPoint(x: bx - uy * halfWidth, y: by + ux * halfWidth)
        let p2 = CGPoint(x: bx + uy * halfWidth, y: by - ux * halfWidth)
        return #"<polygon points="\#(n(tip.x)),\#(n(tip.y)) \#(n(p1.x)),\#(n(p1.y)) \#(n(p2.x)),\#(n(p2.y))" fill="\#(fill)"/>"#
    }
}

// MARK: - Sequence diagram

struct MermaidSequence {
    struct Participant { var id: String; var label: String; var actor: Bool }
    enum Head { case filled, open, cross, async }
    enum NoteKind { case left, right, over }
    enum Event {
        case message(from: Int, to: Int, text: String, dashed: Bool, head: Head)
        case note(kind: NoteKind, from: Int, to: Int, text: String)
        case blockStart(kind: String, label: String, drawn: Bool)
        case divider(label: String)
        case blockEnd
    }

    var participants: [Participant] = []
    var events: [Event] = []
    var title: String?
    var autonumber = false
    var messageCount = 0

    static let blockKinds: Set<String> = ["loop", "alt", "opt", "par", "critical", "break", "rect", "box"]
    static let dividerKinds: Set<String> = ["else", "and", "option"]
    static let ignoredKinds: Set<String> = [
        "activate", "deactivate", "create", "destroy", "link", "links", "properties", "details", "accdescr", "acctitle",
    ]

    mutating func participant(_ id: String, label: String? = nil, actor: Bool = false) -> Int {
        if let index = participants.firstIndex(where: { $0.id == id }) {
            if let label { participants[index].label = label }
            if actor { participants[index].actor = true }
            return index
        }
        participants.append(Participant(id: id, label: label ?? id, actor: actor))
        return participants.count - 1
    }

    static func parse(lines: [String]) -> MermaidSequence? {
        var diagram = MermaidSequence()
        let messageRegex = try! NSRegularExpression(
            pattern: #"^(\S+?)\s*(-->>|->>|-->|->|--x|-x|--\)|-\))\s*([+-]?)\s*(\S+?)\s*(?::\s*(.*))?$"#)
        let noteRegex = try! NSRegularExpression(pattern: #"^note\s+(right of|left of|over)\s+([^:]+?)\s*:\s*(.*)$"#,
                                                 options: .caseInsensitive)
        for line in lines {
            if diagram.participants.count > MermaidSource.maxNodes || diagram.messageCount > MermaidSource.maxEdges { return nil }
            let word = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? line
            let lower = word.lowercased()
            let rest = String(line.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
            switch lower {
            case "participant", "actor":
                var id = rest, label: String?
                if let range = rest.range(of: " as ") {
                    id = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    label = MermaidSource.cleanLabel(String(rest[range.upperBound...]))
                }
                if let brace = id.range(of: "@{") { id = String(id[..<brace.lowerBound]) }
                if !id.isEmpty { _ = diagram.participant(id, label: label, actor: lower == "actor") }
                continue
            case "autonumber": diagram.autonumber = true; continue
            case "title": diagram.title = MermaidSource.cleanLabel(rest.hasPrefix(":") ? String(rest.dropFirst()) : rest); continue
            case "end": diagram.events.append(.blockEnd); continue
            default: break
            }
            if lower == "title:" { diagram.title = MermaidSource.cleanLabel(rest); continue }
            if blockKinds.contains(lower) {
                let drawn = lower != "rect" && lower != "box"
                diagram.events.append(.blockStart(kind: lower, label: MermaidSource.cleanLabel(rest), drawn: drawn))
                continue
            }
            if dividerKinds.contains(lower) { diagram.events.append(.divider(label: MermaidSource.cleanLabel(rest))); continue }
            if ignoredKinds.contains(lower) { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = noteRegex.firstMatch(in: line, range: full) {
                let kindWord = ns.substring(with: m.range(at: 1)).lowercased()
                let names = ns.substring(with: m.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let first = names.first else { continue }
                let a = diagram.participant(first)
                let b = names.count > 1 ? diagram.participant(names[1]) : a
                let kind: NoteKind = kindWord.hasPrefix("right") ? .right : kindWord.hasPrefix("left") ? .left : .over
                diagram.events.append(.note(kind: kind, from: a, to: b, text: MermaidSource.cleanLabel(ns.substring(with: m.range(at: 3)))))
                continue
            }
            if let m = messageRegex.firstMatch(in: line, range: full) {
                func group(_ k: Int) -> String? {
                    m.range(at: k).location == NSNotFound ? nil : ns.substring(with: m.range(at: k))
                }
                guard let fromID = group(1), let op = group(2), let toID = group(4) else { continue }
                let from = diagram.participant(fromID), to = diagram.participant(toID)
                let head: Head = op.hasSuffix(">>") ? .filled : op.hasSuffix(">") ? .open : op.hasSuffix("x") ? .cross : .async
                diagram.events.append(.message(from: from, to: to, text: MermaidSource.cleanLabel(group(5) ?? ""),
                                               dashed: op.hasPrefix("--"), head: head))
                diagram.messageCount += 1
            }
        }
        guard !diagram.participants.isEmpty, diagram.participants.count <= MermaidSource.maxNodes,
              diagram.messageCount <= MermaidSource.maxEdges else { return nil }
        return diagram
    }

    func render(theme: RichRenderSVG.Theme) -> MermaidSource.Canvas? {
        let palette = RichRenderSVG.palette(theme)
        let n = MermaidSource.n
        let boxH: CGFloat = 36
        let lineH: CGFloat = 15
        let boxW = participants.map { max(80, MermaidSource.maxWidth(MermaidSource.textLines($0.label), size: 14) + 28) }

        func textWidth(_ s: String) -> CGFloat { MermaidSource.maxWidth(MermaidSource.textLines(s), size: 12) }
        var gaps: [CGFloat] = []
        for index in 0..<max(participants.count - 1, 0) {
            let half: CGFloat = (boxW[index] + boxW[index + 1]) / 2
            gaps.append(max(half + 20, 120))
        }
        func require(_ lo: Int, _ hi: Int, _ need: CGFloat) {
            guard lo < hi, hi <= gaps.count else { return }
            let have = gaps[lo..<hi].reduce(0, +)
            if have < need { for k in lo..<hi { gaps[k] += (need - have) / CGFloat(hi - lo) } }
        }
        for event in events {
            switch event {
            case let .message(from, to, text, _, _):
                if from == to { require(from, from + 1, textWidth(text) + 60) } else { require(min(from, to), max(from, to), textWidth(text) + 40) }
            case let .note(kind, from, to, text):
                let w = textWidth(text) + 20
                switch kind {
                case .right: require(from, from + 1, w + 30)
                case .left: require(from - 1, from, w + 30)
                case .over: if from != to { require(min(from, to), max(from, to), w - 20) }
                }
            default: break
            }
        }
        var cx: [CGFloat] = []
        var x: CGFloat = boxW.first.map { $0 / 2 } ?? 0
        for k in participants.indices {
            cx.append(x)
            if k < gaps.count { x += gaps[k] }
        }

        var canvas = MermaidSource.Canvas()
        var frames = "", body = ""
        var y = boxH + 26
        var number = 0
        var stack: [(kind: String, label: String, top: CGFloat, drawn: Bool)] = []
        let left = (cx.first ?? 0) - (boxW.first ?? 80) / 2 - 8
        let right = (cx.last ?? 0) + (boxW.last ?? 80) / 2 + 8

        func closeFrame(bottom: CGFloat) {
            guard let frame = stack.popLast(), frame.drawn else { return }
            let inset = CGFloat(stack.filter(\.drawn).count) * 8
            let rect = CGRect(x: left + inset, y: frame.top, width: right - left - inset * 2, height: bottom - frame.top)
            canvas.include(rect)
            frames += #"<rect x="\#(n(rect.minX))" y="\#(n(rect.minY))" width="\#(n(rect.width))" height="\#(n(rect.height))" fill="none" stroke="\#(palette.secondaryText)" stroke-width="1"/>"#
            let tabW = RichRenderSVG.textWidth(frame.kind, size: 12, bold: true) + 20
            frames += #"<rect x="\#(n(rect.minX))" y="\#(n(rect.minY))" width="\#(n(tabW))" height="18" fill="\#(palette.accentFill)" stroke="\#(palette.secondaryText)" stroke-width="1"/>"#
            frames += MermaidSource.text(rect.minX + tabW / 2, rect.minY + 13, frame.kind, size: 12, fill: palette.text, bold: true)
            if !frame.label.isEmpty {
                frames += MermaidSource.text(rect.minX + tabW + 8, rect.minY + 13, "[\(frame.label)]", size: 12, fill: palette.secondaryText, anchor: "start")
            }
        }

        for event in events {
            switch event {
            case let .message(from, to, rawText, dashed, head):
                var text = rawText
                if autonumber { number += 1; text = "\(number). " + text }
                let lines = text.isEmpty ? [] : MermaidSource.textLines(text)
                let dash = dashed ? #" stroke-dasharray="5 4""# : ""
                let stroke = #"stroke="\#(palette.edge)" stroke-width="1.5"\#(dash)"#
                if from == to {
                    let y1 = y + max(CGFloat(lines.count) * lineH, 8) + 2, y2 = y1 + 22
                    let x0 = cx[from], x1 = x0 + 34
                    let tip = CGPoint(x: x0, y: y2)
                    body += #"<path d="M\#(n(x0)) \#(n(y1)) L\#(n(x1)) \#(n(y1)) L\#(n(x1)) \#(n(y2)) L\#(n(x0 + 8)) \#(n(y2))" fill="none" \#(stroke)/>"#
                    body += Self.headSVG(head, tip: tip, from: CGPoint(x: x0 + 20, y: y2), palette: palette)
                    for (k, line) in lines.enumerated() {
                        body += MermaidSource.text(x0 + 6, y + 12 + CGFloat(k) * lineH, line, size: 12, fill: palette.text, anchor: "start")
                    }
                    canvas.include(CGRect(x: x0, y: y, width: 40 + textWidth(text), height: y2 - y))
                    y = y2 + 16
                } else {
                    let lineY = y + CGFloat(lines.count) * lineH + 8
                    let x1 = cx[from], x2 = cx[to]
                    let dir: CGFloat = x2 > x1 ? 1 : -1
                    let end = (head == .filled || head == .async) ? x2 - dir * 8 : x2
                    body += #"<line x1="\#(n(x1))" y1="\#(n(lineY))" x2="\#(n(end))" y2="\#(n(lineY))" \#(stroke)/>"#
                    body += Self.headSVG(head, tip: CGPoint(x: x2, y: lineY), from: CGPoint(x: x1, y: lineY), palette: palette)
                    for (k, line) in lines.enumerated() {
                        body += MermaidSource.text((x1 + x2) / 2, y + 12 + CGFloat(k) * lineH, line, size: 12, fill: palette.text)
                    }
                    y = lineY + 20
                }
            case let .note(kind, from, to, text):
                let lines = MermaidSource.textLines(text)
                let w = textWidth(text) + 20, h = CGFloat(lines.count) * lineH + 12
                var rectX: CGFloat
                switch kind {
                case .right: rectX = cx[from] + 12
                case .left: rectX = cx[from] - 12 - w
                case .over:
                    let lo = min(cx[from], cx[to]), hi = max(cx[from], cx[to])
                    rectX = (lo + hi) / 2 - max(w, hi - lo + 20) / 2
                }
                let width = kind == .over ? max(w, abs(cx[to] - cx[from]) + 20) : w
                y += 4
                let r = CGRect(x: rectX, y: y, width: width, height: h)
                canvas.include(r)
                body += #"<rect x="\#(n(r.minX))" y="\#(n(r.minY))" width="\#(n(r.width))" height="\#(n(r.height))" fill="\#(palette.noteFill)" stroke="\#(palette.noteStroke)"/>"#
                body += MermaidSource.textBlock(centerX: r.midX, centerY: r.midY, lines: lines, size: 12, fill: palette.text, lineHeight: lineH)
                y += h + 12
            case let .blockStart(kind, label, drawn):
                stack.append((kind, label, y, drawn))
                if drawn { y += 26 }
            case let .divider(label):
                guard stack.last?.drawn == true else { break }
                let inset = CGFloat(stack.count - 1) * 8
                body += #"<line x1="\#(n(left + inset))" y1="\#(n(y))" x2="\#(n(right - inset))" y2="\#(n(y))" stroke="\#(palette.secondaryText)" stroke-dasharray="6 4"/>"#
                if !label.isEmpty {
                    body += MermaidSource.text(left + inset + 8, y + 15, "[\(label)]", size: 12, fill: palette.secondaryText, anchor: "start")
                }
                y += 26
            case .blockEnd:
                closeFrame(bottom: y)
                y += 10
            }
        }
        while !stack.isEmpty { closeFrame(bottom: y); y += 10 }

        let bottom = y + 6
        var lifelines = ""
        for (k, p) in participants.enumerated() {
            lifelines += #"<line x1="\#(n(cx[k]))" y1="\#(n(boxH))" x2="\#(n(cx[k]))" y2="\#(n(bottom))" stroke="\#(palette.border)" stroke-width="1.5" stroke-dasharray="5 5"/>"#
            for top in [CGFloat(0), bottom] {
                let r = CGRect(x: cx[k] - boxW[k] / 2, y: top, width: boxW[k], height: boxH)
                canvas.include(r)
                let rx: CGFloat = p.actor ? 18 : 4
                lifelines += #"<rect x="\#(n(r.minX))" y="\#(n(r.minY))" width="\#(n(r.width))" height="\#(n(r.height))" rx="\#(n(rx))" fill="\#(palette.nodeFill)" stroke="\#(palette.nodeStroke)" stroke-width="1.5"/>"#
                lifelines += MermaidSource.textBlock(centerX: cx[k], centerY: r.midY, lines: MermaidSource.textLines(p.label), size: 14,
                                                     fill: palette.text, lineHeight: 17)
            }
        }
        canvas.body = frames + lifelines + body
        return canvas
    }

    static func headSVG(_ head: Head, tip: CGPoint, from: CGPoint, palette: RichRenderSVG.Palette) -> String {
        let n = MermaidSource.n
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max(hypot(dx, dy), 0.001)
        let ux = dx / d, uy = dy / d
        func v() -> String {
            let bx = tip.x - ux * 9, by = tip.y - uy * 9
            return #"<path d="M\#(n(bx - uy * 4.5)) \#(n(by + ux * 4.5)) L\#(n(tip.x)) \#(n(tip.y)) L\#(n(bx + uy * 4.5)) \#(n(by - ux * 4.5))" fill="none" stroke="\#(palette.edge)" stroke-width="1.5"/>"#
        }
        switch head {
        case .filled: return MermaidSource.arrowHead(tip: tip, from: from, fill: palette.edge)
        case .open: return ""
        case .async: return v()
        case .cross:
            let c = CGPoint(x: tip.x - ux * 6, y: tip.y - uy * 6)
            return #"<line x1="\#(n(c.x - 4))" y1="\#(n(c.y - 4))" x2="\#(n(c.x + 4))" y2="\#(n(c.y + 4))" stroke="\#(palette.edge)" stroke-width="2"/>"#
                + #"<line x1="\#(n(c.x - 4))" y1="\#(n(c.y + 4))" x2="\#(n(c.x + 4))" y2="\#(n(c.y - 4))" stroke="\#(palette.edge)" stroke-width="2"/>"#
        }
    }
}

// MARK: - Pie

struct MermaidPie {
    var title: String?
    var showData = false
    var slices: [(label: String, value: Double)] = []

    static func parse(header: String, lines: [String]) -> MermaidPie? {
        var pie = MermaidPie()
        var headerRest = header.dropFirst(3).trimmingCharacters(in: .whitespaces)
        if headerRest.lowercased().hasPrefix("showdata") {
            pie.showData = true
            headerRest = String(headerRest.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        }
        if headerRest.lowercased().hasPrefix("title") {
            pie.title = MermaidSource.cleanLabel(String(headerRest.dropFirst(5)))
        }
        let sliceRegex = try! NSRegularExpression(pattern: #"^"([^"]*)"\s*:\s*(-?[0-9]*\.?[0-9]+)\s*$"#)
        for line in lines {
            let lower = line.lowercased()
            if lower == "showdata" { pie.showData = true; continue }
            if lower.hasPrefix("title") && !lower.hasPrefix("title\"") {
                pie.title = MermaidSource.cleanLabel(String(line.dropFirst(5))); continue
            }
            let ns = line as NSString
            guard let m = sliceRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let value = Double(ns.substring(with: m.range(at: 2))), value > 0, value.isFinite else { continue }
            pie.slices.append((MermaidSource.cleanLabel(ns.substring(with: m.range(at: 1))), value))
            if pie.slices.count > MermaidSource.maxNodes { return nil }
        }
        guard !pie.slices.isEmpty else { return nil }
        return pie
    }

    static let colors: [RichRenderSVG.Theme: [String]] = [
        .light: ["#6366F1", "#F59E0B", "#10B981", "#EF4444", "#3B82F6", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316", "#84CC16"],
        .dark: ["#818CF8", "#FBBF24", "#34D399", "#F87171", "#60A5FA", "#A78BFA", "#F472B6", "#2DD4BF", "#FB923C", "#A3E635"],
    ]

    func render(theme: RichRenderSVG.Theme) -> MermaidSource.Canvas? {
        let palette = RichRenderSVG.palette(theme)
        let n = MermaidSource.n
        let colors = Self.colors[theme]!
        let sorted = slices.enumerated().sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }.map(\.element)
        let total = sorted.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        let radius: CGFloat = 110
        let center = CGPoint(x: radius, y: radius)
        var canvas = MermaidSource.Canvas()
        canvas.include(CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2))
        var angle = -Double.pi / 2
        for (k, slice) in sorted.enumerated() {
            let color = colors[k % colors.count]
            let sweep = slice.value / total * 2 * .pi
            if sorted.count == 1 {
                canvas.add(#"<circle cx="\#(n(center.x))" cy="\#(n(center.y))" r="\#(n(radius))" fill="\#(color)" stroke="\#(palette.background)" stroke-width="2"/>"#)
            } else {
                let end = angle + sweep
                let p0 = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
                let p1 = CGPoint(x: center.x + radius * CGFloat(cos(end)), y: center.y + radius * CGFloat(sin(end)))
                let large = sweep > .pi ? 1 : 0
                canvas.add(#"<path d="M\#(n(center.x)) \#(n(center.y)) L\#(n(p0.x)) \#(n(p0.y)) A\#(n(radius)) \#(n(radius)) 0 \#(large) 1 \#(n(p1.x)) \#(n(p1.y)) Z" fill="\#(color)" stroke="\#(palette.background)" stroke-width="2"/>"#)
            }
            if slice.value / total >= 0.05 {
                let mid = angle + sweep / 2
                let lp = CGPoint(x: center.x + radius * 0.65 * CGFloat(cos(mid)), y: center.y + radius * 0.65 * CGFloat(sin(mid)))
                let percent = Int(saturating: slice.value / total * 100) ?? 0
                canvas.add(MermaidSource.text(lp.x, lp.y + 5, "\(percent)%", size: 13, fill: "#FFFFFF", bold: true))
            }
            angle += sweep
        }
        var ly: CGFloat = 12
        for (k, slice) in sorted.enumerated() {
            let value = slice.value == slice.value.rounded() ? String(Int(slice.value)) : String(slice.value)
            let label = showData ? "\(slice.label) [\(value)]" : slice.label
            let lx = radius * 2 + 24
            canvas.add(#"<rect x="\#(n(lx))" y="\#(n(ly))" width="14" height="14" rx="2" fill="\#(colors[k % colors.count])"/>"#)
            canvas.add(MermaidSource.text(lx + 22, ly + 12, label, size: 14, fill: palette.text, anchor: "start"))
            canvas.include(CGRect(x: lx, y: ly, width: 22 + RichRenderSVG.textWidth(label, size: 14), height: 14))
            ly += 24
        }
        return canvas
    }
}
